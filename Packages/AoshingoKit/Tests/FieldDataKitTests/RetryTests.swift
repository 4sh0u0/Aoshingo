// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
@testable import FieldDataKit
import PICSKit

private let start = Date(timeIntervalSince1970: 1_794_290_000)
/// 00:00 UTC after `start`.
private let nextUTCDay = Date(timeIntervalSince1970: 1_794_355_200)

private func overCapacity() -> HTTPResponse { json(503, ["error": "over_capacity"]) }

@Suite("Retry policy")
struct RetryPolicyTests {
    @Test("exponential back-off doubles from one minute up to four hours, randomised to 50–100 %")
    func exponential() {
        let delays = (1...11).map { RetryPolicy.exponentialDelay(failures: $0) }
        #expect(delays == [60, 120, 240, 480, 960, 1920, 3840, 7680, 14_400, 14_400, 14_400])
        #expect(RetryPolicy.exponentialDelay(failures: 1000) == 14_400)

        let ranges = RangeRecorder()
        let next = RetryPolicy.nextAttempt(after: UploadError.rateLimited, failures: 3, now: start, random: ranges.record)
        #expect(ranges.recorded == [120...240])
        #expect(next == start.addingTimeInterval(240))
    }

    @Test("over capacity waits for the next UTC day plus up to an hour; a rejected attestation waits a day")
    func longWaits() {
        let ranges = RangeRecorder()
        let overCapacity = RetryPolicy.nextAttempt(after: UploadError.server(status: 503, code: "over_capacity"), failures: 1, now: start, random: ranges.record)
        #expect(overCapacity == nextUTCDay.addingTimeInterval(3600))
        let rejected = RetryPolicy.nextAttempt(after: UploadError.server(status: 401, code: "attestation_invalid"), failures: 1, now: start, random: ranges.record)
        #expect(rejected == start.addingTimeInterval(24 * 3600 + 3600))
        #expect(ranges.recorded == [0...3600, 0...3600])
        // Any other 503, and errors that are not UploadError, back off exponentially.
        #expect(RetryPolicy.kind(of: UploadError.server(status: 503, code: nil)) == .transient)
        #expect(RetryPolicy.kind(of: FakeTransport.NetworkError()) == .transient)
        #expect(RetryPolicy.startOfNextUTCDay(after: nextUTCDay) == nextUTCDay.addingTimeInterval(86_400))
    }
}

private final class RangeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var ranges: [ClosedRange<Double>] = []
    var recorded: [ClosedRange<Double>] { lock.withLock { ranges } }

    func record(_ range: ClosedRange<Double>) -> Double {
        lock.withLock { ranges.append(range) }
        return range.upperBound
    }
}

@Suite("Attestation retries")
struct AttestationRetryTests {
    private struct Fixture {
        let transport = FakeTransport()
        let attestation = FakeAttestation()
        let keys: MemoryKeyStorage
        let stateStore = InMemoryStateStore()
        let clock = Clock(start)
        let uploader: ReportUploader

        init(keys: MemoryKeyStorage = MemoryKeyStorage()) {
            self.keys = keys
            uploader = PipelineTests.makeUploader(transport, attestation: attestation, keys: keys, stateStore: stateStore, clock: clock)
        }
    }

    @Test("the challenge comes first: a server out of capacity costs no key, and is retried the next UTC day")
    func challengeFirst() async throws {
        let fixture = Fixture()
        fixture.transport.script("/v1/challenge", overCapacity())
        await #expect(throws: UploadError.server(status: 503, code: "over_capacity")) { try await fixture.uploader.upload(Data()) }
        #expect(fixture.attestation.generatedKeys == 0)
        #expect(fixture.keys.load() == nil)
        #expect(await fixture.uploader.retryNotBefore == nextUTCDay.addingTimeInterval(3600))

        // Until then, nothing is requested at all.
        fixture.clock.set(nextUTCDay)
        await #expect(throws: UploadError.backingOff(until: nextUTCDay.addingTimeInterval(3600))) { try await fixture.uploader.upload(Data()) }
        #expect(fixture.transport.paths == ["/v1/challenge"])

        fixture.clock.set(nextUTCDay.addingTimeInterval(3600))
        fixture.transport.fallback["/v1/challenge"] = challengeResponse
        fixture.transport.script("/v1/attest", tokenResponse("T1", expires: 1_794_400_000))
        fixture.transport.script("/v1/reports", HTTPResponse(status: 202))
        #expect(try await fixture.uploader.upload(Data()) == .accepted)
        #expect(fixture.attestation.generatedKeys == 1)
        #expect(await fixture.uploader.retryNotBefore == nil)
    }

    @Test("a key whose registration failed is saved as pending and reused, not regenerated")
    func pendingKeyReused() async throws {
        let fixture = Fixture()
        fixture.transport.fallback["/v1/challenge"] = challengeResponse
        fixture.transport.script("/v1/attest", HTTPResponse(status: 500), tokenResponse("T1"))
        fixture.transport.script("/v1/reports", HTTPResponse(status: 202))
        await #expect(throws: UploadError.server(status: 500, code: nil)) { try await fixture.uploader.upload(Data()) }
        #expect(fixture.keys.load() == pending("key-1"))
        #expect(await fixture.uploader.retryNotBefore == start.addingTimeInterval(60))

        fixture.clock.advance(30)
        await #expect(throws: UploadError.backingOff(until: start.addingTimeInterval(60))) { try await fixture.uploader.upload(Data()) }
        fixture.clock.advance(30)
        #expect(try await fixture.uploader.upload(Data()) == .accepted)
        #expect(fixture.attestation.generatedKeys == 1)
        #expect(fixture.attestation.attestedKeys == ["key-1", "key-1"])
        #expect(fixture.keys.load() == attested("key-1"))
        #expect(fixture.transport.paths == ["/v1/challenge", "/v1/attest", "/v1/challenge", "/v1/attest", "/v1/reports"])
    }

    @Test("a pending key that App Attest refuses to attest again is replaced by a new one")
    func pendingKeyInvalid() async throws {
        let fixture = Fixture(keys: MemoryKeyStorage(pending("key-0")))
        fixture.attestation.unattestableKeys = ["key-0"]
        fixture.transport.fallback["/v1/challenge"] = challengeResponse
        fixture.transport.script("/v1/attest", tokenResponse("T1"))
        fixture.transport.script("/v1/reports", HTTPResponse(status: 202))
        #expect(try await fixture.uploader.upload(Data()) == .accepted)
        #expect(fixture.attestation.generatedKeys == 1)
        #expect(fixture.keys.load() == attested("key-1"))
        #expect(fixture.transport.paths == ["/v1/challenge", "/v1/attest", "/v1/reports"])
        #expect(fixture.transport.bodies("/v1/attest").first?["keyId"] as? String == "key-1")
    }

    @Test("a new key that cannot be attested is not retried at once")
    func newKeyInvalid() async throws {
        let fixture = Fixture()
        fixture.attestation.unattestableKeys = ["key-1"]
        fixture.transport.fallback["/v1/challenge"] = challengeResponse
        await #expect(throws: AttestationError.invalidKey) { try await fixture.uploader.upload(Data()) }
        #expect(fixture.attestation.generatedKeys == 1)
        #expect(fixture.keys.load() == nil)
        #expect(await fixture.uploader.retryNotBefore == start.addingTimeInterval(60))
    }

    @Test("App Attest's serverUnavailable keeps the key for later; other App Attest errors discard it")
    func attestKeyErrors() async throws {
        struct SystemFailure: Error {}
        let fixture = Fixture()
        fixture.transport.fallback["/v1/challenge"] = challengeResponse
        fixture.attestation.attestErrors = [AttestationError.serverUnavailable, SystemFailure()]
        await #expect(throws: AttestationError.serverUnavailable) { try await fixture.uploader.upload(Data()) }
        #expect(fixture.keys.load() == pending("key-1"))
        #expect(await fixture.uploader.retryNotBefore == start.addingTimeInterval(60))

        fixture.clock.advance(60)
        await #expect(throws: SystemFailure.self) { try await fixture.uploader.upload(Data()) }
        #expect(fixture.keys.load() == nil)
        #expect(fixture.attestation.generatedKeys == 1)
        #expect(await fixture.uploader.retryNotBefore == start.addingTimeInterval(60 + 120))

        fixture.clock.advance(120)
        fixture.transport.script("/v1/attest", tokenResponse("T1"))
        fixture.transport.script("/v1/reports", HTTPResponse(status: 202))
        #expect(try await fixture.uploader.upload(Data()) == .accepted)
        #expect(fixture.keys.load() == attested("key-2"))
        #expect(!fixture.transport.paths.dropLast(2).contains("/v1/attest")) // nothing was posted for key-1
    }

    @Test("401 attestation_invalid discards the key and stops for a day")
    func attestationRejected() async throws {
        let fixture = Fixture()
        fixture.transport.fallback["/v1/challenge"] = challengeResponse
        fixture.transport.fallback["/v1/attest"] = json(401, ["error": "attestation_invalid"])
        await #expect(throws: UploadError.server(status: 401, code: "attestation_invalid")) { try await fixture.uploader.upload(Data()) }
        #expect(fixture.keys.load() == nil)
        let resume = start.addingTimeInterval(24 * 3600 + 3600)
        #expect(await fixture.uploader.retryNotBefore == resume)

        fixture.clock.advance(24 * 3600)
        await #expect(throws: UploadError.backingOff(until: resume)) { try await fixture.uploader.upload(Data()) }
        #expect(fixture.transport.count("/v1/attest") == 1)

        fixture.clock.set(resume)
        await #expect(throws: UploadError.server(status: 401, code: "attestation_invalid")) { try await fixture.uploader.upload(Data()) }
        #expect(fixture.attestation.generatedKeys == 2)
        #expect(await fixture.uploader.retryNotBefore == resume.addingTimeInterval(24 * 3600 + 3600))
    }

    @Test("409 key_exists means an earlier registration arrived: the key is used through /v1/token")
    func keyExists() async throws {
        let fixture = Fixture(keys: MemoryKeyStorage(pending("key-0")))
        fixture.transport.fallback["/v1/challenge"] = challengeResponse
        fixture.transport.script("/v1/attest", json(409, ["error": "key_exists"]))
        fixture.transport.script("/v1/token", tokenResponse("T2"))
        fixture.transport.script("/v1/reports", HTTPResponse(status: 202))
        #expect(try await fixture.uploader.upload(Data()) == .accepted)
        #expect(fixture.keys.load() == attested("key-0"))
        #expect(fixture.attestation.generatedKeys == 0)
        #expect(fixture.transport.paths == ["/v1/challenge", "/v1/attest", "/v1/challenge", "/v1/token", "/v1/reports"])
        #expect(fixture.transport.requests.last?.headers["Authorization"] == "Bearer T2")
    }

    @Test("failures back off exponentially; a success resets the back-off")
    func exponentialBackOff() async throws {
        let fixture = Fixture()
        fixture.transport.fallback["/v1/challenge"] = challengeResponse
        fixture.transport.fallback["/v1/attest"] = tokenResponse("T1", expires: 1_794_290_000 + 30 * 86_400)
        fixture.transport.fallback["/v1/reports"] = HTTPResponse(status: 502)
        var waits: [TimeInterval] = []
        for _ in 0..<10 {
            await #expect(throws: UploadError.server(status: 502, code: nil)) { try await fixture.uploader.upload(Data()) }
            let notBefore = try #require(await fixture.uploader.retryNotBefore)
            waits.append(notBefore.timeIntervalSince(fixture.clock.now))
            fixture.clock.set(notBefore)
        }
        #expect(waits == [60, 120, 240, 480, 960, 1920, 3840, 7680, 14_400, 14_400])
        #expect(fixture.attestation.generatedKeys == 1)

        fixture.transport.script("/v1/reports", HTTPResponse(status: 202), HTTPResponse(status: 502))
        #expect(try await fixture.uploader.upload(Data()) == .accepted)
        #expect(await fixture.uploader.retryNotBefore == nil)
        _ = try? await fixture.uploader.upload(Data())
        #expect(await fixture.uploader.retryNotBefore == fixture.clock.now.addingTimeInterval(60))
    }

    @Test("network errors and 429 back off too; over capacity on upload waits for the next UTC day")
    func otherFailures() async throws {
        let fixture = Fixture()
        fixture.transport.fallback["/v1/challenge"] = challengeResponse
        fixture.transport.setNetworkFailure("/v1/challenge", true)
        await #expect(throws: FakeTransport.NetworkError.self) { try await fixture.uploader.upload(Data()) }
        #expect(await fixture.uploader.retryNotBefore == start.addingTimeInterval(60))
        #expect(fixture.attestation.generatedKeys == 0)

        fixture.transport.setNetworkFailure("/v1/challenge", false)
        fixture.clock.advance(60)
        fixture.transport.fallback["/v1/attest"] = tokenResponse("T1")
        fixture.transport.script("/v1/reports", json(429, ["error": "rate_limited"]), overCapacity())
        await #expect(throws: UploadError.rateLimited) { try await fixture.uploader.upload(Data()) }
        #expect(await fixture.uploader.retryNotBefore == start.addingTimeInterval(60 + 120))
        fixture.clock.advance(120)
        await #expect(throws: UploadError.server(status: 503, code: "over_capacity")) { try await fixture.uploader.upload(Data()) }
        #expect(await fixture.uploader.retryNotBefore == nextUTCDay.addingTimeInterval(3600))
    }

    @Test("the back-off survives a relaunch but not an opt-out")
    func persistence() async throws {
        let fixture = Fixture()
        fixture.transport.fallback["/v1/challenge"] = HTTPResponse(status: 500)
        await #expect(throws: UploadError.server(status: 500, code: nil)) { try await fixture.uploader.upload(Data()) }

        // A new uploader on the same storage, as after a relaunch.
        let relaunched = PipelineTests.makeUploader(fixture.transport, keys: fixture.keys, stateStore: fixture.stateStore, clock: fixture.clock)
        await #expect(throws: UploadError.backingOff(until: start.addingTimeInterval(60))) { try await relaunched.upload(Data()) }
        #expect(fixture.transport.count("/v1/challenge") == 1)

        let pipeline = FieldDataPipeline(store: InMemoryReportStore(), uploader: relaunched, client: "aoshingo-ios/0.1.0", stateStore: fixture.stateStore, now: { fixture.clock.now })
        await pipeline.setEnabled(true)
        await pipeline.setEnabled(false)
        #expect(await relaunched.retryNotBefore == nil)
        #expect(fixture.stateStore.data(forKey: ReportUploader.retryStateKey) == nil)
        await #expect(throws: UploadError.server(status: 500, code: nil)) { try await relaunched.upload(Data()) }
        #expect(fixture.transport.count("/v1/challenge") == 2)
    }

    @Test("while backing off, the pipeline sends nothing and keeps the error that caused it")
    func pipelineBackingOff() async throws {
        let fixture = Fixture()
        fixture.transport.fallback["/v1/challenge"] = overCapacity()
        let store = InMemoryReportStore()
        let pipeline = FieldDataPipeline(store: store, uploader: fixture.uploader, client: "aoshingo-ios/0.1.0", now: { fixture.clock.now })
        await pipeline.setEnabled(true)
        await store.enqueue(Data("{}".utf8), at: fixture.clock.now)
        #expect(await pipeline.uploadPending().error == .server(status: 503, code: "over_capacity"))
        let error = await pipeline.status().lastError
        for _ in 0..<5 {
            fixture.clock.advance(60)
            let summary = await pipeline.uploadPending()
            #expect(summary.error == .backingOff(until: nextUTCDay.addingTimeInterval(3600)))
            #expect(summary.remaining == 1)
        }
        #expect(fixture.transport.requests.count == 1)
        #expect(await pipeline.status().lastError == error)
    }
}

@Suite("Uploading unavailable")
struct UnavailableTests {
    @Test("without a configured server, collection stays off and nothing is kept")
    func noServer() async throws {
        let store = InMemoryReportStore()
        await store.enqueue(Data("{}".utf8), at: Date()) // left by an earlier build
        let pipeline = FieldDataPipeline(store: store, uploader: nil, client: "aoshingo-ios/0.1.0")
        #expect(!pipeline.canUpload)
        await pipeline.setEnabled(true)
        #expect(await pipeline.isEnabled == false)
        #expect(await store.count() == 0)

        let (packet, data) = try PipelineTests.signalPacket(0x31)
        await pipeline.record(packet, manufacturerData: data, at: Date(), rssi: -60, serviceUUIDs: [], emitter: nil, context: .init())
        #expect(await pipeline.status().bufferedObservations == 0)
        #expect(await pipeline.flush(force: true) == false)
        #expect(await pipeline.uploadPending().remaining == 0)
    }

    @Test("without App Attest, collection stays off and the server is never contacted")
    func noAttestation() async throws {
        let transport = FakeTransport()
        let clock = Clock()
        let uploader = PipelineTests.makeUploader(transport, attestation: FakeAttestation(isSupported: false), clock: clock)
        let store = InMemoryReportStore()
        let pipeline = FieldDataPipeline(store: store, uploader: uploader, client: "aoshingo-ios/0.1.0", now: { clock.now })
        #expect(!pipeline.canUpload)
        await pipeline.setEnabled(true)
        #expect(await pipeline.isEnabled == false)
        await store.enqueue(Data("{}".utf8), at: clock.now)
        #expect(await pipeline.uploadPending().remaining == 1)
        #expect(transport.requests.isEmpty)
        await pipeline.setEnabled(true)
        #expect(await store.count() == 0)
    }

    @Test("expired reports are deleted at launch and on consent, even when nothing can be sent")
    func expiryWithoutUpload() async throws {
        let transport = FakeTransport()
        transport.fallback["/v1/challenge"] = HTTPResponse(status: 500)
        let clock = Clock()
        let uploader = PipelineTests.makeUploader(transport, clock: clock)
        let store = InMemoryReportStore()
        await store.enqueue(Data("{\"old\":true}".utf8), at: clock.now)
        clock.advance(FieldDataPipeline.maximumReportAge + 1)
        await store.enqueue(Data("{\"new\":true}".utf8), at: clock.now)

        let pipeline = FieldDataPipeline(store: store, uploader: uploader, client: "aoshingo-ios/0.1.0", now: { clock.now })
        await pipeline.setEnabled(true) // as at launch with consent given
        #expect(await store.pending().map { String(decoding: $0.body, as: UTF8.self) } == ["{\"new\":true}"])
        #expect(transport.requests.isEmpty)
    }
}

@Suite("Opt-out deletion cutoff")
struct PurgeCutoffTests {
    @Test("the cutoff survives a relaunch, and is cleared only once the deletion succeeded")
    func relaunch() async throws {
        let transport = FakeTransport()
        transport.fallback["/v1/challenge"] = challengeResponse
        transport.fallback["/v1/attest"] = tokenResponse("T1")
        transport.fallback["/v1/reports"] = HTTPResponse(status: 202)
        let clock = Clock()
        let store = FlakyStore()
        let stateStore = InMemoryStateStore()
        func launch() -> FieldDataPipeline {
            FieldDataPipeline(
                store: store,
                uploader: PipelineTests.makeUploader(transport, stateStore: stateStore, clock: clock),
                client: "aoshingo-ios/0.1.0",
                stateStore: stateStore,
                now: { clock.now }
            )
        }

        let first = launch()
        await first.setEnabled(true)
        try await store.enqueue(Data("{\"before\":true}".utf8), at: clock.now)
        await store.setFailures(enqueue: false, purge: true)
        clock.advance(1)
        await first.setEnabled(false)
        #expect(stateStore.data(forKey: FieldDataPipeline.purgeCutoffKey) != nil)

        // Opted in again and relaunched while the disk still refuses deletion.
        clock.advance(10)
        let second = launch()
        await second.setEnabled(true)
        try await store.enqueue(Data("{\"after\":true}".utf8), at: clock.now)
        _ = await second.uploadPending()
        #expect(transport.reportBodies() == ["{\"after\":true}"])
        #expect(await store.count() == 1)

        await store.setFailures(enqueue: false, purge: false)
        let third = launch()
        await third.setEnabled(true)
        #expect(await store.count() == 0)
        #expect(stateStore.data(forKey: FieldDataPipeline.purgeCutoffKey) == nil)
        #expect(transport.reportBodies() == ["{\"after\":true}"])
    }

    @Test("a second failed opt-out moves the cutoff forward")
    func secondOptOut() async throws {
        let transport = FakeTransport()
        transport.fallback["/v1/challenge"] = challengeResponse
        transport.fallback["/v1/attest"] = tokenResponse("T1")
        transport.fallback["/v1/reports"] = HTTPResponse(status: 202)
        let clock = Clock()
        let store = FlakyStore()
        let pipeline = FieldDataPipeline(store: store, uploader: PipelineTests.makeUploader(transport, clock: clock), client: "aoshingo-ios/0.1.0", now: { clock.now })
        await store.setFailures(enqueue: false, purge: true)
        await pipeline.setEnabled(true)
        await pipeline.setEnabled(false) // first failed deletion

        clock.advance(60)
        await pipeline.setEnabled(true)
        try await store.enqueue(Data("{\"between\":true}".utf8), at: clock.now)
        clock.advance(60)
        await pipeline.setEnabled(false) // second failed deletion: "between" must never be sent

        clock.advance(60)
        await pipeline.setEnabled(true)
        _ = await pipeline.uploadPending()
        #expect(transport.count("/v1/reports") == 0)
    }

    @Test("a successful opt-out deletion clears a persisted cutoff")
    func clearedOnSuccess() async throws {
        let stateStore = InMemoryStateStore()
        let clock = Clock()
        let store = FlakyStore()
        let pipeline = FieldDataPipeline(store: store, uploader: PipelineTests.makeUploader(clock: clock), client: "aoshingo-ios/0.1.0", stateStore: stateStore, now: { clock.now })
        await store.setFailures(enqueue: false, purge: true)
        await pipeline.setEnabled(false)
        #expect(stateStore.data(forKey: FieldDataPipeline.purgeCutoffKey) != nil)
        await store.setFailures(enqueue: false, purge: false)
        await pipeline.setEnabled(false)
        #expect(stateStore.data(forKey: FieldDataPipeline.purgeCutoffKey) == nil)
    }
}

@Suite("State store")
struct StateStoreTests {
    @Test("UserDefaults store round-trips and removes values under its prefix")
    func userDefaults() {
        let store = UserDefaultsStateStore(prefix: "aoshingo-tests-\(UUID().uuidString).")
        #expect(store.data(forKey: "a") == nil)
        store.set(Data([1, 2, 3]), forKey: "a")
        #expect(store.data(forKey: "a") == Data([1, 2, 3]))
        store.setValue(RetryState(failures: 2, notBefore: start), forKey: "retry")
        #expect(store.value(RetryState.self, forKey: "retry") == RetryState(failures: 2, notBefore: start))
        store.set(nil, forKey: "a")
        store.set(nil, forKey: "retry")
        #expect(store.data(forKey: "a") == nil)
        #expect(store.data(forKey: "retry") == nil)
    }
}
