// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
@testable import FieldDataKit
import PICSKit

/// Opting out while an upload or a flush is suspended half-way. On the code before the generation
/// checks, the suspended work resumed after `forget()` and re-saved the key, kept the token and sent
/// the report, or left a report on disk.
@Suite("Opt-out during upload")
struct OptOutRaceTests {
    private struct Fixture {
        let transport: FakeTransport
        let attestation = FakeAttestation()
        let keys = MemoryKeyStorage()
        let clock = Clock()
        let store = InMemoryReportStore()
        let uploader: ReportUploader
        let pipeline: FieldDataPipeline

        init() {
            let transport = FakeTransport()
            transport.fallback["/v1/challenge"] = challengeResponse
            transport.fallback["/v1/attest"] = tokenResponse("T1")
            transport.fallback["/v1/token"] = tokenResponse("T2")
            transport.fallback["/v1/reports"] = HTTPResponse(status: 202)
            self.transport = transport
            let stateStore = InMemoryStateStore()
            let clock = clock
            uploader = PipelineTests.makeUploader(transport, attestation: attestation, keys: keys, stateStore: stateStore, clock: clock)
            pipeline = FieldDataPipeline(store: store, uploader: uploader, client: "aoshingo-ios/0.1.0", stateStore: stateStore, now: { clock.now })
        }
    }

    @Test("opting out during first-time attestation sends nothing and keeps no key or token")
    func duringAttestation() async throws {
        let fixture = Fixture()
        let gate = Gate() // App Attest calls cannot be cancelled
        fixture.attestation.attestGate = gate
        await fixture.pipeline.setEnabled(true)
        await fixture.store.enqueue(Data("{\"n\":1}".utf8), at: fixture.clock.now)

        let upload = Task { await fixture.pipeline.uploadPending() }
        try await eventually("attestation started") { gate.arrivalCount == 1 }
        #expect(fixture.keys.load() == pending("key-1")) // saved as soon as it was generated

        let optOut = Task { await fixture.pipeline.setEnabled(false) }
        try await eventually("key forgotten") { fixture.keys.deletions >= 1 }
        gate.open()
        let summary = await upload.value
        await optOut.value

        #expect(summary.error == .cancelled)
        #expect(fixture.transport.paths == ["/v1/challenge"])
        #expect(fixture.keys.load() == nil)
        #expect(await fixture.uploader.retryNotBefore == nil)
        #expect(await fixture.store.count() == 0)

        // No token survived: opting in again attests a new key before anything is sent.
        await fixture.pipeline.setEnabled(true)
        await fixture.store.enqueue(Data("{\"n\":2}".utf8), at: fixture.clock.now)
        #expect(await fixture.pipeline.uploadPending().accepted == 1)
        #expect(fixture.transport.paths == ["/v1/challenge", "/v1/challenge", "/v1/attest", "/v1/reports"])
        #expect(fixture.transport.reportBodies() == ["{\"n\":2}"])
        #expect(fixture.keys.load() == attested("key-2"))
    }

    @Test("opting out while the attestation is being registered: the late 200 stores nothing")
    func duringRegistration() async throws {
        let fixture = Fixture()
        let gate = Gate() // the response arrives after the opt-out started
        fixture.transport.hold("/v1/attest", at: gate)
        await fixture.pipeline.setEnabled(true)
        await fixture.store.enqueue(Data("{}".utf8), at: fixture.clock.now)

        let upload = Task { await fixture.pipeline.uploadPending() }
        try await eventually("attestation posted") { gate.arrivalCount == 1 }
        let optOut = Task { await fixture.pipeline.setEnabled(false) }
        try await eventually("key forgotten") { fixture.keys.deletions >= 1 }
        gate.open()
        _ = await upload.value
        await optOut.value

        #expect(fixture.transport.count("/v1/reports") == 0)
        #expect(fixture.keys.load() == nil)
        // The token from that 200 was not kept either.
        await fixture.pipeline.setEnabled(true)
        await fixture.store.enqueue(Data("{}".utf8), at: fixture.clock.now)
        _ = await fixture.pipeline.uploadPending()
        #expect(fixture.transport.paths.suffix(3) == ["/v1/challenge", "/v1/attest", "/v1/reports"])
    }

    @Test("setEnabled(false) cancels a request in flight and returns; nothing is sent after it")
    func cancelsInFlightRequest() async throws {
        let fixture = Fixture()
        let gate = Gate(honoursCancellation: true) // like URLSession
        fixture.transport.hold("/v1/reports", at: gate)
        await fixture.pipeline.setEnabled(true)
        for index in 0..<3 {
            await fixture.store.enqueue(Data("{\"n\":\(index)}".utf8), at: fixture.clock.now)
        }

        let upload = Task { await fixture.pipeline.uploadPending() }
        try await eventually("first report in flight") { gate.arrivalCount == 1 }
        await fixture.pipeline.setEnabled(false) // returns without the gate being opened
        let requestsAtOptOut = fixture.transport.requests.count
        gate.open()
        let summary = await upload.value

        #expect(summary.error == .cancelled)
        #expect(fixture.transport.requests.count == requestsAtOptOut)
        #expect(fixture.transport.count("/v1/reports") == 1)
        #expect(fixture.keys.load() == nil)
        #expect(await fixture.uploader.retryNotBefore == nil)
        #expect(await fixture.store.count() == 0)
    }

    @Test("a report being written when the user opts out is deleted with the rest")
    func duringEnqueue() async throws {
        let clock = Clock()
        let store = FlakyStore()
        let keys = MemoryKeyStorage()
        let pipeline = FieldDataPipeline(store: store, uploader: PipelineTests.makeUploader(keys: keys, clock: clock), client: "aoshingo-ios/0.1.0", now: { clock.now })
        await pipeline.setEnabled(true)
        let (packet, data) = try PipelineTests.signalPacket(0x31)
        await pipeline.record(packet, manufacturerData: data, at: clock.now, rssi: -60, serviceUUIDs: [], emitter: nil, context: .init())
        let gate = Gate()
        await store.setEnqueueGate(gate)

        let flush = Task { await pipeline.flush(force: true) }
        try await eventually("report being written") { gate.arrivalCount == 1 }
        let optOut = Task { await pipeline.setEnabled(false) }
        try await eventually("key forgotten") { keys.deletions >= 1 }
        gate.open()
        _ = await flush.value
        await optOut.value

        #expect(await store.count() == 0)
        #expect(await pipeline.status().bufferedObservations == 0)
    }

    @Test("a flush (as when the app goes to the background) does not wait for a slow upload")
    func flushDuringUpload() async throws {
        let fixture = Fixture()
        let gate = Gate()
        fixture.transport.hold("/v1/reports", at: gate)
        await fixture.pipeline.setEnabled(true)
        await fixture.store.enqueue(Data("{}".utf8), at: fixture.clock.now)
        let upload = Task { await fixture.pipeline.uploadPending() }
        try await eventually("report in flight") { gate.arrivalCount == 1 }

        let (packet, data) = try PipelineTests.signalPacket(0x31)
        await fixture.pipeline.record(packet, manufacturerData: data, at: fixture.clock.now, rssi: -60, serviceUUIDs: [], emitter: nil, context: .init())
        #expect(await fixture.pipeline.flush(force: true))
        #expect(await fixture.store.count() == 2)

        gate.open()
        #expect(await upload.value.accepted == 1)
    }

    @Test("forget() during an upload makes it throw cancelled without storing a key, token or back-off")
    func uploaderForget() async throws {
        let transport = FakeTransport()
        transport.fallback["/v1/challenge"] = challengeResponse
        transport.fallback["/v1/attest"] = tokenResponse("T1")
        transport.fallback["/v1/reports"] = HTTPResponse(status: 202)
        let attestation = FakeAttestation()
        let gate = Gate()
        attestation.attestGate = gate
        let keys = MemoryKeyStorage()
        let stateStore = InMemoryStateStore()
        let clock = Clock()
        let uploader = PipelineTests.makeUploader(transport, attestation: attestation, keys: keys, stateStore: stateStore, clock: clock)

        let upload = Task { try await uploader.upload(Data()) }
        try await eventually("attestation started") { gate.arrivalCount == 1 }
        await uploader.forget()
        gate.open()
        await #expect(throws: UploadError.cancelled) { try await upload.value }
        #expect(keys.load() == nil)
        #expect(transport.paths == ["/v1/challenge"])
        #expect(stateStore.data(forKey: ReportUploader.retryStateKey) == nil)
    }
}
