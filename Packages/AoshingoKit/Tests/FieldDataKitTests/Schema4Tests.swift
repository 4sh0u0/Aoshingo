// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
@testable import FieldDataKit
import PICSKit

private let t0 = 1_794_290_000

private func at(_ offset: Double) -> Date { Date(timeIntervalSince1970: Double(t0) + offset) }

/// A Type 2 message of intersection 00000001 with one signal byte per slot.
private func signalPacket(_ states: [UInt8]) throws -> (PICSPacket, [UInt8]) {
    var payload = [UInt8](repeating: 0, count: 10) + states
    payload[2] = 2
    payload[9] = 1
    let data = PICS.companyIDBytes + payload
    return (try PICSParser.parse(manufacturerData: data), data)
}

@Suite("Report schema 4")
struct Schema4Tests {
    @Test("ms is the sub-second part of the time, rounded down to 100 ms")
    func subsecond() {
        #expect(Bucketing.subsecondMilliseconds(at(0)) == 0)
        #expect(Bucketing.subsecondMilliseconds(at(0.05)) == 0)
        #expect(Bucketing.subsecondMilliseconds(at(0.1)) == 100)
        #expect(Bucketing.subsecondMilliseconds(at(1.7)) == 700)
        #expect(Bucketing.subsecondMilliseconds(at(2.95)) == 900)
        #expect(Bucketing.subsecondMilliseconds(at(3.999)) == 900)
        #expect(Bucketing.seconds(at(3.999)) == t0 + 3)
    }

    @Test("the collector sets t and ms of transitions and steps from the packet time")
    func collectorMS() throws {
        var collector = FieldCollector()
        // Red, then green at 1.25 s (a transition), then green with one step less at 2.5 s (a step).
        let timeline: [(Double, UInt8)] = [(0, 0x71), (1.25, 0x73), (2.5, 0x63)]
        for (time, byte) in timeline {
            let (packet, data) = try signalPacket([byte])
            collector.record(packet, manufacturerData: data, at: at(time), rssi: -60)
        }
        let intersection = try #require(collector.makeReport(client: nil)?.intersections.first)
        let transition = try #require(intersection.transitions.first)
        #expect(transition.t == t0 + 1 && transition.ms == 200)
        let step = try #require(intersection.steps.first)
        #expect(step.t == t0 + 2 && step.ms == 500)
    }

    @Test("ms is encoded as an explicit null; schema 4 is the current schema")
    func encoding() throws {
        let transition = FieldReport.Transition(t: t0, slot: 1, from: .red, to: .green)
        #expect(String(decoding: try FieldReport.makeEncoder().encode(transition), as: UTF8.self).contains("\"ms\":null"))
        let step = FieldReport.Step(t: t0, ms: 300, slot: 1, state: .green, from: 8, to: 7)
        #expect(String(decoding: try FieldReport.makeEncoder().encode(step), as: UTF8.self).contains("\"ms\":300"))
        #expect(FieldReport.schemaVersion == 4)
        #expect(FieldReport(client: nil, intersections: []).schema == 4)
    }

    @Test("a stored schema 3 body without ms still decodes; a schema 4 body decodes its ms")
    func decoding() throws {
        let schema3 = """
        {"schema":3,"client":"aoshingo-ios/0.2.0","intersections":[{"id":"00000001","serviceUUIDs":[],"emitters":1,
        "emitterInfo":[{"txPower":null,"connectable":null}],"observations":[],
        "transitions":[{"t":1794290005,"slot":1,"from":"Red","to":"Green","emitter":0,"gap":300,"held":42100,"cycle":98700}],
        "steps":[{"t":1794290009,"slot":1,"state":"Green","from":8,"to":7,"emitter":0,"held":3900}],
        "packets":[],"coverage":[],"labels":[]}]}
        """
        let old = try JSONDecoder().decode(FieldReport.self, from: Data(schema3.utf8))
        #expect(old.schema == 3)
        #expect(old.intersections[0].transitions[0].ms == nil)
        #expect(old.intersections[0].transitions[0].cycle == 98_700)
        #expect(old.intersections[0].steps[0].ms == nil)

        let schema4 = """
        {"schema":4,"sentAt":1794290240123,"intersections":[{"id":"00000001","serviceUUIDs":[],"emitters":0,
        "transitions":[{"t":1794290005,"ms":400,"slot":1,"from":"Red","to":"Green"}],
        "steps":[{"t":1794290009,"ms":null,"slot":1,"state":"Green","from":8,"to":7}]}]}
        """
        let new = try JSONDecoder().decode(FieldReport.self, from: Data(schema4.utf8))
        #expect(new.schema == 4)
        #expect(new.intersections[0].transitions[0].ms == 400)
        #expect(new.intersections[0].steps[0].ms == nil)
    }

    @Test("the contract keeps ms of 0 to 900 in steps of 100 and nulls the rest; bodies leave room for sentAt")
    func contract() throws {
        let values: [Int?] = [0, 900, 950, 1000, -100, 150, nil]
        let transitions = values.map { FieldReport.Transition(t: t0, ms: $0, slot: 1, from: .red, to: .green) }
        let steps: [FieldReport.Step] = [
            FieldReport.Step(t: t0, ms: 500, slot: 1, state: .green, from: 8, to: 7),
            FieldReport.Step(t: t0, ms: 901, slot: 1, state: .green, from: 7, to: 6),
        ]
        let input = FieldReport.Intersection(id: "00000001", serviceUUIDs: [], emitters: 0, observations: [], transitions: transitions, steps: steps)
        let bodies = ReportContract.encode(FieldReport(client: nil, intersections: [input]), now: at(0))
        #expect(bodies.count == 1)
        let output = try JSONDecoder().decode(FieldReport.self, from: try #require(bodies.first))
        #expect(output.schema == 4)
        let transitionMS = output.intersections[0].transitions.map(\.ms)
        let expectedTransitionMS: [Int?] = [0, 900, nil, nil, nil, nil, nil]
        #expect(transitionMS == expectedTransitionMS)
        let stepMS = output.intersections[0].steps.map(\.ms)
        let expectedStepMS: [Int?] = [500, nil]
        #expect(stepMS == expectedStepMS)
        #expect(ReportContract.maximumQueuedBodyBytes == ReportContract.maximumBodyBytes - ReportContract.sentAtAllowance)
        // The longest possible member fits in the allowance.
        #expect(",\"sentAt\":\(Int.min)".utf8.count <= ReportContract.sentAtAllowance)
    }
}

@Suite("Report uploader, schema 4 and plans")
struct UploaderSchema4Tests {
    private func makeUploader(
        _ transport: FakeTransport,
        attestation: FakeAttestation = FakeAttestation(),
        clock: Clock
    ) -> ReportUploader {
        ReportUploader(
            transport: transport, attestation: attestation, keyStorage: MemoryKeyStorage(),
            sha256: fakeHash, now: { clock.now }, random: longestWait
        )
    }

    @Test("sentAt is inserted into schema 4 bodies; the rest of the body keeps its bytes")
    func stamping() throws {
        let date = Date(timeIntervalSince1970: 1_794_290_000.1239)
        let plain = ReportUploader.stamped(Data(" {\"intersections\":[],\"schema\":4}".utf8), sentAt: date)
        #expect(String(decoding: plain, as: UTF8.self) == " {\"sentAt\":1794290000123,\"intersections\":[],\"schema\":4}")

        // This app never queues sentAt, but a body that has one gets the new value only once.
        let replaced = ReportUploader.stamped(Data("{\"schema\":5,\"sentAt\":1}".utf8), sentAt: date)
        let object = try #require(try JSONSerialization.jsonObject(with: replaced) as? [String: Any])
        #expect(object["sentAt"] as? Int == 1_794_290_000_123)
        #expect(object["schema"] as? Int == 5)
        #expect(String(decoding: replaced, as: UTF8.self).components(separatedBy: "sentAt").count == 2)

        for body in ["{\"schema\":3,\"intersections\":[]}", "{\"schema\":1}", "{}", "[4]", "not json", ""] {
            #expect(ReportUploader.stamped(Data(body.utf8), sentAt: date) == Data(body.utf8), "\(body)")
        }
    }

    @Test("each attempt is stamped with the uploader's clock, also the retry after a token refresh")
    func sentAtPerAttempt() async throws {
        let transport = FakeTransport()
        transport.fallback["/v1/challenge"] = challengeResponse
        transport.script("/v1/attest", tokenResponse("T1"))
        transport.script("/v1/token", tokenResponse("T2"))
        transport.script("/v1/reports", json(401, ["error": "invalid_token"]), HTTPResponse(status: 202))
        let gate = Gate()
        transport.hold("/v1/token", at: gate)
        let clock = Clock()
        let uploader = makeUploader(transport, clock: clock)

        let upload = Task { try await uploader.upload(Data("{\"intersections\":[],\"schema\":4}".utf8)) }
        try await eventually("token refresh posted") { gate.arrivalCount == 1 }
        clock.advance(5)
        gate.open()
        #expect(try await upload.value == .accepted)

        let expected = [
            "{\"sentAt\":1794290000000,\"intersections\":[],\"schema\":4}",
            "{\"sentAt\":1794290005000,\"intersections\":[],\"schema\":4}",
        ]
        #expect(transport.reportBodies() == expected)
    }

    @Test("queued bodies of schema 3 and earlier are sent unchanged")
    func olderSchemas() async throws {
        let transport = FakeTransport()
        transport.fallback["/v1/challenge"] = challengeResponse
        transport.script("/v1/attest", tokenResponse("T1"))
        transport.fallback["/v1/reports"] = HTTPResponse(status: 202)
        let uploader = makeUploader(transport, clock: Clock())
        let bodies = ["{\"schema\":3,\"intersections\":[]}", "{\"schema\":2}", "{\"n\":1}"]
        for body in bodies {
            #expect(try await uploader.upload(Data(body.utf8)) == .accepted)
        }
        #expect(transport.reportBodies() == bodies)
    }

    @Test("fetchPlans: GET /v1/plans without a query, with the bearer token, decoded and returned with its body")
    func fetchPlans() async throws {
        let transport = FakeTransport()
        transport.fallback["/v1/challenge"] = challengeResponse
        transport.script("/v1/attest", tokenResponse("T1"))
        let body = Data(TimingFixtures.plansJSON.utf8)
        transport.script("/v1/plans", HTTPResponse(status: 200, body: body))
        let uploader = makeUploader(transport, clock: Clock())

        let download = try await uploader.fetchPlans()
        let expectedPaths = ["/v1/challenge", "/v1/attest", "/v1/plans"]
        #expect(transport.paths == expectedPaths)
        let request = try #require(transport.requests.last)
        #expect(request.method == "GET")
        #expect(request.path == "/v1/plans")
        #expect(request.body == nil)
        #expect(request.headers["Authorization"] == "Bearer T1")
        #expect(download.body == body)
        #expect(download.plans.intersections.map(\.id) == ["1234ABCD", "00000002"])
        #expect(await uploader.retryNotBefore == nil)
    }

    @Test("a 401 on /v1/plans refreshes the token once and retries")
    func plansRetryOn401() async throws {
        let transport = FakeTransport()
        transport.fallback["/v1/challenge"] = challengeResponse
        transport.script("/v1/attest", tokenResponse("T1"))
        transport.script("/v1/token", tokenResponse("T2"))
        transport.script("/v1/plans", json(401, ["error": "invalid_token"]), HTTPResponse(status: 200, body: Data(TimingFixtures.plansJSON.utf8)))
        let uploader = makeUploader(transport, clock: Clock())

        _ = try await uploader.fetchPlans()
        let expectedPaths = ["/v1/challenge", "/v1/attest", "/v1/plans", "/v1/challenge", "/v1/token", "/v1/plans"]
        #expect(transport.paths == expectedPaths)
        #expect(transport.requests.last?.headers["Authorization"] == "Bearer T2")
    }

    @Test("fetchPlans failures: rate limit, server errors and bad bodies throw and back off like uploads")
    func plansErrors() async throws {
        let transport = FakeTransport()
        transport.fallback["/v1/challenge"] = challengeResponse
        transport.script("/v1/attest", tokenResponse("T1"))
        transport.script(
            "/v1/plans",
            json(429, ["error": "rate_limited"]),
            json(400, ["error": "bad_request"]),
            HTTPResponse(status: 200, body: Data("nope".utf8))
        )
        let clock = Clock()
        let uploader = makeUploader(transport, clock: clock)

        await #expect(throws: UploadError.rateLimited) { try await uploader.fetchPlans() }
        let until = clock.now.addingTimeInterval(RetryPolicy.initialDelay)
        await #expect(throws: UploadError.backingOff(until: until)) { try await uploader.fetchPlans() }
        await #expect(throws: UploadError.backingOff(until: until)) { try await uploader.upload(Data("{}".utf8)) }
        #expect(transport.count("/v1/plans") == 1)
        clock.advance(600)
        await #expect(throws: UploadError.server(status: 400, code: "bad_request")) { try await uploader.fetchPlans() }
        clock.advance(600) // past the second back-off (2 min), with the token still valid
        await #expect(throws: UploadError.invalidResponse) { try await uploader.fetchPlans() }

        let unsupported = makeUploader(FakeTransport(), attestation: FakeAttestation(isSupported: false), clock: clock)
        await #expect(throws: UploadError.attestationUnsupported) { try await unsupported.fetchPlans() }
    }

    @Test("an upload and a plans download at the same time attest only one key")
    func sharedToken() async throws {
        let transport = FakeTransport()
        transport.fallback["/v1/challenge"] = challengeResponse
        transport.fallback["/v1/attest"] = tokenResponse("T1")
        transport.fallback["/v1/reports"] = HTTPResponse(status: 202)
        transport.fallback["/v1/plans"] = HTTPResponse(status: 200, body: Data(TimingFixtures.plansJSON.utf8))
        let gate = Gate()
        transport.hold("/v1/attest", at: gate)
        let attestation = FakeAttestation()
        let uploader = makeUploader(transport, attestation: attestation, clock: Clock())

        let upload = Task { try await uploader.upload(Data("{}".utf8)) }
        try await eventually("attestation posted") { gate.arrivalCount == 1 }
        let plans = Task { try await uploader.fetchPlans() }
        try await eventually("plans waiting for the token") { await uploader.tokenWaiterCount == 1 }
        gate.open()
        #expect(try await upload.value == .accepted)
        _ = try await plans.value

        #expect(transport.count("/v1/challenge") == 1)
        #expect(transport.count("/v1/attest") == 1)
        #expect(attestation.generatedKeys == 1)
        #expect(transport.requests.filter { $0.path == "/v1/plans" }.map { $0.headers["Authorization"] } == ["Bearer T1"])
    }
}
