// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
@testable import FieldDataKit
import PICSKit

/// Holds callers at a known point until the test opens it.
///
/// With `honoursCancellation`, a waiting caller whose task is cancelled throws `CancellationError`,
/// like `URLSession.data(for:)`; otherwise it keeps waiting, like an App Attest call in progress.
final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private let honoursCancellation: Bool
    private var isOpen = false
    private var arrivals = 0
    private var nextID = 0
    private var waiting: [Int: CheckedContinuation<Void, any Error>] = [:]
    private var cancelledBeforeWaiting: Set<Int> = []

    init(honoursCancellation: Bool = false) {
        self.honoursCancellation = honoursCancellation
    }

    var arrivalCount: Int { lock.withLock { arrivals } }

    func pass() async throws {
        let id: Int = lock.withLock {
            arrivals += 1
            nextID += 1
            return nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                enum Action { case resume, cancel, wait }
                let action: Action = lock.withLock {
                    if isOpen { return .resume }
                    if cancelledBeforeWaiting.remove(id) != nil { return .cancel }
                    waiting[id] = continuation
                    return .wait
                }
                switch action {
                case .resume: continuation.resume()
                case .cancel: continuation.resume(throwing: CancellationError())
                case .wait: break
                }
            }
        } onCancel: {
            guard honoursCancellation else { return }
            let continuation: CheckedContinuation<Void, any Error>? = lock.withLock {
                if let continuation = waiting.removeValue(forKey: id) { return continuation }
                cancelledBeforeWaiting.insert(id)
                return nil
            }
            continuation?.resume(throwing: CancellationError())
        }
    }

    func open() {
        let continuations: [CheckedContinuation<Void, any Error>] = lock.withLock {
            isOpen = true
            defer { waiting.removeAll() }
            return Array(waiting.values)
        }
        for continuation in continuations { continuation.resume() }
    }
}

/// Polls `condition` until it holds, failing the test after about five seconds.
func eventually(
    _ description: String = "condition",
    sourceLocation: SourceLocation = #_sourceLocation,
    _ condition: @Sendable () async -> Bool
) async throws {
    for _ in 0..<5000 {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(1))
    }
    Issue.record("timed out waiting for \(description)", sourceLocation: sourceLocation)
    throw CancellationError()
}

/// Scripted server: each path has a queue of responses; requests are recorded.
final class FakeTransport: HTTPTransport, @unchecked Sendable {
    struct NetworkError: Error {}

    private let lock = NSLock()
    private var scripted: [String: [HTTPResponse]] = [:]
    private var gates: [String: Gate] = [:]
    private var failures: Set<String> = []
    private(set) var requests: [HTTPRequest] = []
    var fallback: [String: HTTPResponse] = [:]

    func script(_ path: String, _ responses: HTTPResponse...) {
        lock.withLock { scripted[path, default: []].append(contentsOf: responses) }
    }

    /// Requests to `path` are recorded, then wait at `gate` before they are answered.
    func hold(_ path: String, at gate: Gate) {
        lock.withLock { gates[path] = gate }
    }

    /// Requests to `path` fail like a network error until `failing` is set to `false`.
    func setNetworkFailure(_ path: String, _ failing: Bool) {
        lock.withLock {
            if failing { failures.insert(path) } else { failures.remove(path) }
        }
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let gate = lock.withLock {
            requests.append(request)
            return gates[request.path]
        }
        try await gate?.pass()
        return try lock.withLock {
            if failures.contains(request.path) { throw NetworkError() }
            if var queue = scripted[request.path], !queue.isEmpty {
                let response = queue.removeFirst()
                scripted[request.path] = queue
                return response
            }
            return fallback[request.path] ?? HTTPResponse(status: 500)
        }
    }

    var paths: [String] { lock.withLock { requests.map(\.path) } }

    func count(_ path: String) -> Int { lock.withLock { requests.filter { $0.path == path }.count } }

    func bodies(_ path: String) -> [[String: Any]] {
        lock.withLock {
            requests.filter { $0.path == path }.compactMap { request in
                request.body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            }
        }
    }

    func reportBodies() -> [String] {
        lock.withLock {
            requests.filter { $0.path == "/v1/reports" }.compactMap { $0.body.map { String(decoding: $0, as: UTF8.self) } }
        }
    }
}

final class FakeAttestation: AttestationProvider, @unchecked Sendable {
    private let lock = NSLock()
    let isSupported: Bool
    var assertionError: (any Error)?
    /// Keys for which `attestKey` throws `AttestationError.invalidKey` (for example, already attested).
    var unattestableKeys: Set<String> = []
    /// Thrown by `attestKey` (once per entry) before anything else.
    var attestErrors: [any Error] = []
    var attestGate: Gate?
    private(set) var generatedKeys = 0
    private(set) var attestedKeys: [String] = []
    private(set) var hashes: [Data] = []

    init(isSupported: Bool = true) { self.isSupported = isSupported }

    func generateKey() async throws -> String {
        lock.withLock {
            generatedKeys += 1
            return "key-\(generatedKeys)"
        }
    }

    func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data {
        let gate = lock.withLock { attestGate }
        try await gate?.pass()
        return try lock.withLock {
            if !attestErrors.isEmpty { throw attestErrors.removeFirst() }
            if unattestableKeys.contains(keyID) { throw AttestationError.invalidKey }
            hashes.append(clientDataHash)
            attestedKeys.append(keyID)
            return Data("attestation-\(keyID)".utf8)
        }
    }

    func generateAssertion(_ keyID: String, clientDataHash: Data) async throws -> Data {
        try lock.withLock {
            hashes.append(clientDataHash)
            if let assertionError { throw assertionError }
        }
        return Data("assertion-\(keyID)".utf8)
    }
}

final class MemoryKeyStorage: KeyIDStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var value: AttestKey?
    private var saves: [AttestKey?] = []

    init(_ value: AttestKey? = nil) { self.value = value }

    func load() -> AttestKey? { lock.withLock { value } }

    func save(_ key: AttestKey?) {
        lock.withLock {
            value = key
            saves.append(key)
        }
    }

    /// How often the key was deleted (for example by `forget()`).
    var deletions: Int { lock.withLock { saves.filter { $0 == nil }.count } }
}

func attested(_ id: String) -> AttestKey { AttestKey(id: id, isAttested: true) }
func pending(_ id: String) -> AttestKey { AttestKey(id: id, isAttested: false) }

final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date = Date(timeIntervalSince1970: 1_794_290_000)) { current = start }

    var now: Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current += seconds } }
    func set(_ date: Date) { lock.withLock { current = date } }
}

func json(_ status: Int, _ object: [String: Any]) -> HTTPResponse {
    HTTPResponse(status: status, body: try! JSONSerialization.data(withJSONObject: object))
}

let challengeResponse = json(201, ["challenge": "abc", "expiresAt": 1_794_290_300])

func tokenResponse(_ value: String, expires: Int = 1_794_290_000 + 21_600) -> HTTPResponse {
    json(200, ["token": value, "expiresAt": expires])
}

// A stand-in hash: the tests only check that the hash of the challenge string is passed through.
let fakeHash: @Sendable (Data) -> Data = { Data($0.reversed()) }

/// An in-memory queue whose writes and bulk deletions can be made to fail, like a full or locked disk.
actor FlakyStore: ReportStore {
    struct DiskError: Error {}
    private let inner = InMemoryReportStore()
    var failEnqueue = false
    var failPurge = false
    var enqueueGate: Gate?

    func setFailures(enqueue: Bool, purge: Bool) {
        failEnqueue = enqueue
        failPurge = purge
    }

    func setEnqueueGate(_ gate: Gate?) { enqueueGate = gate }

    func enqueue(_ body: Data, at date: Date) async throws {
        try await enqueueGate?.pass()
        if failEnqueue { throw DiskError() }
        await inner.enqueue(body, at: date)
    }

    func pending() async throws -> [PendingReport] { await inner.pending() }

    func remove(id: String) async throws { await inner.remove(id: id) }

    func removeAll() async throws {
        if failPurge { throw DiskError() }
        await inner.removeAll()
    }

    func removeOlder(than date: Date) async throws {
        if failPurge { throw DiskError() }
        await inner.removeOlder(than: date)
    }
}
