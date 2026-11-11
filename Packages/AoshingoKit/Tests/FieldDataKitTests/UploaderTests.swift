// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
@testable import FieldDataKit
import PICSKit

private let challenge = challengeResponse
private func token(_ value: String, expires: Int = 1_794_290_000 + 21_600) -> HTTPResponse {
    tokenResponse(value, expires: expires)
}

/// Picks the longest wait of every random range, so back-off times are predictable.
let longestWait: @Sendable (ClosedRange<Double>) -> Double = { $0.upperBound }

@Suite("Report uploader")
struct UploaderTests {
    private func makeUploader(
        transport: FakeTransport,
        attestation: FakeAttestation = FakeAttestation(),
        keys: MemoryKeyStorage = MemoryKeyStorage(),
        clock: Clock = Clock()
    ) -> ReportUploader {
        ReportUploader(transport: transport, attestation: attestation, keyStorage: keys, sha256: fakeHash, now: { clock.now }, random: longestWait)
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
        #expect(keys.load() == attested("key-1"))
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
            let keys = MemoryKeyStorage(attested("old-key"))
            let uploader = makeUploader(transport: transport, keys: keys)
            #expect(try await uploader.upload(Data()) == .accepted)
            #expect(transport.paths == ["/v1/challenge", "/v1/token", "/v1/challenge", "/v1/attest", "/v1/reports"])
            #expect(keys.load() == attested("key-1"))
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
        let keys = MemoryKeyStorage(attested("stale"))
        let uploader = makeUploader(transport: transport, attestation: attestation, keys: keys)
        #expect(try await uploader.upload(Data()) == .accepted)
        #expect(!transport.paths.contains("/v1/token"))
        #expect(keys.load() == attested("key-1"))
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
        let clock = Clock()
        let uploader = makeUploader(transport: transport, clock: clock)
        #expect(try await uploader.upload(Data()) == .rejected(code: "invalid_report"))
        #expect(try await uploader.upload(Data()) == .rejected(code: "too_large"))
        await #expect(throws: UploadError.rateLimited) { try await uploader.upload(Data()) }
        clock.advance(RetryPolicy.maximumDelay)
        await #expect(throws: UploadError.server(status: 503, code: nil)) { try await uploader.upload(Data()) }
    }

    @Test("unsupported devices never contact the server; forget() drops the key")
    func unsupportedAndForget() async throws {
        let transport = FakeTransport()
        let unsupported = makeUploader(transport: transport, attestation: FakeAttestation(isSupported: false))
        #expect(!unsupported.isAttestationSupported)
        await #expect(throws: UploadError.attestationUnsupported) { try await unsupported.upload(Data()) }
        #expect(transport.requests.isEmpty)

        let keys = MemoryKeyStorage(attested("key"))
        let uploader = makeUploader(transport: transport, keys: keys)
        await uploader.forget()
        #expect(keys.load() == nil)
    }

    @Test("a malformed token response is invalidResponse; the key the server accepted is kept")
    func malformed() async throws {
        let transport = FakeTransport()
        transport.fallback["/v1/challenge"] = challenge
        transport.script("/v1/attest", HTTPResponse(status: 200, body: Data("nope".utf8)))
        let keys = MemoryKeyStorage()
        let uploader = makeUploader(transport: transport, keys: keys)
        await #expect(throws: UploadError.invalidResponse) { try await uploader.upload(Data()) }
        // The server answered 200, so the key is registered there; later attempts use /v1/token.
        #expect(keys.load() == attested("key-1"))
    }
}

@Suite("Field data pipeline")
struct PipelineTests {
    static func signalPacket(_ state: UInt8) throws -> (PICSPacket, [UInt8]) {
        var payload = [UInt8](repeating: 0, count: 11)
        payload[2] = 2
        payload[9] = 1
        payload[10] = state
        let data = PICS.companyIDBytes + payload
        return (try PICSParser.parse(manufacturerData: data), data)
    }

    static func makeUploader(
        _ transport: FakeTransport = FakeTransport(),
        attestation: FakeAttestation = FakeAttestation(),
        keys: MemoryKeyStorage = MemoryKeyStorage(),
        stateStore: any StateStore = InMemoryStateStore(),
        clock: Clock
    ) -> ReportUploader {
        ReportUploader(
            transport: transport, attestation: attestation, keyStorage: keys, stateStore: stateStore,
            sha256: fakeHash, now: { clock.now }, random: longestWait
        )
    }

    @Test("nothing is recorded while disabled; disabling deletes the queue and the key")
    func consent() async throws {
        let transport = FakeTransport()
        let keys = MemoryKeyStorage(attested("key"))
        let store = InMemoryReportStore()
        let clock = Clock()
        let uploader = Self.makeUploader(transport, keys: keys, clock: clock)
        let pipeline = FieldDataPipeline(store: store, uploader: uploader, client: "aoshingo-ios/0.1.0", now: { clock.now })
        #expect(pipeline.canUpload)

        let (packet, data) = try Self.signalPacket(0x31)
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
        let pipeline = FieldDataPipeline(store: store, uploader: Self.makeUploader(transport, clock: clock), client: "aoshingo-ios/0.1.0", now: { clock.now })
        await pipeline.setEnabled(true)
        for index in 0..<4 {
            await store.enqueue(Data("{\"n\":\(index)}".utf8), at: clock.now)
        }
        let summary = await pipeline.uploadPending()
        #expect(summary.accepted == 1)
        #expect(summary.rejected == 1)
        #expect(summary.remaining == 2)
        #expect(summary.error == .server(status: 503, code: nil))
        #expect(transport.reportBodies() == ["{\"n\":0}", "{\"n\":1}", "{\"n\":2}"])
    }

    @Test("reports older than six days are dropped before upload")
    func dropsOld() async throws {
        let transport = FakeTransport()
        let clock = Clock()
        let store = InMemoryReportStore()
        let pipeline = FieldDataPipeline(store: store, uploader: Self.makeUploader(transport, clock: clock), client: "aoshingo-ios/0.1.0", now: { clock.now })
        await pipeline.setEnabled(true)
        await store.enqueue(Data("{}".utf8), at: clock.now)
        clock.advance(FieldDataPipeline.maximumReportAge + 1)
        let summary = await pipeline.uploadPending()
        #expect(summary.remaining == 0)
        #expect(transport.requests.isEmpty)
    }

    @Test("a report the queue cannot take is kept and queued on the next flush")
    func enqueueFailure() async throws {
        let clock = Clock()
        let store = FlakyStore()
        let pipeline = FieldDataPipeline(store: store, uploader: Self.makeUploader(clock: clock), client: "aoshingo-ios/0.1.0", now: { clock.now })
        await pipeline.setEnabled(true)
        let (packet, data) = try Self.signalPacket(0x31)
        await pipeline.record(packet, manufacturerData: data, at: clock.now, rssi: -60, serviceUUIDs: [], emitter: nil, context: .init())

        await store.setFailures(enqueue: true, purge: false)
        #expect(await pipeline.flush(force: true) == false)
        #expect(await store.count() == 0)
        #expect(await pipeline.status().lastError != nil)

        await store.setFailures(enqueue: false, purge: false)
        #expect(await pipeline.flush() == true) // the window is empty, but the kept report is queued
        #expect(await store.count() == 1)
        #expect(await pipeline.flush(force: true) == false) // nothing left to queue
    }

    @Test("after a pause in reception, a changed signal is not recorded as a transition")
    func receptionPause() async throws {
        let clock = Clock()
        let pipeline = FieldDataPipeline(store: InMemoryReportStore(), uploader: Self.makeUploader(clock: clock), client: "aoshingo-ios/0.1.0", now: { clock.now })
        await pipeline.setEnabled(true)
        let (red, redData) = try Self.signalPacket(0x31)
        let (green, greenData) = try Self.signalPacket(0x33)
        await pipeline.record(red, manufacturerData: redData, at: clock.now, rssi: -60, serviceUUIDs: [], emitter: nil, context: .init())
        await pipeline.receptionDidPause()
        clock.advance(1)
        await pipeline.record(green, manufacturerData: greenData, at: clock.now, rssi: -60, serviceUUIDs: [], emitter: nil, context: .init())
        #expect(await pipeline.status().bufferedTransitions == 0)
        clock.advance(1)
        await pipeline.record(red, manufacturerData: redData, at: clock.now, rssi: -60, serviceUUIDs: [], emitter: nil, context: .init())
        #expect(await pipeline.status().bufferedTransitions == 1)
    }

    @Test("if deleting on opt-out fails, those reports are never uploaded and deletion is retried")
    func optOutDeletionFailure() async throws {
        let transport = FakeTransport()
        transport.fallback["/v1/challenge"] = challenge
        transport.script("/v1/attest", token("T1"))
        transport.fallback["/v1/reports"] = HTTPResponse(status: 202)
        let clock = Clock()
        let store = FlakyStore()
        let pipeline = FieldDataPipeline(store: store, uploader: Self.makeUploader(transport, clock: clock), client: "aoshingo-ios/0.1.0", now: { clock.now })
        await pipeline.setEnabled(true)
        try await store.enqueue(Data("{\"before\":true}".utf8), at: clock.now)

        await store.setFailures(enqueue: false, purge: true)
        clock.advance(1)
        await pipeline.setEnabled(false)
        #expect(await store.count() == 1)
        #expect(await pipeline.status().lastError != nil)

        // Opting in again while the disk still refuses deletion: the old report must not be sent.
        clock.advance(1)
        await pipeline.setEnabled(true)
        try await store.enqueue(Data("{\"after\":true}".utf8), at: clock.now)
        _ = await pipeline.uploadPending()
        #expect(transport.reportBodies() == ["{\"after\":true}"])
        #expect(try await store.pending().map { String(decoding: $0.body, as: UTF8.self) } == ["{\"before\":true}"])

        // Once deletion works again, the next chance removes it.
        await store.setFailures(enqueue: false, purge: false)
        _ = await pipeline.uploadPending()
        #expect(await store.count() == 0)
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

    @Test("the queue directory is excluded from backups")
    func excludedFromBackup() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aoshingo-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileReportStore(directory: directory)
        try await store.enqueue(Data("{}".utf8), at: Date())
        #expect(try await store.pending().count == 1)
        #if canImport(Darwin)
        let values = try directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
        #endif
    }
}
