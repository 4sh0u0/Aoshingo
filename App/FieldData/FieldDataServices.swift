// SPDX-License-Identifier: Apache-2.0

import CryptoKit
@preconcurrency import DeviceCheck
import FieldDataKit
import Foundation
import Security

/// App Attest through `DCAppAttestService`.
struct AppAttestProvider: AttestationProvider {
    var isSupported: Bool { DCAppAttestService.shared.isSupported }

    func generateKey() async throws -> String {
        try await DCAppAttestService.shared.generateKey()
    }

    func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data {
        do {
            return try await DCAppAttestService.shared.attestKey(keyID, clientDataHash: clientDataHash)
        } catch let error as DCError where error.code == .invalidKey {
            throw AttestationError.invalidKey
        } catch let error as DCError where error.code == .serverUnavailable {
            throw AttestationError.serverUnavailable
        }
    }

    func generateAssertion(_ keyID: String, clientDataHash: Data) async throws -> Data {
        do {
            return try await DCAppAttestService.shared.generateAssertion(keyID, clientDataHash: clientDataHash)
        } catch let error as DCError where error.code == .invalidKey {
            throw AttestationError.invalidKey
        }
    }
}

/// Stores the App Attest key ID and whether the server has accepted it in the Keychain, on this
/// device only (App Attest keys cannot move).
struct KeychainKeyIDStorage: KeyIDStorage {
    private let service = "es.4sh.aoshingo.appattest"
    private let account = "keyId"

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    func load() -> AttestKey? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        if let key = try? JSONDecoder().decode(AttestKey.self, from: data) { return key }
        // Earlier versions stored the bare key ID, and only once the server had accepted it.
        guard let keyID = String(data: data, encoding: .utf8), !keyID.isEmpty else { return nil }
        return AttestKey(id: keyID, isAttested: true)
    }

    func save(_ key: AttestKey?) {
        SecItemDelete(baseQuery as CFDictionary)
        guard let key, let data = try? JSONEncoder().encode(key) else { return }
        var item = baseQuery
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }
}

/// HTTPS transport with an ephemeral session: no cookies, no cache, no credential storage.
struct URLSessionTransport: HTTPTransport {
    let baseURL: URL
    private let session: URLSession

    init(baseURL: URL) {
        self.baseURL = baseURL
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.httpAdditionalHeaders = ["User-Agent": "Aoshingo"]
        session = URLSession(configuration: configuration)
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        var urlRequest = URLRequest(url: baseURL.appendingPathComponent(request.path))
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        let (data, response) = try await session.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else { throw UploadError.invalidResponse }
        return HTTPResponse(status: http.statusCode, body: data)
    }
}

enum Digest {
    static func sha256(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }
}

enum ReportServer {
    /// `https://<AoshingoReportHost>` from Info.plist (build setting `AOSHINGO_REPORT_HOST`),
    /// or `nil` when this build has no server configured.
    static var baseURL: URL? {
        guard let host = Bundle.main.object(forInfoDictionaryKey: "AoshingoReportHost") as? String else { return nil }
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("$("), !trimmed.contains("/") else { return nil }
        return URL(string: "https://\(trimmed)")
    }
}
