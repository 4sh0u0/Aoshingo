// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
@testable import FieldDataKit
import PICSKit

/// Scripted server: each path has a queue of responses; requests are recorded.
private final class FakeTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var scripted: [String: [HTTPResponse]] = [:]
    private(set) var requests: [HTTPRequest] = []
    var fallback: [String: HTTPResponse] = [:]

    func script(_ path: String, _ responses: HTTPResponse...) {
        lock.withLock { scripted[path, default: []].append(contentsOf: responses) }
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        lock.withLock {
            requests.append(request)
            if var queue = scripted[request.path], !queue.isEmpty {
                let response = queue.removeFirst()
                scripted[request.path] = queue
                return response
            }
            return fallback[request.path] ?? HTTPResponse(status: 500)
        }
    }

    var paths: [String] { lock.withLock { requests.map(\.path) } }

    func bodies(_ path: String) -> [[String: Any]] {
        lock.withLock {
            requests.filter { $0.path == path }.compactMap { request in
                request.body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            }
        }
    }
}

private final class FakeAttestation: AttestationProvider, @unchecked Sendable {
    private let lock = NSLock()
    let isSupported: Bool
    var assertionError: Error?
    private(set) var generatedKeys = 0
    private(set) var hashes: [Data] = []

    init(isSupported: Bool = true) { self.isSupported = isSupported }

    func generateKey() async throws -> String {
        lock.withLock {
            generatedKeys += 1
            return "key-\(generatedKeys)"
        }
    }

    func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data {
        lock.withLock { hashes.append(clientDataHash) }
        return Data("attestation-\(keyID)".utf8)
    }

    func generateAssertion(_ keyID: String, clientDataHash: Data) async throws -> Data {
        try lock.withLock {
            hashes.append(clientDataHash)
            if let assertionError { throw assertionError }
        }
        return Data("assertion-\(keyID)".utf8)
    }
}

private final class MemoryKeyStorage: KeyIDStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    init(_ value: String? = nil) { self.value = value }
    func load() -> String? { lock.withLock { value } }
    func save(_ keyID: String?) { lock.withLock { value = keyID } }
}

private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_794_290_000)
    var now: Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current += seconds } }
}

private func json(_ status: Int, _ object: [String: Any]) -> HTTPResponse {
    HTTPResponse(status: status, body: try! JSONSerialization.data(withJSONObject: object))
}

private let challenge = json(201, ["challenge": "abc", "expiresAt": 1_794_290_300])
private func token(_ value: String, expires: Int = 1_794_290_000 + 21_600) -> HTTPResponse {
    json(200, ["token": value, "expiresAt": expires])
}

// A stand-in hash: the tests only check that the hash of the challenge string is passed through.
private let fakeHash: @Sendable (Data) -> Data = { Data($0.reversed()) }

@Suite("Report uploader")
struct UploaderTests {
    private func makeUploader(
        transport: FakeTransport,
        attestation: FakeAttestation = FakeAttestation(),
        keys: MemoryKeyStorage = MemoryKeyStorage(),
        clock: Clock = Clock()
    ) -> ReportUploader {
        ReportUploader(transport: transport, attestation: attestation, keyStorage: keys, sha256: fakeHash, now: { clock.now })
    }

    @Test("first upload attests a new key, stores it, and sends the token as a bearer")
    func firstUpload() async throws {
        let transport = FakeTransport()
        transport.script("/v1/challenge", challenge)
        transport.script("/v1/attest", token("T1"))
        transport.script("/v1/reports", HTTPResponse(status: 202))
        let attestation = FakeAttestation()
        let keys = MemoryKeyStorage()
        let uploader = makeUploader(transport: transport, attestation: attestation, keys: keys)

        #expect(try await uploader.upload(Data("{}".utf8)) == .accepted)
        #expect(transport.paths == ["/v1/challenge", "/v1/attest", "/v1/reports"])
        #expect(keys.load() == "key-1")
        #expect(attestation.hashes == [fakeHash(Data("abc".utf8))])
        let attest = try #require(transport.bodies("/v1/attest").first)
        #expect(attest["keyId"] as? String == "key-1")
        #expect(attest["challenge"] as? String == "abc")
        #expect(attest["attestation"] as? String == Data("attestation-key-1".utf8).base64EncodedString())
        #expect(transport.requests.last?.headers["Authorization"] == "Bearer T1")
    }

    @Test("token is reused until one minute before expiry, then refreshed with an assertion")
    func tokenReuseAndRefresh() async throws {
        let transport = FakeTransport()
        transport.fallback["/v1/reports"] = HTTPResponse(status: 202)
        transport.fallback["/v1/challenge"] = challenge
        transport.script("/v1/attest", token("T1", expires: 1_794_290_000 + 3600))
        transport.script("/v1/token", token("T2", expires: 1_794_290_000 + 7200))
        let clock = Clock()
        let uploader = makeUploader(transport: transport, clock: clock)

        _ = try await uploader.upload(Data())
        clock.advance(3000)
        _ = try await uploader.upload(Data())
        #expect(transport.paths.filter { $0 == "/v1/challenge" }.count == 1)
        clock.advance(541) // 59 s left
        _ = try await uploader.upload(Data())
        #expect(transport.paths.suffix(3) == ["/v1/challenge", "/v1/token", "/v1/reports"])
        let refresh = try #require(transport.bodies("/v1/token").first)
        #expect(refresh["keyId"] as? String == "key-1")
        #expect(refresh["assertion"] as? String == Data("assertion-key-1".utf8).base64EncodedString())
        #expect(transport.requests.last?.headers["Authorization"] == "Bearer T2")
    }

    @Test("an unknown or invalid key falls back to attesting a new key")
    func unknownKeyFallsBack() async throws {
        for failure in [json(404, ["error": "unknown_key"]), json(401, ["error": "assertion_invalid"])] {
            let transport = FakeTransport()
            transport.fallback["/v1/challenge"] = challenge
            transport.script("/v1/token", failure)
            transport.script("/v1/attest", token("T9"))
            transport.script("/v1/reports", HTTPResponse(status: 202))
            let keys = MemoryKeyStorage("old-key")
            let uploader = makeUploader(transport: transport, keys: keys)
            #expect(try await uploader.upload(Data()) == .accepted)
            #expect(transport.paths == ["/v1/challenge", "/v1/token", "/v1/challenge", "/v1/attest", "/v1/reports"])
            #expect(keys.load() == "key-1")
        }
    }

    @Test("a key the device reports as invalid is replaced without calling /v1/token")
    func deviceInvalidKey() async throws {
        let transport = FakeTransport()
        transport.fallback["/v1/challenge"] = challenge
        transport.script("/v1/attest", token("T1"))
        transport.script("/v1/reports", HTTPResponse(status: 202))
        let attestation = FakeAttestation()
        attestation.assertionError = AttestationError.invalidKey
        let uploader = makeUploader(transport: transport, attestation: attestation, keys: MemoryKeyStorage("stale"))
        #expect(try await uploader.upload(Data()) == .accepted)
        #expect(!transport.paths.contains("/v1/token"))
    }

    @Test("a 401 on upload refreshes the token once and retries")
    func retryOn401() async throws {
        let transport = FakeTransport()
        transport.fallback["/v1/challenge"] = challenge
        transport.script("/v1/attest", token("T1"))
        transport.script("/v1/token", token("T2"))
        transport.script("/v1/reports", json(401, ["error": "invalid_token"]), HTTPResponse(status: 202))
        let uploader = makeUploader(transport: transport)
        #expect(try await uploader.upload(Data()) == .accepted)
        #expect(transport.requests.last?.headers["Authorization"] == "Bearer T2")
    }

    @Test("permanent rejections are reported, retryable failures throw")
    func outcomes() async throws {
        let transport = FakeTransport()
        transport.fallback["/v1/challenge"] = challenge
        transport.script("/v1/attest", token("T1"))
        transport.script(
            "/v1/reports",
            json(400, ["error": "invalid_report"]),
            json(413, ["error": "too_large"]),
            json(429, ["error": "rate_limited"]),
            HTTPResponse(status: 503)
        )
        let uploader = makeUploader(transport: transport)
        #expect(try await uploader.upload(Data()) == .rejected(code: "invalid_report"))
        #expect(try await uploader.upload(Data()) == .rejected(code: "too_large"))
        await #expect(throws: UploadError.rateLimited) { try await uploader.upload(Data()) }
        await #expect(throws: UploadError.server(status: 503, code: nil)) { try await uploader.upload(Data()) }
    }

    @Test("unsupported devices never contact the server; forget() drops the key")
    func unsupportedAndForget() async throws {
        let transport = FakeTransport()
        let unsupported = makeUploader(transport: transport, attestation: FakeAttestation(isSupported: false))
        await #expect(throws: UploadError.attestationUnsupported) { try await unsupported.upload(Data()) }
        #expect(transport.requests.isEmpty)

        let keys = MemoryKeyStorage("key")
        let uploader = makeUploader(transport: transport, keys: keys)
        await uploader.forget()
        #expect(keys.load() == nil)
    }

    @Test("malformed token responses are invalidResponse")
    func malformed() async throws {
        let transport = FakeTransport()
        transport.fallback["/v1/challenge"] = challenge
        transport.script("/v1/attest", HTTPResponse(status: 200, body: Data("nope".utf8)))
        let keys = MemoryKeyStorage()
        let uploader = makeUploader(transport: transport, keys: keys)
        await #expect(throws: UploadError.invalidResponse) { try await uploader.upload(Data()) }
        #expect(keys.load() == nil)
    }
}

@Suite("Field data pipeline")
struct PipelineTests {
    private func signalPacket(_ state: UInt8) throws -> (PICSPacket, [UInt8]) {
        var payload = [UInt8](repeating: 0, count: 11)
        payload[2] = 2
        payload[9] = 1
        payload[10] = state
        let data = PICS.companyIDBytes + payload
        return (try PICSParser.parse(manufacturerData: data), data)
    }

    @Test("nothing is recorded while disabled; disabling deletes the queue and the key")
    func consent() async throws {
        let transport = FakeTransport()
        let keys = MemoryKeyStorage("key")
        let store = InMemoryReportStore()
        let clock = Clock()
        let uploader = ReportUploader(transport: transport, attestation: FakeAttestation(), keyStorage: keys, sha256: fakeHash, now: { clock.now })
        let pipeline = FieldDataPipeline(store: store, uploader: uploader, client: "aoshingo-ios/0.1.0", now: { clock.now })

        let (packet, data) = try signalPacket(0x31)
        await pipeline.record(packet, manufacturerData: data, at: clock.now, rssi: -60, serviceUUIDs: [], emitter: nil, context: .init())
        #expect(await pipeline.flush(force: true) == false)
        #expect(await store.count() == 0)

        await pipeline.setEnabled(true)
        await pipeline.record(packet, manufacturerData: data, at: clock.now, rssi: -60, serviceUUIDs: [], emitter: nil, context: .init())
        #expect(await pipeline.status().bufferedObservations == 1)
        #expect(await pipeline.flush() == false) // window not full yet
        clock.advance(600)
        #expect(await pipeline.flush() == true)
        #expect(await store.count() == 1)

        await pipeline.setEnabled(false)
        #expect(await store.count() == 0)
        #expect(keys.load() == nil)
        #expect(await pipeline.status() == .init(isEnabled: false, bufferedObservations: 0, bufferedTransitions: 0, pendingReports: 0, lastUpload: nil, lastError: nil))
        #expect(transport.requests.isEmpty)
    }

    @Test("uploads queued reports oldest first, drops rejected ones, keeps the rest on a retryable error")
    func upload() async throws {
        let transport = FakeTransport()
        transport.fallback["/v1/challenge"] = challenge
        transport.script("/v1/attest", token("T1"))
        transport.script("/v1/reports", HTTPResponse(status: 202), json(400, ["error": "invalid_report"]), HTTPResponse(status: 503))
        let clock = Clock()
        let store = InMemoryReportStore()
        let uploader = ReportUploader(transport: transport, attestation: FakeAttestation(), keyStorage: MemoryKeyStorage(), sha256: fakeHash, now: { clock.now })
        let pipeline = FieldDataPipeline(store: store, uploader: uploader, client: "aoshingo-ios/0.1.0", now: { clock.now })
        await pipeline.setEnabled(true)
        for index in 0..<4 {
            await store.enqueue(Data("{\"n\":\(index)}".utf8), at: clock.now)
        }
        let summary = await pipeline.uploadPending()
        #expect(summary.accepted == 1)
        #expect(summary.rejected == 1)
        #expect(summary.remaining == 2)
        #expect(summary.error == .server(status: 503, code: nil))
        let sent = transport.requests.filter { $0.path == "/v1/reports" }.compactMap { $0.body.map { String(decoding: $0, as: UTF8.self) } }
        #expect(sent == ["{\"n\":0}", "{\"n\":1}", "{\"n\":2}"])
    }

    @Test("reports older than six days are dropped before upload")
    func dropsOld() async throws {
        let transport = FakeTransport()
        let clock = Clock()
        let store = InMemoryReportStore()
        let uploader = ReportUploader(transport: transport, attestation: FakeAttestation(), keyStorage: MemoryKeyStorage(), sha256: fakeHash, now: { clock.now })
        let pipeline = FieldDataPipeline(store: store, uploader: uploader, client: "aoshingo-ios/0.1.0", now: { clock.now })
        await pipeline.setEnabled(true)
        await store.enqueue(Data("{}".utf8), at: clock.now)
        clock.advance(FieldDataPipeline.maximumReportAge + 1)
        let summary = await pipeline.uploadPending()
        #expect(summary.remaining == 0)
        #expect(transport.requests.isEmpty)
    }

    @Test("without a configured server, reports stay queued")
    func noServer() async throws {
        let store = InMemoryReportStore()
        let pipeline = FieldDataPipeline(store: store, uploader: nil, client: "aoshingo-ios/0.1.0")
        await pipeline.setEnabled(true)
        await store.enqueue(Data("{}".utf8), at: Date())
        #expect(await pipeline.uploadPending().remaining == 1)
    }
}

@Suite("File report store")
struct FileReportStoreTests {
    @Test("persists, orders, caps, ages out and deletes reports")
    func lifecycle() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aoshingo-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileReportStore(directory: directory, capacity: 3)
        let base = Date(timeIntervalSince1970: 1_794_290_000)
        for index in 0..<4 {
            try await store.enqueue(Data("\(index)".utf8), at: base.addingTimeInterval(Double(index)))
        }
        var pending = try await store.pending()
        #expect(pending.map { String(decoding: $0.body, as: UTF8.self) } == ["1", "2", "3"])
        #expect(pending[0].createdAt == base.addingTimeInterval(1))

        try await store.remove(id: pending[0].id)
        try await store.remove(id: "../../etc/passwd")
        pending = try await store.pending()
        #expect(pending.count == 2)

        try await store.removeOlder(than: base.addingTimeInterval(3))
        #expect(try await store.pending().count == 1)

        try await store.removeAll()
        #expect(try await store.pending().isEmpty)
    }
}
