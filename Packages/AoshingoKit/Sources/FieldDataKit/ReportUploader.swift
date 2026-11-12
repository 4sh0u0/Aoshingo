// SPDX-License-Identifier: Apache-2.0

import Foundation

/// A minimal HTTP abstraction so the upload logic can be tested without a network.
public struct HTTPRequest: Sendable, Hashable {
    public var method: String
    /// Path relative to the API base, for example `/v1/reports`.
    public var path: String
    public var headers: [String: String]
    public var body: Data?

    public init(method: String, path: String, headers: [String: String] = [:], body: Data? = nil) {
        self.method = method
        self.path = path
        self.headers = headers
        self.body = body
    }
}

public struct HTTPResponse: Sendable, Hashable {
    public var status: Int
    public var body: Data

    public init(status: Int, body: Data = Data()) {
        self.status = status
        self.body = body
    }
}

public protocol HTTPTransport: Sendable {
    /// Should stop and throw when the calling task is cancelled (as `URLSession` does).
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}

/// App Attest operations (`DCAppAttestService` on iOS).
public protocol AttestationProvider: Sendable {
    var isSupported: Bool { get }
    func generateKey() async throws -> String
    func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data
    func generateAssertion(_ keyID: String, clientDataHash: Data) async throws -> Data
}

public enum AttestationError: Error, Sendable, Equatable {
    /// The key can no longer be used (for example after a restore to another device, or when it
    /// was already attested once).
    case invalidKey
    /// App Attest could not reach Apple. Apple asks to try again later with the same key; after
    /// any other attestation error the key is discarded.
    case serverUnavailable
}

/// The App Attest key this installation uses. The key ID never travels with report data.
public struct AttestKey: Sendable, Hashable, Codable {
    public var id: String
    /// `false` from key generation until the server has accepted the key's attestation, so a key
    /// whose attestation could not be delivered is reused instead of generating another one.
    public var isAttested: Bool

    public init(id: String, isAttested: Bool) {
        self.id = id
        self.isAttested = isAttested
    }
}

/// Persists the App Attest key (Keychain on iOS).
public protocol KeyIDStorage: Sendable {
    func load() -> AttestKey?
    func save(_ key: AttestKey?)
}

public enum UploadError: Error, Sendable, Equatable {
    case attestationUnsupported
    case rateLimited
    case invalidResponse
    case server(status: Int, code: String?)
    /// An earlier attempt failed; no request was made before this time (see `RetryPolicy`).
    case backingOff(until: Date)
    /// The user opted out (or the task was cancelled) while uploading. Nothing was kept.
    case cancelled
}

public enum UploadOutcome: Sendable, Equatable {
    case accepted
    /// The server refused this report permanently (for example `invalid_report`); drop it.
    case rejected(code: String?)
}

/// Uploads reports and downloads the signal timing plans, obtaining short-lived upload tokens
/// through App Attest.
///
/// `forget()` (opt-out) wins over any upload in progress: every step checks, after each suspension
/// point and before anything is stored or sent, that `forget()` has not been called since the
/// upload started. Calls to `upload(_:)` are expected not to overlap; `FieldDataPipeline`
/// serialises them. `fetchPlans()` may run alongside an upload: getting a token is serialised, so
/// the two never refresh the token or attest a key at the same time.
///
/// Every report `POST` of schema 4 or later carries `sentAt`, the uploader's clock at that attempt
/// in Unix milliseconds (docs/timing-estimation.md). It is added here and not stored in the queue.
public actor ReportUploader {
    /// Tokens are refreshed when they have less than this many seconds left.
    public static let tokenRefreshMargin: TimeInterval = 60
    static let retryStateKey = "uploadRetry"

    private let transport: any HTTPTransport
    private let attestation: any AttestationProvider
    private let keyStorage: any KeyIDStorage
    private let stateStore: any StateStore
    private let sha256: @Sendable (Data) -> Data
    private let now: @Sendable () -> Date
    private let random: @Sendable (ClosedRange<Double>) -> Double
    private var token: (value: String, expiresAt: Date)?
    /// Incremented by `forget()`; work started under an older value stops without side effects.
    private var generation: UInt64 = 0
    private var retry: RetryState?
    /// Set while a caller gets a token; others wait in `tokenWaiters`, in call order.
    private var isGettingToken = false
    private var tokenWaiters: [CheckedContinuation<Void, Never>] = []

    /// - Parameters:
    ///   - stateStore: keeps the back-off across launches.
    ///   - random: returns a value in the range; used for retry jitter.
    public init(
        transport: any HTTPTransport,
        attestation: any AttestationProvider,
        keyStorage: any KeyIDStorage,
        stateStore: any StateStore = InMemoryStateStore(),
        sha256: @escaping @Sendable (Data) -> Data,
        now: @escaping @Sendable () -> Date = { Date() },
        random: @escaping @Sendable (ClosedRange<Double>) -> Double = { Double.random(in: $0) }
    ) {
        self.transport = transport
        self.attestation = attestation
        self.keyStorage = keyStorage
        self.stateStore = stateStore
        self.sha256 = sha256
        self.now = now
        self.random = random
        self.retry = stateStore.value(RetryState.self, forKey: Self.retryStateKey)
    }

    /// `false` on devices without App Attest; such an uploader never contacts the server.
    public nonisolated var isAttestationSupported: Bool { attestation.isSupported }

    /// The earliest time of the next request after a failure, or `nil` when not backing off.
    public var retryNotBefore: Date? { retry?.notBefore }

    /// Uploads one encoded report. Throws for retryable failures, after which no request is made
    /// until the back-off has passed (`UploadError.backingOff`).
    public func upload(_ body: Data) async throws -> UploadOutcome {
        guard attestation.isSupported else { throw UploadError.attestationUnsupported }
        if let retry, now() < retry.notBefore { throw UploadError.backingOff(until: retry.notBefore) }
        let epoch = generation
        do {
            let outcome = try await send(body, epoch: epoch)
            setRetry(nil)
            return outcome
        } catch {
            throw failure(error, epoch: epoch)
        }
    }

    /// Downloads every intersection's signal timing plans (`GET /v1/plans`) with the upload token,
    /// refreshing the token once when the server answers 401, as `upload(_:)` does.
    ///
    /// The request never names intersections (the optional `ids` query), so the server does not
    /// learn which intersections this user is interested in. The back-off is shared with
    /// `upload(_:)`: this throws `backingOff` while one runs, and a failure starts or extends it.
    public func fetchPlans() async throws -> TimingPlanDownload {
        guard attestation.isSupported else { throw UploadError.attestationUnsupported }
        if let retry, now() < retry.notBefore { throw UploadError.backingOff(until: retry.notBefore) }
        let epoch = generation
        do {
            let download = try await getPlans(epoch: epoch)
            setRetry(nil)
            return download
        } catch {
            throw failure(error, epoch: epoch)
        }
    }

    /// Records the back-off after a failed upload or download and returns the error to throw.
    private func failure(_ error: any Error, epoch: UInt64) -> any Error {
        // Opted out or cancelled meanwhile: record nothing, not even a back-off.
        if epoch != generation || Task.isCancelled || error is CancellationError || error as? UploadError == .cancelled {
            return UploadError.cancelled
        }
        let failures = (retry?.failures ?? 0) + 1
        setRetry(RetryState(
            failures: failures,
            notBefore: RetryPolicy.nextAttempt(after: error, failures: failures, now: now(), random: random)
        ))
        return error
    }

    /// Forgets the token, the App Attest key ID and the back-off (when the user turns collection off),
    /// and stops any upload in progress from storing or sending anything more.
    public func forget() {
        generation &+= 1
        token = nil
        keyStorage.save(nil)
        setRetry(nil)
    }

    private func setRetry(_ state: RetryState?) {
        retry = state
        stateStore.setValue(state, forKey: Self.retryStateKey)
    }

    private func send(_ body: Data, epoch: UInt64) async throws -> UploadOutcome {
        var response = try await postReport(body, token: try await validToken(epoch), epoch: epoch)
        if response.status == 401 {
            token = nil
            response = try await postReport(body, token: try await validToken(epoch), epoch: epoch)
        }
        switch response.status {
        case 200..<300:
            return .accepted
        case 400, 413, 415:
            return .rejected(code: Self.errorCode(response.body))
        case 429:
            throw UploadError.rateLimited
        default:
            throw UploadError.server(status: response.status, code: Self.errorCode(response.body))
        }
    }

    private func getPlans(epoch: UInt64) async throws -> TimingPlanDownload {
        var response = try await requestPlans(token: try await validToken(epoch), epoch: epoch)
        if response.status == 401 {
            token = nil
            response = try await requestPlans(token: try await validToken(epoch), epoch: epoch)
        }
        switch response.status {
        case 200:
            return TimingPlanDownload(plans: try Self.decode(TimingPlans.self, response.body), body: response.body)
        case 429:
            throw UploadError.rateLimited
        default:
            throw UploadError.server(status: response.status, code: Self.errorCode(response.body))
        }
    }

    // MARK: - Opt-out checks

    /// Before starting a request or an App Attest operation.
    private func checkBeforeStarting(_ epoch: UInt64) throws {
        guard epoch == generation, !Task.isCancelled else { throw UploadError.cancelled }
    }

    /// After every suspension point, before anything is stored.
    private func checkStillCurrent(_ epoch: UInt64) throws {
        guard epoch == generation else { throw UploadError.cancelled }
    }

    // MARK: - Tokens

    private func validToken(_ epoch: UInt64) async throws -> String {
        // One caller at a time: an upload and a plans download must not refresh the token or attest a
        // key concurrently (the server accepts each assertion counter only once, and every attestation
        // costs an App Attest call). A caller that waited usually finds the token the other one got.
        await lockToken()
        defer { unlockToken() }
        if let token, token.expiresAt.timeIntervalSince(now()) > Self.tokenRefreshMargin {
            return token.value
        }
        if let key = keyStorage.load(), key.isAttested {
            if let refreshed = try await refreshToken(keyID: key.id, epoch: epoch) {
                return try keep(refreshed, epoch: epoch)
            }
            // The device or the server no longer accepts this key: attest a new one.
            keyStorage.save(nil)
        }
        return try keep(try await attest(epoch: epoch), epoch: epoch)
    }

    private func lockToken() async {
        guard isGettingToken else {
            isGettingToken = true
            return
        }
        await withCheckedContinuation { tokenWaiters.append($0) }
    }

    /// Callers waiting for another one to get the token (for tests).
    var tokenWaiterCount: Int { tokenWaiters.count }

    /// Hands the token lock to the next waiter, in call order.
    private func unlockToken() {
        if tokenWaiters.isEmpty {
            isGettingToken = false
        } else {
            tokenWaiters.removeFirst().resume()
        }
    }

    private func keep(_ response: TokenResponse, epoch: UInt64) throws -> String {
        try checkStillCurrent(epoch)
        token = (response.token, Date(timeIntervalSince1970: TimeInterval(response.expiresAt)))
        return response.token
    }

    /// Returns `nil` when the key is unknown to the server or no longer valid, so a new key is attested.
    private func refreshToken(keyID: String, epoch: UInt64) async throws -> TokenResponse? {
        let challenge = try await fetchChallenge(epoch: epoch)
        let assertion: Data
        do {
            try checkBeforeStarting(epoch)
            assertion = try await attestation.generateAssertion(keyID, clientDataHash: sha256(Data(challenge.utf8)))
        } catch AttestationError.invalidKey {
            try checkStillCurrent(epoch)
            return nil
        }
        try checkStillCurrent(epoch)
        let response = try await postJSON("/v1/token", [
            "keyId": keyID,
            "assertion": assertion.base64EncodedString(),
            "challenge": challenge,
        ], epoch: epoch)
        switch response.status {
        case 200:
            return try Self.decode(TokenResponse.self, response.body)
        case 401, 404:
            return nil
        case 429:
            throw UploadError.rateLimited
        default:
            throw UploadError.server(status: response.status, code: Self.errorCode(response.body))
        }
    }

    /// Attests the pending key, or a new one, and registers it with the server.
    ///
    /// The challenge comes first, so a server that is down or out of capacity costs no new key.
    /// A new key is saved (as not attested) as soon as it exists and reused by later attempts; it is
    /// replaced only when App Attest reports it invalid or fails it (other than `serverUnavailable`),
    /// or the server rejects its attestation.
    private func attest(epoch: UInt64) async throws -> TokenResponse {
        let challenge = try await fetchChallenge(epoch: epoch)
        let clientDataHash = sha256(Data(challenge.utf8))

        var key: AttestKey
        let reused: Bool
        if let stored = keyStorage.load(), !stored.isAttested {
            key = stored
            reused = true
        } else {
            key = try await generateKey(epoch: epoch)
            reused = false
        }

        let attestationObject: Data
        do {
            attestationObject = try await attestKey(key, clientDataHash: clientDataHash, epoch: epoch)
        } catch AttestationError.invalidKey where reused {
            // A reused key may have been attested before its upload failed; App Attest allows that
            // only once. A key generated just now is not replaced within the same attempt.
            key = try await generateKey(epoch: epoch)
            attestationObject = try await attestKey(key, clientDataHash: clientDataHash, epoch: epoch)
        }

        let response = try await postJSON("/v1/attest", [
            "keyId": key.id,
            "attestation": attestationObject.base64EncodedString(),
            "challenge": challenge,
        ], epoch: epoch)
        switch response.status {
        case 200:
            keyStorage.save(AttestKey(id: key.id, isAttested: true))
            return try Self.decode(TokenResponse.self, response.body)
        case 409:
            // `key_exists`: an earlier attestation of this key reached the server but its answer
            // did not reach us. The key is registered, so use it.
            keyStorage.save(AttestKey(id: key.id, isAttested: true))
            if let refreshed = try await refreshToken(keyID: key.id, epoch: epoch) {
                return refreshed
            }
            keyStorage.save(nil)
            throw UploadError.server(status: response.status, code: Self.errorCode(response.body))
        case 401:
            // `attestation_invalid`: the server will never accept this key (RetryPolicy waits a day).
            keyStorage.save(nil)
            throw UploadError.server(status: response.status, code: Self.errorCode(response.body))
        case 429:
            throw UploadError.rateLimited
        default:
            throw UploadError.server(status: response.status, code: Self.errorCode(response.body))
        }
    }

    /// Attests `key`. On failure the key is forgotten, except when App Attest asks to retry it later.
    private func attestKey(_ key: AttestKey, clientDataHash: Data, epoch: UInt64) async throws -> Data {
        try checkBeforeStarting(epoch)
        let attestationObject: Data
        do {
            attestationObject = try await attestation.attestKey(key.id, clientDataHash: clientDataHash)
        } catch AttestationError.serverUnavailable {
            throw AttestationError.serverUnavailable
        } catch {
            try checkStillCurrent(epoch)
            keyStorage.save(nil)
            throw error
        }
        try checkStillCurrent(epoch)
        return attestationObject
    }

    private func generateKey(epoch: UInt64) async throws -> AttestKey {
        try checkBeforeStarting(epoch)
        let id = try await attestation.generateKey()
        try checkStillCurrent(epoch)
        let key = AttestKey(id: id, isAttested: false)
        keyStorage.save(key)
        return key
    }

    private func fetchChallenge(epoch: UInt64) async throws -> String {
        let response = try await perform(HTTPRequest(
            method: "POST",
            path: "/v1/challenge",
            headers: ["Content-Type": "application/json"],
            body: Data("{}".utf8)
        ), epoch: epoch)
        switch response.status {
        case 201, 200:
            return try Self.decode(ChallengeResponse.self, response.body).challenge
        case 429:
            throw UploadError.rateLimited
        default:
            throw UploadError.server(status: response.status, code: Self.errorCode(response.body))
        }
    }

    // MARK: - HTTP helpers

    private func perform(_ request: HTTPRequest, epoch: UInt64) async throws -> HTTPResponse {
        try checkBeforeStarting(epoch)
        let response = try await transport.send(request)
        try checkStillCurrent(epoch)
        return response
    }

    /// Posts one report, stamped with `sentAt` at this attempt (see `stamped(_:sentAt:)`).
    private func postReport(_ body: Data, token: String, epoch: UInt64) async throws -> HTTPResponse {
        try await perform(HTTPRequest(
            method: "POST",
            path: "/v1/reports",
            headers: ["Content-Type": "application/json", "Authorization": "Bearer \(token)"],
            body: Self.stamped(body, sentAt: now())
        ), epoch: epoch)
    }

    private func requestPlans(token: String, epoch: UInt64) async throws -> HTTPResponse {
        try await perform(HTTPRequest(
            method: "GET",
            path: "/v1/plans",
            headers: ["Accept": "application/json", "Authorization": "Bearer \(token)"]
        ), epoch: epoch)
    }

    /// `body` as sent at `date`. A report of schema 4 or later gets `"sentAt": <Unix milliseconds of
    /// date>` (inserted after the opening brace, so the rest of the body keeps its bytes), which the
    /// server compares with its own clock. Bodies of older schemas, which may still be queued from an
    /// earlier version, are sent unchanged, because the server rejects `sentAt` below schema 4; so is
    /// anything that is not a JSON object.
    static func stamped(_ body: Data, sentAt date: Date) -> Data {
        guard let envelope = try? JSONDecoder().decode(ReportEnvelope.self, from: body),
              let schema = envelope.schema, schema >= 4
        else { return body }
        let milliseconds = Int((date.timeIntervalSince1970 * 1000).rounded(.down))
        if !envelope.hasSentAt, let brace = body.firstIndex(of: UInt8(ascii: "{")),
           body[body.startIndex..<brace].allSatisfy(Self.isJSONWhitespace) {
            // The object has at least `schema`, so a comma follows the new member.
            var result = Data(body[body.startIndex...brace])
            result.append(contentsOf: Array("\"sentAt\":\(milliseconds),".utf8))
            result.append(contentsOf: body[body.index(after: brace)...])
            return result
        }
        // This app never queues `sentAt`; should a body have one, its value is replaced.
        guard var object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return body }
        object["sentAt"] = milliseconds
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? body
    }

    private static func isJSONWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }

    /// The members of a report body that decide how it is stamped.
    private struct ReportEnvelope: Decodable {
        var schema: Int?
        var hasSentAt: Bool

        private enum CodingKeys: String, CodingKey { case schema, sentAt }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            schema = try? container.decodeIfPresent(Int.self, forKey: .schema)
            hasSentAt = container.contains(.sentAt)
        }
    }

    private func postJSON(_ path: String, _ object: [String: String], epoch: UInt64) async throws -> HTTPResponse {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try await perform(HTTPRequest(
            method: "POST",
            path: path,
            headers: ["Content-Type": "application/json"],
            body: try encoder.encode(object)
        ), epoch: epoch)
    }

    private struct ChallengeResponse: Decodable {
        var challenge: String
        var expiresAt: Int
    }

    private struct TokenResponse: Decodable {
        var token: String
        var expiresAt: Int
    }

    private struct ErrorResponse: Decodable {
        var error: String
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw UploadError.invalidResponse
        }
    }

    private static func errorCode(_ data: Data) -> String? {
        try? JSONDecoder().decode(ErrorResponse.self, from: data).error
    }
}
