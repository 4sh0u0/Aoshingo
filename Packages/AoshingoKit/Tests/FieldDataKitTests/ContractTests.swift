// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
@testable import FieldDataKit
import PICSKit

private let now = Date(timeIntervalSince1970: 1_794_290_000)
private let t0 = 1_794_290_000

/// A port of the schema 2 rules of `POST /v1/reports` (docs/field-data-api.md, server/src/report.ts),
/// used to check what `ReportContract` produces.
private enum ServerRules {
    static let states: Set<String> = ["NoSignal", "Red", "BlinkGreen", "Green", "None", "Unknown"]
    static let distances: Set<Int> = [0, 10, 20, 40, 80, 160]
    static let accuracies: Set<Int> = [5, 10, 20, 30]
    static let nearbyCounts: Set<Int> = [0, 1, 5, 10, 20, 50, 100]

    static func violation(_ body: Data, nowSeconds: Int) -> String? {
        guard body.count <= 256 * 1024 else { return "too_large" }
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return "body" }
        guard Set(object.keys).isSubset(of: ["schema", "client", "intersections"]) else { return "report keys" }
        guard object["schema"] as? Int == 2 else { return "schema" }
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
            if let problem = intersectionViolation(intersection, times: (nowSeconds - 7 * 86_400)...(nowSeconds + 300)) {
                return problem
            }
            guard ids.insert(intersection["id"] as! String).inserted else { return "duplicate id" }
        }
        return nil
    }

    private static func intersectionViolation(_ item: [String: Any], times: ClosedRange<Int>) -> String? {
        let keys: Set<String> = ["id", "serviceUUIDs", "emitters", "emitterInfo", "observations", "transitions", "steps", "packets", "coverage", "labels"]
        guard Set(item.keys).isSubset(of: keys) else { return "intersection keys" }
        guard let id = item["id"] as? String, id.range(of: "^[0-9A-F]{8}$", options: .regularExpression) != nil else { return "id" }
        guard let uuids = item["serviceUUIDs"] as? [String], uuids.count <= 8,
              uuids.allSatisfy({ $0.range(of: "^(?:[0-9A-F]{4}|[0-9A-F]{8}|[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12})$", options: .regularExpression) != nil })
        else { return "serviceUUIDs" }
        guard let emitters = item["emitters"] as? Int, (0...32).contains(emitters) else { return "emitters" }
        func list(_ key: String, _ maximum: Int) -> [[String: Any]]? {
            guard let value = item[key] else { return [] } // schema 2 lists may be left out
            guard let list = value as? [[String: Any]], list.count <= maximum else { return nil }
            return list
        }
        guard let info = list("emitterInfo", 32), info.count == emitters else { return "emitterInfo" }
        guard let observations = list("observations", 600) else { return "observations" }
        guard let transitions = list("transitions", 300) else { return "transitions" }
        guard let steps = list("steps", 600) else { return "steps" }
        guard let packets = list("packets", 96) else { return "packets" }
        guard let coverage = list("coverage", 60) else { return "coverage" }
        guard let labels = list("labels", 20) else { return "labels" }
        guard !(observations.isEmpty && transitions.isEmpty && steps.isEmpty && labels.isEmpty) else { return "empty intersection" }
        let emitterRange = 0..<emitters

        for entry in info {
            guard Set(entry.keys).isSubset(of: ["txPower", "connectable"]) else { return "emitterInfo keys" }
            if let problem = nullable(entry["txPower"], -127...20, "txPower") { return problem }
            if let connectable = entry["connectable"], !(connectable is NSNull), connectable as? Bool == nil { return "connectable" }
        }
        for observation in observations {
            guard Set(observation.keys).isSubset(of: ["t", "raw", "rssi", "bearing", "heading", "emitter", "distance", "accuracy", "course", "speed", "nearby"]) else {
                return "observation keys"
            }
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
            if let problem = nullable(observation["emitter"], emitterRange, "observation.emitter") { return problem }
            if let problem = member(observation["distance"], distances, "distance") { return problem }
            if let problem = member(observation["accuracy"], accuracies, "accuracy") { return problem }
            if let problem = nullable(observation["course"], 0...7, "course") { return problem }
            if let problem = nullable(observation["speed"], 0...2, "speed") { return problem }
            if let problem = member(observation["nearby"], nearbyCounts, "nearby") { return problem }
        }
        for transition in transitions {
            guard Set(transition.keys).isSubset(of: ["t", "slot", "from", "to", "emitter", "gap", "held", "cycle"]) else { return "transition keys" }
            guard let t = transition["t"] as? Int, times.contains(t) else { return "transition.t" }
            guard let slot = transition["slot"] as? Int, (1...6).contains(slot) else { return "slot" }
            guard let from = transition["from"] as? String, let to = transition["to"] as? String,
                  states.contains(from), states.contains(to), from != to
            else { return "from/to" }
            if let problem = nullable(transition["emitter"], emitterRange, "transition.emitter") { return problem }
            if let problem = multiple(transition["gap"], 5000, 100, "gap") { return problem }
            if let problem = multiple(transition["held"], 3_600_000, 100, "held") { return problem }
            if let problem = multiple(transition["cycle"], 3_600_000, 100, "cycle") { return problem }
        }
        for step in steps {
            guard Set(step.keys).isSubset(of: ["t", "slot", "state", "from", "to", "emitter", "held"]) else { return "step keys" }
            guard let t = step["t"] as? Int, times.contains(t) else { return "step.t" }
            guard let slot = step["slot"] as? Int, (1...6).contains(slot) else { return "step.slot" }
            guard let state = step["state"] as? String, states.contains(state) else { return "step.state" }
            if let problem = nullable(step["from"], 1...8, "step.from") { return problem }
            if let problem = nullable(step["to"], 1...8, "step.to") { return problem }
            guard step["from"] as? Int != step["to"] as? Int else { return "step from equals to" }
            if let problem = nullable(step["emitter"], emitterRange, "step.emitter") { return problem }
            if let problem = multiple(step["held"], 3_600_000, 100, "step.held") { return problem }
        }
        var pairs: Set<[Int]> = []
        for stats in packets {
            guard Set(stats.keys).isSubset(of: ["emitter", "type", "count", "minInterval", "medianInterval"]) else { return "packets keys" }
            guard let emitter = stats["emitter"] as? Int, emitterRange.contains(emitter) else { return "packets.emitter" }
            guard let type = stats["type"] as? Int, (0...2).contains(type) else { return "packets.type" }
            guard let count = stats["count"] as? Int, (1...100_000).contains(count) else { return "packets.count" }
            if let problem = multiple(stats["minInterval"], 600_000, 10, "minInterval") { return problem }
            if let problem = multiple(stats["medianInterval"], 600_000, 10, "medianInterval") { return problem }
            let minimum = stats["minInterval"] as? Int, median = stats["medianInterval"] as? Int
            if count == 1, minimum != nil || median != nil { return "interval of one packet" }
            if let minimum, let median, minimum > median { return "minInterval above medianInterval" }
            guard pairs.insert([emitter, type]).inserted else { return "duplicate packets" }
        }
        for span in coverage {
            guard Set(span.keys).isSubset(of: ["start", "end"]) else { return "coverage keys" }
            guard let start = span["start"] as? Int, let end = span["end"] as? Int,
                  times.contains(start), times.contains(end), start <= end
            else { return "coverage" }
        }
        for label in labels {
            guard Set(label.keys).isSubset(of: ["t", "kind", "slot", "heading", "bearing", "distance"]) else { return "label keys" }
            guard let t = label["t"] as? Int, times.contains(t) else { return "label.t" }
            guard let kind = label["kind"] as? String, ["crosswalk", "button"].contains(kind) else { return "label.kind" }
            if let problem = nullable(label["slot"], 1...6, "label.slot") { return problem }
            if kind == "crosswalk", label["slot"] as? Int == nil { return "crosswalk without slot" }
            if let problem = nullable(label["heading"], 0...7, "label.heading") { return problem }
            if let problem = nullable(label["bearing"], 0...7, "label.bearing") { return problem }
            if let problem = member(label["distance"], distances, "label.distance") { return problem }
        }
        return nil
    }

    private static func nullable(_ value: Any?, _ range: some RangeExpression<Int>, _ name: String) -> String? {
        guard let value, !(value is NSNull) else { return nil }
        guard let number = value as? Int, range.contains(number) else { return name }
        return nil
    }

    private static func member(_ value: Any?, _ allowed: Set<Int>, _ name: String) -> String? {
        guard let value, !(value is NSNull) else { return nil }
        guard let number = value as? Int, allowed.contains(number) else { return name }
        return nil
    }

    private static func multiple(_ value: Any?, _ maximum: Int, _ step: Int, _ name: String) -> String? {
        guard let value, !(value is NSNull) else { return nil }
        guard let number = value as? Int, (0...maximum).contains(number), number % step == 0 else { return name }
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

private func label(_ kind: FieldReport.Label.Kind = .button, t: Int = t0, slot: Int? = nil, heading: Int? = nil, bearing: Int? = nil, distance: Int? = nil) -> FieldReport.Label {
    FieldReport.Label(t: t, kind: kind, slot: slot, heading: heading, bearing: bearing, distance: distance)
}

@Suite("Report contract, schema 2")
struct ContractSchema2Tests {
    @Test("schema 2 fields: invalid values become null and invalid entries are dropped")
    func sanitizing() throws {
        let valid = FieldReport.Observation(
            t: t0, raw: signalRaw(1), rssi: -70, bearing: 3, heading: nil,
            emitter: 1, distance: 20, accuracy: 10, course: 3, speed: 2, nearby: 50
        )
        let invalid = FieldReport.Observation(
            t: t0, raw: signalRaw(1), rssi: -70, bearing: 3, heading: nil,
            emitter: 2, distance: 15, accuracy: 7, course: 8, speed: 3, nearby: 3
        )
        let input = FieldReport.Intersection(
            id: id(1), serviceUUIDs: [], emitters: 2,
            emitterInfo: [.init(txPower: 30, connectable: true), .init(txPower: -10), .init(txPower: 5, connectable: false)],
            observations: [valid, invalid],
            transitions: [
                .init(t: t0, slot: 1, from: .red, to: .green, emitter: 0, gap: 300, held: 42_100, cycle: 98_700),
                .init(t: t0, slot: 2, from: .red, to: .green, emitter: -1, gap: 5100, held: 3_600_100, cycle: 150),
            ],
            steps: [
                .init(t: t0, slot: 1, state: .green, from: 8, to: 7, emitter: 1, held: 3900),
                .init(t: t0, slot: 1, state: .green, from: 9, to: 7, emitter: 5, held: 50),   // from, emitter, held → null
                .init(t: t0, slot: 1, state: .green, from: nil, to: nil),                     // not a change
                .init(t: t0, slot: 1, state: .green, from: 9, to: 0),                         // not a change once nulled
                .init(t: t0, slot: 7, state: .green, from: 8, to: 7),
                .init(t: t0 + 301, slot: 1, state: .green, from: 8, to: 7),
            ],
            packets: [
                .init(emitter: 0, type: 2, count: 1180, minInterval: 90, medianInterval: 200),
                .init(emitter: 2, type: 2, count: 5, minInterval: nil, medianInterval: nil),    // no such emitter
                .init(emitter: 1, type: 3, count: 5, minInterval: nil, medianInterval: nil),    // unknown type
                .init(emitter: 1, type: 0, count: 0, minInterval: nil, medianInterval: nil),
                .init(emitter: 1, type: 0, count: 100_001, minInterval: nil, medianInterval: nil),
                .init(emitter: 0, type: 2, count: 3, minInterval: 100, medianInterval: 100),    // duplicate pair
                .init(emitter: 1, type: 2, count: 1, minInterval: 100, medianInterval: 100),    // one packet has no interval
                .init(emitter: 1, type: 1, count: 5, minInterval: 300, medianInterval: 200),    // minimum above median
                .init(emitter: 1, type: 0, count: 5, minInterval: 95, medianInterval: 600_010),
            ],
            coverage: [
                .init(start: t0 - 10, end: t0),
                .init(start: t0, end: t0 - 1),
                .init(start: t0, end: t0 + 301),
                .init(start: t0 - 86_401, end: t0),
            ],
            labels: [
                label(.crosswalk, slot: 1, heading: 2, bearing: 5, distance: 10),
                label(.crosswalk, slot: nil),
                label(.crosswalk, slot: 7),
                label(.button, slot: 9, heading: 8, bearing: -1, distance: 30),
                label(.button, t: t0 + 301),
            ]
        )
        let bodies = ReportContract.encode(FieldReport(client: nil, intersections: [input]), now: now)
        expectValid(bodies)
        let output = try #require(try decode(bodies).first?.intersections.first)
        #expect(output.emitters == 2)
        #expect(output.emitterInfo == [.init(txPower: nil, connectable: true), .init(txPower: -10)])
        #expect(output.observations == [valid, FieldReport.Observation(t: t0, raw: signalRaw(1), rssi: -70, bearing: 3, heading: nil)])
        #expect(output.transitions == [input.transitions[0], .init(t: t0, slot: 2, from: .red, to: .green)])
        #expect(output.steps == [input.steps[0], .init(t: t0, slot: 1, state: .green, from: nil, to: 7)])
        let expectedPackets: [FieldReport.PacketStats] = [
            input.packets[0],
            .init(emitter: 1, type: 2, count: 1, minInterval: nil, medianInterval: nil),
            .init(emitter: 1, type: 1, count: 5, minInterval: nil, medianInterval: nil),
            .init(emitter: 1, type: 0, count: 5, minInterval: nil, medianInterval: nil),
        ]
        #expect(output.packets == expectedPackets)
        #expect(output.coverage == [.init(start: t0 - 10, end: t0)])
        #expect(output.labels == [input.labels[0], label(.button)])
    }

    @Test("emitterInfo is padded to emitters; an intersection needs an observation, transition, step or label")
    func emptiness() throws {
        let report = FieldReport(client: nil, intersections: [
            FieldReport.Intersection(id: id(1), serviceUUIDs: [], emitters: 3, observations: [], transitions: [], labels: [label()]),
            FieldReport.Intersection(id: id(2), serviceUUIDs: [], emitters: 0, observations: [], transitions: [],
                                     steps: [.init(t: t0, slot: 1, state: .red, from: 2, to: 1)]),
            FieldReport.Intersection(id: id(3), serviceUUIDs: [], emitters: 1, emitterInfo: [.init()], observations: [], transitions: [],
                                     packets: [.init(emitter: 0, type: 2, count: 3, minInterval: 100, medianInterval: 100)],
                                     coverage: [.init(start: t0, end: t0)]),
            FieldReport.Intersection(id: id(4), serviceUUIDs: [], emitters: 0, observations: [], transitions: [],
                                     labels: [label(.crosswalk)]),
        ])
        let bodies = ReportContract.encode(report, now: now)
        expectValid(bodies)
        let intersections = try decode(bodies).flatMap(\.intersections)
        #expect(intersections.map(\.id) == [id(1), id(2)])
        #expect(intersections[0].emitterInfo == [.init(), .init(), .init()])
    }

    @Test("coverage and labels are cut to their limits; 96 packet statistics fit")
    func listLimits() throws {
        let packets = (0..<32).flatMap { emitter in
            (0...2).map { FieldReport.PacketStats(emitter: emitter, type: $0, count: 2, minInterval: 100, medianInterval: 100) }
        }
        let coverage = (0..<70).map { FieldReport.Coverage(start: t0 - 1000 + $0 * 10, end: t0 - 995 + $0 * 10) }
        let labels = (0..<25).map { label(t: t0 - $0) }
        let report = FieldReport(client: nil, intersections: [FieldReport.Intersection(
            id: id(1), serviceUUIDs: [], emitters: 32, observations: [observation(1)], transitions: [],
            packets: packets, coverage: coverage, labels: labels
        )])
        let bodies = ReportContract.encode(report, now: now)
        expectValid(bodies)
        let output = try #require(try decode(bodies).first?.intersections.first)
        #expect(output.packets == packets)
        #expect(output.coverage == Array(coverage.prefix(60)))
        #expect(output.labels == Array(labels.prefix(20)))
    }

    @Test("a split intersection repeats emitterInfo and carries packets, coverage and labels in its first piece only")
    func splitting() throws {
        let info: [FieldReport.EmitterInfo] = [.init(txPower: -4, connectable: true), .init(txPower: nil, connectable: false)]
        let packets: [FieldReport.PacketStats] = [
            .init(emitter: 0, type: 2, count: 1180, minInterval: 90, medianInterval: 200),
            .init(emitter: 1, type: 0, count: 1, minInterval: nil, medianInterval: nil),
        ]
        let coverage = (0..<60).map { FieldReport.Coverage(start: t0 - 6000 + $0 * 100, end: t0 - 5950 + $0 * 100) }
        let labels = (0..<20).map { label(.crosswalk, t: t0 - $0, slot: 1 + $0 % 6, heading: $0 % 8, bearing: 7 - $0 % 8, distance: 40) }
        let big = FieldReport.Intersection(
            id: id(1), serviceUUIDs: ["FFF0"], emitters: 2, emitterInfo: info,
            observations: (0..<1500).map {
                FieldReport.Observation(t: t0 - $0, raw: signalRaw(1, extra: 51), rssi: -70, bearing: 3, heading: 4,
                                        emitter: $0 % 2, distance: 20, accuracy: 10, course: 1, speed: 1, nearby: 5)
            },
            transitions: (0..<700).map { .init(t: t0 - $0, slot: 1, from: .red, to: .green, emitter: 1, gap: 300, held: 30_000) },
            steps: (0..<1500).map { .init(t: t0 - $0, slot: 1 + $0 % 6, state: .green, from: 8, to: 7, emitter: 0, held: 1000) },
            packets: packets, coverage: coverage, labels: labels
        )
        let bodies = ReportContract.encode(FieldReport(client: "aoshingo-ios/0.2.0", intersections: [big, intersection(2)]), now: now)
        expectValid(bodies)
        let reports = try decode(bodies)
        #expect(reports.allSatisfy { Set($0.intersections.map(\.id)).count == $0.intersections.count })
        let pieces = reports.flatMap(\.intersections).filter { $0.id == id(1) }
        #expect(pieces.count > 2)
        #expect(pieces[0].packets == packets && pieces[0].coverage == coverage && pieces[0].labels == labels)
        #expect(pieces.dropFirst().allSatisfy { $0.packets.isEmpty && $0.coverage.isEmpty && $0.labels.isEmpty })
        #expect(pieces.allSatisfy { $0.emitters == 2 && $0.emitterInfo == info && $0.serviceUUIDs == ["FFF0"] })
        #expect(pieces.allSatisfy { $0.observations.count <= 600 && $0.transitions.count <= 300 && $0.steps.count <= 600 })
        // Nothing valid is lost, and the order is kept.
        #expect(pieces.flatMap(\.observations) == big.observations)
        #expect(pieces.flatMap(\.transitions) == big.transitions)
        #expect(pieces.flatMap(\.steps) == big.steps)
        #expect(reports.flatMap(\.intersections).contains { $0.id == id(2) })
    }

    @Test("pieces: with too little room, single entries are separated and the first piece keeps the unsplit lists")
    func smallestPieces() {
        let packets: [FieldReport.PacketStats] = [.init(emitter: 0, type: 2, count: 2, minInterval: 100, medianInterval: 100)]
        let step = FieldReport.Step(t: t0, slot: 1, state: .green, from: 2, to: 1, emitter: 0)
        let whole = FieldReport.Intersection(
            id: id(1), serviceUUIDs: [], emitters: 1, emitterInfo: [.init(txPower: 0)],
            observations: [observation(1)], transitions: [], steps: [step],
            packets: packets, coverage: [.init(start: t0, end: t0)], labels: [label()]
        )
        let pieces = ReportContract.pieces(of: whole, budget: ReportContract.encodedSize(whole) - 1)
        #expect(pieces.count == 2)
        #expect(pieces.map(\.observations.count) == [1, 0])
        #expect(pieces.map(\.steps) == [[], [step]])
        #expect(pieces.map(\.packets) == [packets, []])
        #expect(pieces.map(\.coverage.count) == [1, 0])
        #expect(pieces.map(\.labels.count) == [1, 0])
        #expect(pieces.allSatisfy { $0.emitterInfo == whole.emitterInfo })

        var pair = whole
        pair.observations = []
        pair.transitions = [.init(t: t0, slot: 1, from: .red, to: .green)]
        let split = ReportContract.pieces(of: pair, budget: ReportContract.encodedSize(pair) - 1)
        #expect(split.map(\.transitions.count) == [1, 0])
        #expect(split.map(\.steps.count) == [0, 1])
        #expect(split.map(\.labels.count) == [1, 0])
    }

    @Test("the pipeline records labels only while enabled, and new fields reach the queue")
    func pipelineLabels() async throws {
        let clock = Clock(now)
        let store = InMemoryReportStore()
        let pipeline = FieldDataPipeline(store: store, uploader: PipelineTests.makeUploader(clock: clock), client: "aoshingo-ios/0.2.0", now: { clock.now })
        #expect(await pipeline.recordLabel(.button, slot: nil, intersectionID: id(1), at: clock.now, context: .init()) == false)
        await pipeline.setEnabled(true)
        #expect(await pipeline.recordLabel(.crosswalk, slot: nil, intersectionID: id(1), at: clock.now, context: .init()) == false)
        #expect(await pipeline.recordLabel(.crosswalk, slot: 2, intersectionID: id(1), at: clock.now, context: .init(trueHeading: 45)))
        let data = Hex.bytes(signalRaw(1))!
        await pipeline.record(
            try PICSParser.parse(manufacturerData: data), manufacturerData: data, at: clock.now, rssi: -60,
            serviceUUIDs: [], emitter: "E", txPower: -12, connectable: true, context: .init(nearbyDevices: 7)
        )
        #expect(await pipeline.flush(force: true))
        let bodies = await store.pending().map(\.body)
        expectValid(bodies)
        let intersection = try #require(try decode(bodies).first?.intersections.first)
        #expect(intersection.labels == [label(.crosswalk, slot: 2, heading: 1)])
        #expect(intersection.emitterInfo == [.init(txPower: -12, connectable: true)])
        #expect(intersection.observations.map(\.nearby) == [5])
        #expect(intersection.packets == [.init(emitter: 0, type: 2, count: 1, minInterval: nil, medianInterval: nil)])
    }
}
