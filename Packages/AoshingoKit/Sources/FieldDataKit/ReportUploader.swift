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
    /// The key can no longer be used (for example after a restore to another device).
    case invalidKey
}

/// Persists the App Attest key ID (Keychain on iOS). The key ID never travels with report data.
public protocol KeyIDStorage: Sendable {
    func load() -> String?
    func save(_ keyID: String?)
}

public enum UploadError: Error, Sendable, Equatable {
    case attestationUnsupported
    case rateLimited
    case invalidResponse
    case server(status: Int, code: String?)
}

public enum UploadOutcome: Sendable, Equatable {
    case accepted
    /// The server refused this report permanently (for example `invalid_report`); drop it.
    case rejected(code: String?)
}

/// Uploads reports, obtaining short-lived upload tokens through App Attest.
public actor ReportUploader {
    /// Tokens are refreshed when they have less than this many seconds left.
    public static let tokenRefreshMargin: TimeInterval = 60

    private let transport: any HTTPTransport
    private let attestation: any AttestationProvider
    private let keyStorage: any KeyIDStorage
    private let sha256: @Sendable (Data) -> Data
    private let now: @Sendable () -> Date
    private var token: (value: String, expiresAt: Date)?

    public init(
        transport: any HTTPTransport,
        attestation: any AttestationProvider,
        keyStorage: any KeyIDStorage,
        sha256: @escaping @Sendable (Data) -> Data,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.transport = transport
        self.attestation = attestation
        self.keyStorage = keyStorage
        self.sha256 = sha256
        self.now = now
    }

    /// Uploads one encoded report. Throws for retryable failures.
    public func upload(_ body: Data) async throws -> UploadOutcome {
        guard attestation.isSupported else { throw UploadError.attestationUnsupported }
        var response = try await postReport(body, token: try await validToken())
        if response.status == 401 {
            token = nil
            response = try await postReport(body, token: try await validToken())
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

    /// Forgets the token and the App Attest key ID (when the user turns collection off).
    public func forget() {
        token = nil
        keyStorage.save(nil)
    }

    // MARK: - Tokens

    private func validToken() async throws -> String {
        if let token, token.expiresAt.timeIntervalSince(now()) > Self.tokenRefreshMargin {
            return token.value
        }
        if let keyID = keyStorage.load() {
            if let refreshed = try await refreshToken(keyID: keyID) {
                return store(refreshed)
            }
            keyStorage.save(nil)
        }
        return store(try await attestNewKey())
    }

    private func store(_ response: TokenResponse) -> String {
        token = (response.token, Date(timeIntervalSince1970: TimeInterval(response.expiresAt)))
        return response.token
    }

    /// Returns `nil` when the key is unknown to the server or no longer valid, so a new key is attested.
    private func refreshToken(keyID: String) async throws -> TokenResponse? {
        let challenge = try await fetchChallenge()
        let assertion: Data
        do {
            assertion = try await attestation.generateAssertion(keyID, clientDataHash: sha256(Data(challenge.utf8)))
        } catch AttestationError.invalidKey {
            return nil
        }
        let response = try await postJSON("/v1/token", [
            "keyId": keyID,
            "assertion": assertion.base64EncodedString(),
            "challenge": challenge,
        ])
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

    private func attestNewKey() async throws -> TokenResponse {
        let keyID = try await attestation.generateKey()
        let challenge = try await fetchChallenge()
        let attestationObject = try await attestation.attestKey(keyID, clientDataHash: sha256(Data(challenge.utf8)))
        let response = try await postJSON("/v1/attest", [
            "keyId": keyID,
            "attestation": attestationObject.base64EncodedString(),
            "challenge": challenge,
        ])
        switch response.status {
        case 200:
            let token = try Self.decode(TokenResponse.self, response.body)
            keyStorage.save(keyID)
            return token
        case 429:
            throw UploadError.rateLimited
        default:
            throw UploadError.server(status: response.status, code: Self.errorCode(response.body))
        }
    }

    private func fetchChallenge() async throws -> String {
        let response = try await transport.send(HTTPRequest(
            method: "POST",
            path: "/v1/challenge",
            headers: ["Content-Type": "application/json"],
            body: Data("{}".utf8)
        ))
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

    private func postReport(_ body: Data, token: String) async throws -> HTTPResponse {
        try await transport.send(HTTPRequest(
            method: "POST",
            path: "/v1/reports",
            headers: ["Content-Type": "application/json", "Authorization": "Bearer \(token)"],
            body: body
        ))
    }

    private func postJSON(_ path: String, _ object: [String: String]) async throws -> HTTPResponse {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try await transport.send(HTTPRequest(
            method: "POST",
            path: path,
            headers: ["Content-Type": "application/json"],
            body: try encoder.encode(object)
        ))
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
