// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
@testable import FieldDataKit
import PICSKit

private let now = Date(timeIntervalSince1970: 1_794_290_000)
private let t0 = 1_794_290_000

/// A port of `validateReport` in server/src/report.ts (plus the planned check that `raw` is a PICS
/// message of a known type), used to check what `ReportContract` produces.
private enum ServerRules {
    static let states: Set<String> = ["NoSignal", "Red", "BlinkGreen", "Green", "None", "Unknown"]

    static func violation(_ body: Data, nowSeconds: Int) -> String? {
        guard body.count <= 256 * 1024 else { return "too_large" }
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return "body" }
        guard Set(object.keys).isSubset(of: ["schema", "client", "intersections"]) else { return "report keys" }
        guard object["schema"] as? Int == 1 else { return "schema" }
        if let client = object["client"], !(client is NSNull) {
            guard let client = client as? String, client.count <= 40,
                  client.range(of: "^aoshingo-[a-z]+/[0-9A-Za-z.+-]+$", options: .regularExpression) != nil
            else { return "client" }
        }
        guard let intersections = object["intersections"] as? [[String: Any]], (1...50).contains(intersections.count) else {
            return "intersections"
        }
        var ids: Set<String> = []
        for intersection in intersections {
            if let problem = intersectionViolation(intersection, nowSeconds: nowSeconds) { return problem }
            guard ids.insert(intersection["id"] as! String).inserted else { return "duplicate id" }
        }
        return nil
    }

    private static func intersectionViolation(_ item: [String: Any], nowSeconds: Int) -> String? {
        guard Set(item.keys).isSubset(of: ["id", "serviceUUIDs", "emitters", "observations", "transitions"]) else { return "intersection keys" }
        guard let id = item["id"] as? String, id.range(of: "^[0-9A-F]{8}$", options: .regularExpression) != nil else { return "id" }
        guard let uuids = item["serviceUUIDs"] as? [String], uuids.count <= 8,
              uuids.allSatisfy({ $0.range(of: "^(?:[0-9A-F]{4}|[0-9A-F]{8}|[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12})$", options: .regularExpression) != nil })
        else { return "serviceUUIDs" }
        guard let emitters = item["emitters"] as? Int, (0...32).contains(emitters) else { return "emitters" }
        guard let observations = item["observations"] as? [[String: Any]], observations.count <= 600 else { return "observations" }
        guard let transitions = item["transitions"] as? [[String: Any]], transitions.count <= 300 else { return "transitions" }
        guard !(observations.isEmpty && transitions.isEmpty) else { return "empty intersection" }
        let times = (nowSeconds - 7 * 86_400)...(nowSeconds + 300)
        for observation in observations {
            guard Set(observation.keys).isSubset(of: ["t", "raw", "rssi", "bearing", "heading"]) else { return "observation keys" }
            guard let t = observation["t"] as? Int, times.contains(t) else { return "observation.t" }
            guard let raw = observation["raw"] as? String, (24...128).contains(raw.count),
                  raw.range(of: "^CE01(?:[0-9A-F]{2})+$", options: .regularExpression) != nil
            else { return "raw" }
            guard raw.dropFirst(16).prefix(8) == Substring(id) else { return "raw intersection" }
            guard let packet = try? PICSParser.parse(manufacturerData: Hex.bytes(raw)!), packet.messageType <= 2 else { return "raw type" }
            if let problem = nullable(observation["rssi"], -130...0, "rssi") { return problem }
            if let rssi = observation["rssi"] as? Int, rssi % 5 != 0 { return "rssi" }
            if let problem = nullable(observation["bearing"], 0...7, "bearing") { return problem }
            if let problem = nullable(observation["heading"], 0...7, "heading") { return problem }
        }
        for transition in transitions {
            guard Set(transition.keys).isSubset(of: ["t", "slot", "from", "to"]) else { return "transition keys" }
            guard let t = transition["t"] as? Int, times.contains(t) else { return "transition.t" }
            guard let slot = transition["slot"] as? Int, (1...6).contains(slot) else { return "slot" }
            guard let from = transition["from"] as? String, let to = transition["to"] as? String,
                  states.contains(from), states.contains(to), from != to
            else { return "from/to" }
        }
        return nil
    }

    private static func nullable(_ value: Any?, _ range: ClosedRange<Int>, _ name: String) -> String? {
        guard let value, !(value is NSNull) else { return nil }
        guard let number = value as? Int, range.contains(number) else { return name }
        return nil
    }
}

private func id(_ index: Int) -> String { String(format: "%08X", index) }

/// Manufacturer data of a Type 2 message for intersection `index`, `extra` bytes longer than the minimum.
private func signalRaw(_ index: Int, state: UInt8 = 0x31, extra: Int = 0, type: UInt8 = 2) -> String {
    var payload = [UInt8](repeating: 0, count: 10) + [state] + [UInt8](repeating: 0x44, count: extra)
    payload[2] = type
    payload.replaceSubrange(6..<10, with: [UInt8(index >> 24 & 0xFF), UInt8(index >> 16 & 0xFF), UInt8(index >> 8 & 0xFF), UInt8(index & 0xFF)])
    return Hex.string(PICS.companyIDBytes + payload, separator: "")
}

private func observation(_ index: Int, t: Int = t0, raw: String? = nil, rssi: Int? = -70, bearing: Int? = 3, heading: Int? = nil) -> FieldReport.Observation {
    FieldReport.Observation(t: t, raw: raw ?? signalRaw(index), rssi: rssi, bearing: bearing, heading: heading)
}

private func intersection(
    _ index: Int,
    observations: [FieldReport.Observation]? = nil,
    transitions: [FieldReport.Transition] = [],
    serviceUUIDs: [String] = [],
    emitters: Int = 1
) -> FieldReport.Intersection {
    FieldReport.Intersection(
        id: id(index),
        serviceUUIDs: serviceUUIDs,
        emitters: emitters,
        observations: observations ?? [observation(index)],
        transitions: transitions
    )
}

private func decode(_ bodies: [Data]) throws -> [FieldReport] {
    try bodies.map { try JSONDecoder().decode(FieldReport.self, from: $0) }
}

private func expectValid(_ bodies: [Data], sourceLocation: SourceLocation = #_sourceLocation) {
    for body in bodies {
        #expect(ServerRules.violation(body, nowSeconds: t0) == nil, sourceLocation: sourceLocation)
    }
}

@Suite("Report contract")
struct ContractTests {
    @Test("invalid observations are dropped and invalid optional values become null")
    func observations() throws {
        let report = FieldReport(client: "aoshingo-ios/0.1.0", intersections: [intersection(1, observations: [
            observation(1),
            observation(1, raw: signalRaw(1, type: 7)),                       // unknown message type
            observation(1, raw: String(signalRaw(1).prefix(22))),             // too short
            observation(1, raw: signalRaw(1, extra: 52)),                     // 65 bytes: too long
            observation(1, raw: signalRaw(1).lowercased()),                   // not uppercase
            observation(1, raw: signalRaw(2)),                                // another intersection
            observation(1, raw: "CE01" + String(signalRaw(1).dropFirst(4).dropLast(1)) + "G"), // not hex
            observation(1, t: t0 + 301),                                      // too far ahead
            observation(1, t: t0 - 86_401),                                   // too old for the queue
            observation(1, t: t0 + 300, rssi: -67, bearing: 8, heading: -1),  // kept with nulls
            observation(1, raw: signalRaw(1, extra: 51)),                     // 64 bytes: longest accepted
        ])])
        let bodies = ReportContract.encode(report, now: now)
        expectValid(bodies)
        let kept = try #require(try decode(bodies).first?.intersections.first?.observations)
        #expect(kept.count == 3)
        #expect(kept[1] == FieldReport.Observation(t: t0 + 300, raw: signalRaw(1), rssi: nil, bearing: nil, heading: nil))
        #expect(kept[2].raw.count == 128)
    }

    @Test("invalid transitions, empty intersections, bad IDs and bad clients are dropped; lists are normalised")
    func transitionsAndFields() throws {
        let report = FieldReport(client: "aoshingo-iOS/0.1.0", intersections: [
            intersection(1, observations: [], transitions: [
                .init(t: t0, slot: 0, from: .red, to: .green),
                .init(t: t0, slot: 7, from: .red, to: .green),
                .init(t: t0, slot: 1, from: .red, to: .red),
                .init(t: t0 + 301, slot: 1, from: .red, to: .green),
                .init(t: t0, slot: 6, from: .green, to: .blinkGreen),
            ], serviceUUIDs: ["fff0", "FFF0", "bad"] + (0..<10).map { String(format: "%04X", $0) }, emitters: 40),
            intersection(2, observations: [observation(2, t: t0 + 999)], emitters: -1),
            FieldReport.Intersection(id: "abcdef01", serviceUUIDs: [], emitters: 1, observations: [observation(0xABCDEF01)], transitions: []),
            intersection(3, emitters: -1),
        ])
        let bodies = ReportContract.encode(report, now: now)
        expectValid(bodies)
        let reports = try decode(bodies)
        #expect(reports.count == 1)
        #expect(reports[0].client == nil)
        #expect(reports[0].intersections.map(\.id) == [id(1), id(3)])
        let first = reports[0].intersections[0]
        #expect(first.transitions == [.init(t: t0, slot: 6, from: .green, to: .blinkGreen)])
        #expect(first.serviceUUIDs == ["FFF0", "0000", "0001", "0002", "0003", "0004", "0005", "0006"])
        #expect(first.emitters == 32)
        #expect(reports[0].intersections[1].emitters == 0)

        #expect(ReportContract.encode(FieldReport(client: nil, intersections: [intersection(4, observations: [])]), now: now).isEmpty)
        #expect(ReportContract.isValidClient(FieldReport.clientString(version: "0.1.0")))
        #expect(!ReportContract.isValidClient("aoshingo-ios/" + String(repeating: "1", count: 28)))
        #expect(!ReportContract.isValidClient("aoshingo-/1"))
        #expect(!ReportContract.isValidClient("aoshingo-ios/"))
    }

    @Test("more than 50 intersections are split into several reports")
    func intersectionCount() throws {
        let report = FieldReport(client: "aoshingo-ios/0.1.0", intersections: (0..<120).map { intersection($0) })
        let bodies = ReportContract.encode(report, now: now)
        expectValid(bodies)
        let reports = try decode(bodies)
        #expect(reports.map(\.intersections.count) == [50, 50, 20])
        #expect(reports.flatMap(\.intersections).map(\.id) == (0..<120).map(id))
        #expect(reports.allSatisfy { $0.client == "aoshingo-ios/0.1.0" })
    }

    @Test("bodies stay within 256 KiB and nothing valid is lost")
    func bodySize() throws {
        let observations = { (index: Int) in
            (0..<600).map { observation(index, t: t0 - $0, raw: signalRaw(index, extra: 51)) }
        }
        let transitions = (0..<300).map { FieldReport.Transition(t: t0 - $0, slot: 1 + $0 % 6, from: .red, to: .green) }
        let report = FieldReport(client: "aoshingo-ios/0.1.0", intersections: (0..<50).map {
            intersection($0, observations: observations($0), transitions: transitions)
        })
        #expect(try report.encoded().count > 5 * ReportContract.maximumBodyBytes)
        let bodies = ReportContract.encode(report, now: now)
        expectValid(bodies)
        #expect(bodies.allSatisfy { $0.count <= ReportContract.maximumBodyBytes })
        let reports = try decode(bodies)
        #expect(reports.reduce(0) { $0 + $1.observationCount } == 50 * 600)
        #expect(reports.reduce(0) { $0 + $1.transitionCount } == 50 * 300)
    }

    @Test("an intersection over the list limits is split across reports, never twice in one")
    func longIntersection() throws {
        let report = FieldReport(client: nil, intersections: [
            intersection(1, observations: (0..<1500).map { observation(1, t: t0 - $0) },
                         transitions: (0..<700).map { .init(t: t0 - $0, slot: 1, from: .red, to: .green) }),
            intersection(1), // the same ID twice
        ])
        let bodies = ReportContract.encode(report, now: now)
        expectValid(bodies)
        let reports = try decode(bodies)
        #expect(reports.reduce(0) { $0 + $1.observationCount } == 1501)
        #expect(reports.reduce(0) { $0 + $1.transitionCount } == 700)
        #expect(reports.allSatisfy { $0.intersections.count == 1 })
    }

    @Test("the pipeline queues only what the server accepts")
    func pipelineQueuesValidBodies() async throws {
        let clock = Clock(now)
        let store = InMemoryReportStore()
        let pipeline = FieldDataPipeline(store: store, uploader: PipelineTests.makeUploader(clock: clock), client: "aoshingo-ios/0.1.0", now: { clock.now })
        await pipeline.setEnabled(true)
        for index in 0..<60 {
            let data = Hex.bytes(signalRaw(index))!
            await pipeline.record(try PICSParser.parse(manufacturerData: data), manufacturerData: data, at: clock.now, rssi: -60, serviceUUIDs: ["fff0"], emitter: "E\(index)", context: .init())
        }
        #expect(await pipeline.flush(force: true))
        let bodies = await store.pending().map(\.body)
        #expect(bodies.count == 1) // the collector keeps 50 intersections, which fit in one body
        expectValid(bodies)
    }
}
