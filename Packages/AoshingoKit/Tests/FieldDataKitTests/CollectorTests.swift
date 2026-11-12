// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
@testable import FieldDataKit
import PICSKit

private func seconds(_ value: Double) -> Date { Date(timeIntervalSince1970: 1_794_290_000 + value) }

private func signalData(_ states: [UInt8], messageID: UInt8 = 0, last: UInt8 = 0x01) -> [UInt8] {
    var payload = [UInt8](repeating: 0, count: 10) + states
    payload[2] = 2
    payload[3] = messageID
    payload.replaceSubrange(6..<10, with: [0x00, 0x00, 0x00, last])
    return PICS.companyIDBytes + payload
}

private extension FieldCollector {
    mutating func feed(
        _ data: [UInt8],
        at time: Double,
        rssi: Int? = -67,
        context: ObservationContext = .init(),
        emitter: String? = nil,
        serviceUUIDs: [String] = [],
        txPower: Int? = nil,
        connectable: Bool? = nil
    ) throws {
        let packet = try PICSParser.parse(manufacturerData: data)
        record(
            packet, manufacturerData: data, at: seconds(time), rssi: rssi, serviceUUIDs: serviceUUIDs,
            emitter: emitter, txPower: txPower, connectable: connectable, context: context
        )
    }

    mutating func requireReport(client: String?, sourceLocation: SourceLocation = #_sourceLocation) throws -> FieldReport {
        let report = makeReport(client: client)
        return try #require(report, sourceLocation: sourceLocation)
    }
}

@Suite("Bucketing")
struct BucketingTests {
    @Test func rssi() {
        #expect(Bucketing.rssi(-67) == -70)
        #expect(Bucketing.rssi(-65) == -65)
        #expect(Bucketing.rssi(-1) == -5)
        #expect(Bucketing.rssi(-127) == -130)
        #expect(Bucketing.rssi(127) == nil)
        #expect(Bucketing.rssi(0) == nil)
        #expect(Bucketing.rssi(nil) == nil)
    }

    @Test func sectors() {
        #expect(Bucketing.sector(degrees: 0) == 0)
        #expect(Bucketing.sector(degrees: 22.4) == 0)
        #expect(Bucketing.sector(degrees: 22.5) == 1)
        #expect(Bucketing.sector(degrees: 90) == 2)
        #expect(Bucketing.sector(degrees: 337.4) == 7)
        #expect(Bucketing.sector(degrees: 337.5) == 0)
        #expect(Bucketing.sector(degrees: 359.9) == 0)
        #expect(Bucketing.sector(degrees: 720 + 180) == 4)
        #expect(Bucketing.sector(degrees: -1) == nil)
        #expect(Bucketing.sector(degrees: .nan) == nil)
        #expect(Bucketing.sector(degrees: nil) == nil)
    }

    @Test func bearing() throws {
        let origin = Coordinate(latitude: 35.712, longitude: 139.703)
        let north = try #require(Bucketing.bearing(from: origin, to: Coordinate(latitude: 35.713, longitude: 139.703)))
        #expect(abs(north - 0) < 0.01)
        let east = try #require(Bucketing.bearing(from: origin, to: Coordinate(latitude: 35.712, longitude: 139.704)))
        #expect(abs(east - 90) < 0.1)
        let southWest = try #require(Bucketing.bearing(from: origin, to: Coordinate(latitude: 35.711, longitude: 139.702)))
        #expect(Bucketing.sector(degrees: southWest) == 5)
        #expect(Bucketing.bearing(from: origin, to: origin) == nil)
    }

    @Test func serviceUUIDs() {
        #expect(Bucketing.serviceUUID("fff0") == "FFF0")
        #expect(Bucketing.serviceUUID("0000FFF0") == "0000FFF0")
        #expect(Bucketing.serviceUUID("6e400001-b5a3-f393-e0a9-e50e24dcca9e") == "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
        #expect(Bucketing.serviceUUID("FFF") == nil)
        #expect(Bucketing.serviceUUID("GGGG") == nil)
        #expect(Bucketing.serviceUUID("6e400001xb5a3-f393-e0a9-e50e24dcca9e") == nil)
    }

    @Test func distance() {
        let origin = DemoAdvertiser.coordinate
        #expect(Bucketing.distance(from: origin, to: origin) == 0)
        let north = Coordinate(latitude: origin.latitude + 0.001, longitude: origin.longitude)
        #expect(abs(Bucketing.distance(from: origin, to: north) - 111.195) < 0.01)
        let east = Coordinate(latitude: origin.latitude, longitude: origin.longitude + 0.001)
        #expect(abs(Bucketing.distance(from: origin, to: east) - 90.32) < 0.05)
        #expect(Bucketing.distance(from: east, to: origin) == Bucketing.distance(from: origin, to: east))
        let antipode = Coordinate(latitude: -origin.latitude, longitude: origin.longitude - 180)
        #expect(abs(Bucketing.distance(from: origin, to: antipode) - .pi * 6_371_008.8) < 1)
    }

    @Test func distanceRings() {
        let cases: [(Double?, Int?)] = [
            (0, 0), (9.99, 0), (10, 10), (19.9, 10), (20, 20), (27, 20), (39.9, 20), (40, 40),
            (79.9, 40), (80, 80), (159.9, 80), (160, 160), (5000, 160),
            (-0.1, nil), (nil, nil), (.nan, nil), (.infinity, nil),
        ]
        for (meters, ring) in cases {
            #expect(Bucketing.distanceRing(meters) == ring, "\(String(describing: meters))")
        }
    }

    @Test func accuracyClasses() {
        let cases: [(Double?, Int?)] = [
            (0, 5), (5, 5), (5.01, 10), (7, 10), (10, 10), (10.5, 20), (20, 20), (20.5, 30), (30, 30),
            (30.01, nil), (-1, nil), (nil, nil), (.nan, nil),
        ]
        for (meters, value) in cases {
            #expect(Bucketing.accuracy(meters) == value, "\(String(describing: meters))")
        }
    }

    @Test func speedClasses() {
        let cases: [(Double?, Int?)] = [
            (0, 0), (0.49, 0), (0.5, 1), (1.4, 1), (2.49, 1), (2.5, 2), (30, 2), (-1, nil), (nil, nil), (.nan, nil),
        ]
        for (speed, value) in cases {
            #expect(Bucketing.speed(speed) == value, "\(String(describing: speed))")
        }
    }

    @Test("activity: unsure or unknown is nil, and a vehicle wins over standing still")
    func activityClasses() {
        func activity(
            automotive: Bool = false, cycling: Bool = false, running: Bool = false,
            walking: Bool = false, stationary: Bool = false, confident: Bool = true
        ) -> FieldReport.Activity? {
            Bucketing.activity(
                automotive: automotive, cycling: cycling, running: running,
                walking: walking, stationary: stationary, confident: confident
            )
        }
        #expect(activity(walking: true) == .walking)
        #expect(activity(running: true) == .running)
        #expect(activity(cycling: true) == .cycling)
        #expect(activity(automotive: true) == .automotive)
        #expect(activity(stationary: true) == .stationary)
        // A car waiting at a red light.
        #expect(activity(automotive: true, stationary: true) == .automotive)
        #expect(activity(cycling: true, stationary: true) == .cycling)
        #expect(activity(walking: true, stationary: true) == .walking)
        #expect(activity(running: true, walking: true) == .running)
        #expect(activity() == nil)
        #expect(activity(walking: true, confident: false) == nil)
        #expect(FieldReport.Activity.allCases.map(\.rawValue) == ["stationary", "walking", "running", "cycling", "automotive"])
    }

    @Test func nearbyClasses() {
        let cases: [(Int?, Int?)] = [
            (0, 0), (1, 1), (4, 1), (5, 5), (9, 5), (10, 10), (19, 10), (20, 20), (49, 20), (50, 50),
            (99, 50), (100, 100), (5000, 100), (-1, nil), (nil, nil),
        ]
        for (count, value) in cases {
            #expect(Bucketing.nearby(count) == value, "\(String(describing: count))")
        }
    }

    @Test func milliseconds() {
        #expect(Bucketing.durationMilliseconds(0) == 0)
        #expect(Bucketing.durationMilliseconds(0.04) == 0)
        #expect(Bucketing.durationMilliseconds(0.06) == 100)
        #expect(Bucketing.durationMilliseconds(0.3) == 300)
        #expect(Bucketing.durationMilliseconds(42.13) == 42_100)
        #expect(Bucketing.durationMilliseconds(3600) == 3_600_000)
        #expect(Bucketing.durationMilliseconds(3600.04) == 3_600_000)
        #expect(Bucketing.durationMilliseconds(3600.06) == nil)
        #expect(Bucketing.durationMilliseconds(86_400 * 365) == nil)
        #expect(Bucketing.durationMilliseconds(-0.01) == nil)
        #expect(Bucketing.durationMilliseconds(.nan) == nil)

        #expect(Bucketing.intervalMilliseconds(0) == 0)
        #expect(Bucketing.intervalMilliseconds(0.094) == 90)
        #expect(Bucketing.intervalMilliseconds(0.096) == 100)
        #expect(Bucketing.intervalMilliseconds(0.2) == 200)
        #expect(Bucketing.intervalMilliseconds(599.999) == 600_000)
        #expect(Bucketing.intervalMilliseconds(600) == 600_000)
        #expect(Bucketing.intervalMilliseconds(7200) == 600_000)
        #expect(Bucketing.intervalMilliseconds(.infinity) == 600_000)
        #expect(Bucketing.intervalMilliseconds(-0.001) == nil)
        #expect(Bucketing.intervalMilliseconds(.nan) == nil)
    }

    @Test func txPower() {
        #expect(Bucketing.txPower(-127) == -127)
        #expect(Bucketing.txPower(0) == 0)
        #expect(Bucketing.txPower(20) == 20)
        #expect(Bucketing.txPower(21) == nil)
        #expect(Bucketing.txPower(127) == nil)
        #expect(Bucketing.txPower(-128) == nil)
        #expect(Bucketing.txPower(nil) == nil)
    }

    @Test func clientString() {
        #expect(FieldReport.clientString(version: "0.1.0") == "aoshingo-ios/0.1.0")
        // TestFlight and development builds add the channel (App/AppChannel.swift, docs/release.md).
        #expect(FieldReport.clientString(version: "1.1.0-tf") == "aoshingo-ios/1.1.0-tf")
        #expect(FieldReport.clientString(version: "1.1.0-dev") == "aoshingo-ios/1.1.0-dev")
        #expect(FieldReport.clientString(version: "0.1 (5)") == "aoshingo-ios/0.15")
        #expect(FieldReport.clientString(version: "") == "aoshingo-ios/0")
    }
}

@Suite("Field collector")
struct CollectorTests {
    @Test("unchanged packets are resampled every 5 s; the message ID byte is ignored")
    func sampling() throws {
        var collector = FieldCollector()
        for (index, time) in [0.0, 0.5, 1.0, 4.9, 5.0, 9.9, 10.0].enumerated() {
            try collector.feed(signalData([0x31], messageID: UInt8(index)), at: time)
        }
        let report = try collector.requireReport(client: nil)
        #expect(report.intersections[0].observations.map(\.t) == [0, 5, 10].map { 1_794_290_000 + $0 })
    }

    @Test("changed packets are kept at most once per second")
    func changes() throws {
        var collector = FieldCollector()
        try collector.feed(signalData([0x71]), at: 0)
        try collector.feed(signalData([0x61]), at: 0.5)
        try collector.feed(signalData([0x51]), at: 1.0)
        try collector.feed(signalData([0x41]), at: 2.5)
        let report = try collector.requireReport(client: nil)
        #expect(report.intersections[0].observations.count == 3)
    }

    @Test("name and position are resampled only every 60 s")
    func staticMessages() throws {
        var collector = FieldCollector()
        for step in 0..<3 {
            for data in DemoAdvertiser.manufacturerData(step: 0) where data[4] < 2 {
                try collector.feed(data, at: Double(step) * 30)
            }
        }
        let report = try collector.requireReport(client: nil)
        #expect(report.intersections[0].observations.count == 4)
    }

    @Test("transitions are recorded per slot to 0.1 s (t and ms) and survive a window boundary")
    func transitions() throws {
        var collector = FieldCollector()
        try collector.feed(signalData([0x31, 0x13]), at: 0.4)
        try collector.feed(signalData([0x33, 0x13]), at: 1.7)
        try collector.feed(signalData([0x32, 0x11]), at: 2.2)
        let first = try collector.requireReport(client: "aoshingo-ios/0.1.0")
        let expectedTransitions: [FieldReport.Transition] = [
            .init(t: 1_794_290_001, ms: 700, slot: 1, from: .red, to: .green, gap: 1300),
            .init(t: 1_794_290_002, ms: 200, slot: 1, from: .green, to: .blinkGreen, gap: 500, held: 500),
            .init(t: 1_794_290_002, ms: 200, slot: 2, from: .green, to: .red, gap: 500),
        ]
        #expect(first.intersections[0].transitions == expectedTransitions)
        try collector.feed(signalData([0x31, 0x11]), at: 3.0)
        let second = try collector.requireReport(client: nil)
        let expectedSecond: [FieldReport.Transition] = [
            .init(t: 1_794_290_003, ms: 0, slot: 1, from: .blinkGreen, to: .red, gap: 800, held: 800),
        ]
        #expect(second.intersections[0].transitions == expectedSecond)
    }

    @Test("bearing comes from the Type 1 position; RSSI and heading are bucketed; location is never included")
    func context() throws {
        var collector = FieldCollector()
        let position = DemoAdvertiser.manufacturerData(step: 0)[1]
        try collector.feed(position, at: 0)
        let user = Coordinate(latitude: DemoAdvertiser.coordinate.latitude, longitude: DemoAdvertiser.coordinate.longitude + 0.0005)
        try collector.feed(DemoAdvertiser.manufacturerData(step: 1)[0], at: 1, rssi: -72, context: .init(userLocation: user, trueHeading: 181))
        let report = try collector.requireReport(client: nil)
        let observations = report.intersections[0].observations
        #expect(observations[0].bearing == nil)
        #expect(observations[1].bearing == 2)
        #expect(observations[1].heading == 4)
        #expect(observations[1].rssi == -75)
        let json = String(decoding: try report.encoded(), as: UTF8.self)
        #expect(!json.contains("139.76"))
        #expect(!json.contains("35.68"))
    }

    @Test("emitters are counted, service UUIDs normalised, and only the count leaves the device")
    func emitters() throws {
        var collector = FieldCollector()
        try collector.feed(signalData([0x31]), at: 0, emitter: "peripheral-A", serviceUUIDs: ["fff0", "bad"])
        try collector.feed(signalData([0x31]), at: 6, emitter: "peripheral-B")
        try collector.feed(signalData([0x31]), at: 12, emitter: "peripheral-A")
        let report = try collector.requireReport(client: nil)
        #expect(report.intersections[0].emitters == 2)
        #expect(report.intersections[0].serviceUUIDs == ["FFF0"])
        #expect(!String(decoding: try report.encoded(), as: UTF8.self).contains("peripheral"))
    }

    @Test("window flushes after ten minutes; empty windows make no report")
    func window() throws {
        var collector = FieldCollector()
        let empty = collector.makeReport(client: nil)
        #expect(empty == nil)
        #expect(!collector.shouldFlush(at: seconds(0)))
        try collector.feed(signalData([0x31]), at: 0)
        #expect(!collector.shouldFlush(at: seconds(599)))
        #expect(collector.shouldFlush(at: seconds(600)))
        _ = try collector.requireReport(client: nil)
        #expect(collector.isEmpty)
        #expect(collector.windowStart == nil)
    }

    @Test("observation limit per intersection triggers a flush; transitions still count")
    func limits() throws {
        var collector = FieldCollector()
        for index in 0...FieldCollector.maxObservationsPerIntersection + 5 {
            try collector.feed(signalData([index.isMultiple(of: 2) ? 0x31 : 0x33]), at: Double(index) * 1.0)
        }
        #expect(collector.observationCount == FieldCollector.maxObservationsPerIntersection)
        #expect(collector.shouldFlush(at: seconds(1)))
        #expect(collector.transitionCount == FieldCollector.maxTransitionsPerIntersection)
    }

    @Test("at most 50 intersections per report")
    func intersectionLimit() throws {
        var collector = FieldCollector()
        for index in 0..<60 {
            try collector.feed(signalData([0x31], last: UInt8(index)), at: 0)
        }
        #expect(try collector.requireReport(client: nil).intersections.count == FieldCollector.maxIntersections)
    }

    @Test("a change after a pause in reception is not a transition")
    func gapResetsTransitions() throws {
        var collector = FieldCollector()
        try collector.feed(signalData([0x31]), at: 0)       // red at 10:00
        try collector.feed(signalData([0x33]), at: 1800)    // green at 10:30
        try collector.feed(signalData([0x31]), at: 1800 + FieldCollector.maxTransitionGap + 0.5)
        try collector.feed(signalData([0x33]), at: 1800 + FieldCollector.maxTransitionGap + 0.5 + FieldCollector.maxTransitionGap)
        let report = try collector.requireReport(client: nil)
        let expectedTransitions: [FieldReport.Transition] = [
            .init(t: 1_794_290_000 + 1800 + 10, ms: 500, slot: 1, from: .red, to: .green, gap: 5000),
        ]
        #expect(report.intersections[0].transitions == expectedTransitions)
    }

    @Test("resetSignalStates (app in the background) starts every intersection afresh")
    func resetSignalStates() throws {
        var collector = FieldCollector()
        try collector.feed(signalData([0x31]), at: 0)
        collector.resetSignalStates()
        try collector.feed(signalData([0x33]), at: 1)
        try collector.feed(signalData([0x31]), at: 2)
        let report = try collector.requireReport(client: nil)
        #expect(report.intersections[0].observations.count == 3)
        let expectedTransitions: [FieldReport.Transition] = [
            .init(t: 1_794_290_002, ms: 0, slot: 1, from: .green, to: .red, gap: 1000),
        ]
        #expect(report.intersections[0].transitions == expectedTransitions)
    }

    @Test("packets the server would refuse as raw are ignored: unknown types and odd lengths")
    func unknownTypes() throws {
        var collector = FieldCollector()
        var unknown = signalData([0x31])
        unknown[4] = 7 // message type 7
        try collector.feed(unknown, at: 0)
        try collector.feed(signalData([0x31] + [UInt8](repeating: 0x44, count: 60)), at: 0) // 73 bytes
        #expect(collector.isEmpty)
        try collector.feed(signalData([0x31] + [UInt8](repeating: 0x44, count: 51)), at: 0) // 64 bytes
        #expect(collector.observationCount == 1)
    }

    @Test("discardAll forgets the window and the last states")
    func discard() throws {
        var collector = FieldCollector()
        try collector.feed(signalData([0x31]), at: 0)
        collector.discardAll()
        try collector.feed(signalData([0x33]), at: 1)
        #expect(try collector.requireReport(client: nil).intersections[0].transitions.isEmpty)
    }

    @Test("report JSON follows the contract: schema 4, explicit nulls, uppercase raw hex starting with CE01")
    func json() throws {
        var collector = FieldCollector()
        try collector.feed(signalData([0x31]), at: 0, rssi: nil)
        let report = try collector.requireReport(client: "aoshingo-ios/0.1.0")
        let object = try #require(try JSONSerialization.jsonObject(with: report.encoded()) as? [String: Any])
        #expect(object["schema"] as? Int == 4)
        #expect(object["sentAt"] == nil) // added by the uploader at each attempt, never queued
        #expect(object["client"] as? String == "aoshingo-ios/0.1.0")
        let intersection = try #require((object["intersections"] as? [[String: Any]])?.first)
        #expect(intersection["id"] as? String == "00000001")
        let observation = try #require((intersection["observations"] as? [[String: Any]])?.first)
        #expect(observation["raw"] as? String == "CE010000020000000000000131")
        #expect(observation["rssi"] is NSNull)
        #expect(observation["bearing"] is NSNull)
        #expect(observation["heading"] is NSNull)
        #expect(Set(observation.keys) == ["t", "raw", "rssi", "bearing", "heading", "emitter", "distance", "accuracy", "course", "speed", "nearby", "activity"])
        for key in ["emitter", "distance", "accuracy", "course", "speed", "nearby", "activity"] {
            #expect(observation[key] is NSNull, "\(key)")
        }
    }
}

private let t0 = 1_794_290_000
private let positionData = DemoAdvertiser.manufacturerData(step: 0)[1] // Type 1 of intersection 00000001

/// A point `north` and `east` metres-ish (in degrees) away from the demo intersection.
private func near(latitude: Double = 0, longitude: Double = 0) -> Coordinate {
    Coordinate(latitude: DemoAdvertiser.coordinate.latitude + latitude, longitude: DemoAdvertiser.coordinate.longitude + longitude)
}

@Suite("Field collector, schema 2")
struct CollectorSchema2Tests {
    @Test("transmitters are numbered per report in order of appearance; emitterInfo keeps the latest valid values")
    func emitterNumbers() throws {
        var collector = FieldCollector()
        try collector.feed(signalData([0x31]), at: 0, emitter: "B", txPower: 4, connectable: true)
        try collector.feed(signalData([0x31]), at: 0.5, emitter: "A", txPower: 99) // sampled out, still numbered; 99 dBm ignored
        try collector.feed(signalData([0x31]), at: 5, emitter: "A", txPower: -8, connectable: false)
        try collector.feed(signalData([0x31]), at: 10, emitter: "B") // keeps 4 dBm and connectable
        try collector.feed(signalData([0x31]), at: 15) // no alias: no number
        let report = try collector.requireReport(client: nil)
        let intersection = report.intersections[0]
        #expect(intersection.emitters == 2)
        #expect(intersection.emitterInfo == [.init(txPower: 4, connectable: true), .init(txPower: -8, connectable: false)])
        #expect(intersection.observations.map(\.emitter) == [0, 1, 0, nil])
        #expect(!String(decoding: try report.encoded(), as: UTF8.self).contains("\"A\""))

        // The next report numbers afresh.
        try collector.feed(signalData([0x31]), at: 20, emitter: "A")
        let next = try collector.requireReport(client: nil).intersections[0]
        #expect(next.observations.map(\.emitter) == [0])
        #expect(next.emitterInfo == [.init()])
    }

    @Test("at most 32 transmitters are numbered; packets of further ones carry no number")
    func emitterLimit() throws {
        var collector = FieldCollector()
        for index in 0..<34 {
            try collector.feed(signalData([0x31]), at: Double(index) * 5, emitter: "E\(index)", txPower: -index)
        }
        let intersection = try collector.requireReport(client: nil).intersections[0]
        #expect(intersection.emitters == 32)
        #expect(intersection.emitterInfo.map(\.txPower) == (0..<32).map { -$0 })
        #expect(intersection.observations.map(\.emitter) == (0..<32).map { $0 } + [nil, nil])
        #expect(intersection.packets.map(\.emitter) == Array(0..<32))
    }

    @Test("packet statistics count every packet before sampling and give the shortest and lower median interval")
    func packetStatistics() throws {
        var collector = FieldCollector()
        for time in [0, 0.094, 0.3, 0.6, 1.0] { // intervals 90, 210, 300, 400 ms
            try collector.feed(signalData([0x31]), at: time, emitter: "A")
        }
        try collector.feed(positionData, at: 0.2, emitter: "A")
        for time in [0.05, 0.25, 0.45] {
            try collector.feed(signalData([0x31]), at: time, emitter: "B")
        }
        try collector.feed(signalData([0x31]), at: 0.7) // no transmitter number: not counted
        let intersection = try collector.requireReport(client: nil).intersections[0]
        let expectedPackets: [FieldReport.PacketStats] = [
            .init(emitter: 0, type: 1, count: 1, minInterval: nil, medianInterval: nil),
            .init(emitter: 0, type: 2, count: 5, minInterval: 90, medianInterval: 210),
            .init(emitter: 1, type: 2, count: 3, minInterval: 200, medianInterval: 200),
        ]
        #expect(intersection.packets == expectedPackets)
        #expect(intersection.observations.count == 2) // sampling keeps one per message type
    }

    @Test("at most 10,000 intervals are kept per transmitter and type, but every packet is counted")
    func packetIntervalLimit() throws {
        var collector = FieldCollector()
        for index in 0...FieldCollector.maxIntervalsPerPacketKey {
            try collector.feed(signalData([0x31]), at: Double(index) * 0.1, emitter: "A")
        }
        let last = Double(FieldCollector.maxIntervalsPerPacketKey) * 0.1
        for index in 1...5 {
            try collector.feed(signalData([0x31]), at: last + Double(index) * 0.001, emitter: "A") // 0 ms, not kept
        }
        let stats = try collector.requireReport(client: nil).intersections[0].packets
        #expect(stats == [.init(emitter: 0, type: 2, count: FieldCollector.maxIntervalsPerPacketKey + 6, minInterval: 100, medianInterval: 100)])
    }

    @Test("coverage: periods with packets at most 5 s apart, in whole seconds, per report")
    func coverage() throws {
        var collector = FieldCollector()
        for time in [0.4, 3, 7.5, 13, 15.9] { // 7.5 → 13 is 5.5 s
            try collector.feed(signalData([0x31]), at: time)
        }
        try collector.feed(positionData, at: 17.2)
        let expectedCoverage: [FieldReport.Coverage] = [
            .init(start: t0, end: t0 + 7),
            .init(start: t0 + 13, end: t0 + 17),
        ]
        #expect(try collector.requireReport(client: nil).intersections[0].coverage == expectedCoverage)
        try collector.feed(signalData([0x31]), at: 18) // a new report starts a new period
        #expect(try collector.requireReport(client: nil).intersections[0].coverage == [.init(start: t0 + 18, end: t0 + 18)])
    }

    @Test("coverage keeps the first 60 periods; the last one still grows while reception continues")
    func coverageLimit() throws {
        var collector = FieldCollector()
        for period in 0..<FieldCollector.maxCoveragePerIntersection {
            try collector.feed(signalData([0x31]), at: Double(period) * 10)
        }
        try collector.feed(signalData([0x31]), at: 593)
        try collector.feed(signalData([0x31]), at: 600) // a 61st period: not kept
        try collector.feed(signalData([0x31]), at: 602) // continues the 61st, not the 60th
        let coverage = try collector.requireReport(client: nil).intersections[0].coverage
        #expect(coverage.count == 60)
        #expect(coverage.first == .init(start: t0, end: t0))
        #expect(coverage.last == .init(start: t0 + 590, end: t0 + 593))
    }

    @Test("transitions carry the transmitter, the gap and, under continuous reception, held and cycle")
    func transitionTiming() throws {
        var collector = FieldCollector()
        let red: [UInt8] = [0x31], green: [UInt8] = [0x33], blink: [UInt8] = [0x32]
        let timeline: [(Double, [UInt8], String)] = [
            (0, red, "A"), (2, red, "A"), (2.3, green, "B"),
            (4, green, "A"), (8, green, "A"), (12, green, "A"), (16, green, "A"), (20, blink, "A"),
            (24, blink, "A"), (25.4, red, "A"),
            (29, red, "A"), (33, red, "A"), (37, red, "A"), (40, green, "B"),
        ]
        for (time, states, emitter) in timeline {
            try collector.feed(signalData(states), at: time, emitter: emitter)
        }
        let expectedTransitions: [FieldReport.Transition] = [
            .init(t: t0 + 2, ms: 300, slot: 1, from: .red, to: .green, emitter: 1, gap: 300),
            .init(t: t0 + 20, ms: 0, slot: 1, from: .green, to: .blinkGreen, emitter: 0, gap: 4000, held: 17_700),
            .init(t: t0 + 25, ms: 400, slot: 1, from: .blinkGreen, to: .red, emitter: 0, gap: 1400, held: 5400),
            .init(t: t0 + 40, ms: 0, slot: 1, from: .red, to: .green, emitter: 1, gap: 3000, held: 14_600, cycle: 37_700),
        ]
        #expect(try collector.requireReport(client: nil).intersections[0].transitions == expectedTransitions)
    }

    @Test("held and cycle span report windows, but not a pause in reception or resetSignalStates")
    func transitionTimingContinuity() throws {
        var collector = FieldCollector()
        let red: [UInt8] = [0x31], green: [UInt8] = [0x33], blink: [UInt8] = [0x32]
        try collector.feed(signalData(red), at: 0)
        try collector.feed(signalData(green), at: 1)
        let expectedTransitions: [FieldReport.Transition] = [
            .init(t: t0 + 1, ms: 0, slot: 1, from: .red, to: .green, gap: 1000),
        ]
        #expect(try collector.requireReport(client: nil).intersections[0].transitions == expectedTransitions)
        for (time, states) in [(3.0, green), (4, blink), (5, red), (6, green)] {
            try collector.feed(signalData(states), at: time)
        }
        // Pause: the change into green at 6 is forgotten.
        for (time, states) in [(12.0, green), (13, blink), (14, green)] {
            try collector.feed(signalData(states), at: time)
        }
        collector.resetSignalStates()
        for (time, states) in [(15.0, red), (16, green), (17, red)] {
            try collector.feed(signalData(states), at: time)
        }
        let expectedTransitions2: [FieldReport.Transition] = [
            .init(t: t0 + 4, ms: 0, slot: 1, from: .green, to: .blinkGreen, gap: 1000, held: 3000),
            .init(t: t0 + 5, ms: 0, slot: 1, from: .blinkGreen, to: .red, gap: 1000, held: 1000),
            .init(t: t0 + 6, ms: 0, slot: 1, from: .red, to: .green, gap: 1000, held: 1000, cycle: 5000),
            .init(t: t0 + 13, ms: 0, slot: 1, from: .green, to: .blinkGreen, gap: 1000),
            .init(t: t0 + 14, ms: 0, slot: 1, from: .blinkGreen, to: .green, gap: 1000, held: 1000),
            .init(t: t0 + 16, ms: 0, slot: 1, from: .red, to: .green, gap: 1000),
            .init(t: t0 + 17, ms: 0, slot: 1, from: .green, to: .red, gap: 1000, held: 1000),
        ]
        #expect(try collector.requireReport(client: nil).intersections[0].transitions == expectedTransitions2)
    }

    @Test("steps: a changed remaining-time indication with an unchanged state, timed from the last change")
    func steps() throws {
        var collector = FieldCollector()
        // High nibble: remaining − 1 (8 or more: unknown). Slot 2 is unused throughout.
        let timeline: [(Double, UInt8)] = [
            (0, 0x71),            // red, 8
            (1, 0x73),            // green, 8: a transition, which starts the step timer
            (4.2, 0x63),          // green, 7
            (8, 0x53),            // green, 6
            (8.5, 0x53),          // unchanged
            (14, 0x43),           // after a 5.5 s pause: no step
            (16, 0x33),           // green, 4: how long 5 lasted is unknown
            (18, 0x32),           // blinking green, 4: a transition, which restarts the timer
            (19.5, 0x22),         // blinking green, 3
            (20.5, 0xA2),         // blinking green, unknown
            (21, 0xB2),           // still unknown
        ]
        for (time, byte) in timeline {
            try collector.feed(signalData([byte, 0x84]), at: time, emitter: "A")
        }
        let intersection = try collector.requireReport(client: nil).intersections[0]
        let expectedSteps: [FieldReport.Step] = [
            .init(t: t0 + 4, ms: 200, slot: 1, state: .green, from: 8, to: 7, emitter: 0, held: 3200),
            .init(t: t0 + 8, ms: 0, slot: 1, state: .green, from: 7, to: 6, emitter: 0, held: 3800),
            .init(t: t0 + 16, ms: 0, slot: 1, state: .green, from: 5, to: 4, emitter: 0, held: nil),
            .init(t: t0 + 19, ms: 500, slot: 1, state: .blinkGreen, from: 4, to: 3, emitter: 0, held: 1500),
            .init(t: t0 + 20, ms: 500, slot: 1, state: .blinkGreen, from: 3, to: nil, emitter: 0, held: 1000),
        ]
        #expect(intersection.steps == expectedSteps)
        let expectedTransitions: [FieldReport.Transition] = [
            .init(t: t0 + 1, ms: 0, slot: 1, from: .red, to: .green, emitter: 0, gap: 1000),
            .init(t: t0 + 18, ms: 0, slot: 1, from: .green, to: .blinkGreen, emitter: 0, gap: 2000),
        ]
        #expect(intersection.transitions == expectedTransitions)

        // The timer survives the report window.
        try collector.feed(signalData([0x12, 0x84]), at: 22, emitter: "A")
        let expectedSteps2: [FieldReport.Step] = [
            .init(t: t0 + 22, ms: 0, slot: 1, state: .blinkGreen, from: nil, to: 2, emitter: 0, held: 1500),
        ]
        #expect(try collector.requireReport(client: nil).intersections[0].steps == expectedSteps2)
    }

    @Test("at most 600 steps per intersection; reaching the limit asks for a flush")
    func stepLimit() throws {
        var collector = FieldCollector()
        for index in 0...FieldCollector.maxStepsPerIntersection + 5 {
            try collector.feed(signalData([index.isMultiple(of: 2) ? 0x73 : 0x63]), at: Double(index) * 0.5)
        }
        #expect(collector.shouldFlush(at: seconds(1)))
        #expect(try collector.requireReport(client: nil).intersections[0].steps.count == FieldCollector.maxStepsPerIntersection)
    }

    @Test("observations carry distance, accuracy, course, speed and nearby; position-derived values need a usable fix")
    func observationContext() throws {
        var collector = FieldCollector()
        try collector.feed(positionData, at: 0)
        let user = near(latitude: 0.0005) // about 56 m north
        let contexts: [ObservationContext] = [
            .init(userLocation: user, trueHeading: 90, horizontalAccuracy: 7, course: 181, speed: 1.4, nearbyDevices: 12),
            .init(userLocation: user, horizontalAccuracy: 3, course: 90, speed: 0.3, nearbyDevices: 0),
            .init(userLocation: nil, course: 90, speed: 3, nearbyDevices: 150),
            .init(userLocation: user, horizontalAccuracy: 45, course: 90, speed: 3),
            .init(userLocation: user, course: 90, speed: nil),
        ]
        for (index, context) in contexts.enumerated() {
            try collector.feed(signalData([0x31]), at: 1 + Double(index) * 5, context: context)
        }
        let report = try collector.requireReport(client: nil)
        let observations = report.intersections[0].observations.dropFirst()
        #expect(observations.map(\.bearing) == [0, 0, nil, nil, 0])
        #expect(observations.map(\.heading) == [2, nil, nil, nil, nil])
        #expect(observations.map(\.distance) == [40, 40, nil, nil, 40])
        #expect(observations.map(\.accuracy) == [10, 5, nil, nil, nil])
        #expect(observations.map(\.course) == [4, nil, nil, nil, nil])
        #expect(observations.map(\.speed) == [1, 0, nil, nil, nil])
        #expect(observations.map(\.nearby) == [10, 0, 100, nil, nil])
        let json = String(decoding: try report.encoded(), as: UTF8.self)
        #expect(!json.contains("139.76"))
        #expect(!json.contains("35.68"))
    }

    @Test("observations carry the activity, also without a position; it is sent as its name")
    func observationActivity() throws {
        var collector = FieldCollector()
        try collector.feed(positionData, at: 0)
        let contexts: [ObservationContext] = [
            .init(userLocation: near(latitude: 0.0005), horizontalAccuracy: 7, speed: 0, activity: .automotive),
            .init(activity: .walking),
            .init(userLocation: near(latitude: 0.0005), horizontalAccuracy: 45, activity: .cycling),
            .init(),
        ]
        for (index, context) in contexts.enumerated() {
            try collector.feed(signalData([0x31]), at: 1 + Double(index) * 5, context: context)
        }
        let report = try collector.requireReport(client: nil)
        let observations = report.intersections[0].observations.dropFirst()
        #expect(observations.map(\.activity) == [.automotive, .walking, .cycling, nil])
        let object = try #require(try JSONSerialization.jsonObject(with: report.encoded()) as? [String: Any])
        let encoded = try #require((object["intersections"] as? [[String: Any]])?.first?["observations"] as? [[String: Any]])
        #expect(encoded.dropFirst().map { $0["activity"] as? String } == ["automotive", "walking", "cycling", nil])
        #expect(try JSONDecoder().decode(FieldReport.self, from: report.encoded()) == report)
    }

    @Test("labels: crosswalk needs a slot, at most 20 per intersection and report, with heading, bearing and distance")
    func labels() throws {
        var collector = FieldCollector()
        try collector.feed(positionData, at: 0)
        let context = ObservationContext(userLocation: near(longitude: 0.0003), trueHeading: 270, horizontalAccuracy: 8) // about 27 m east
        let accepted = [
            collector.recordLabel(.crosswalk, slot: 2, intersectionID: "00000001", at: seconds(3), context: context),
            collector.recordLabel(.crosswalk, slot: nil, intersectionID: "00000001", at: seconds(3), context: context),
            collector.recordLabel(.crosswalk, slot: 7, intersectionID: "00000001", at: seconds(3), context: context),
            collector.recordLabel(.button, slot: 0, intersectionID: "00000001", at: seconds(3), context: context),
            collector.recordLabel(.button, slot: nil, intersectionID: "0000000a", at: seconds(3), context: context),
            collector.recordLabel(.button, slot: nil, intersectionID: "123", at: seconds(3), context: context),
            collector.recordLabel(.button, slot: nil, intersectionID: "00000001", at: seconds(4.5), context: .init()),
        ]
        #expect(accepted == [true, false, false, false, false, false, true])
        let more = (0..<19).map { _ in
            collector.recordLabel(.button, slot: 6, intersectionID: "00000001", at: seconds(5), context: .init())
        }
        #expect(more == Array(repeating: true, count: 18) + [false])
        let labels = try collector.requireReport(client: nil).intersections[0].labels
        #expect(labels.count == FieldCollector.maxLabelsPerIntersection)
        #expect(labels[0] == .init(t: t0 + 3, kind: .crosswalk, slot: 2, heading: 6, bearing: 2, distance: 20))
        #expect(labels[1] == .init(t: t0 + 4, kind: .button, slot: nil, heading: nil, bearing: nil, distance: nil))
        // A new report has room again.
        let again = collector.recordLabel(.button, slot: nil, intersectionID: "00000001", at: seconds(700), context: .init())
        #expect(again)
    }

    @Test("a label alone puts its intersection in the report and starts the window; the intersection limit applies")
    func labelOnly() throws {
        var collector = FieldCollector()
        let first = collector.recordLabel(.button, slot: 3, intersectionID: "ABCDEF01", at: seconds(0), context: .init(trueHeading: 10))
        #expect(first)
        #expect(collector.windowStart == seconds(0))
        #expect(collector.shouldFlush(at: seconds(600)))
        let report = try collector.requireReport(client: nil)
        #expect(report.intersections == [FieldReport.Intersection(
            id: "ABCDEF01", serviceUUIDs: [], emitters: 0, observations: [], transitions: [],
            labels: [.init(t: t0, kind: .button, slot: 3, heading: 0, bearing: nil, distance: nil)]
        )])
        #expect(ReportContract.encode(report, now: seconds(0)).count == 1)

        for index in 0..<FieldCollector.maxIntersections {
            try collector.feed(signalData([0x31], last: UInt8(index)), at: 0)
        }
        let full = collector.recordLabel(.button, slot: nil, intersectionID: "ABCDEF01", at: seconds(1), context: .init())
        let known = collector.recordLabel(.button, slot: nil, intersectionID: "00000001", at: seconds(1), context: .init())
        #expect(!full)
        #expect(known)
    }

    @Test("schema 4 JSON: every nullable field is an explicit null and every list is present")
    func json() throws {
        var collector = FieldCollector()
        try collector.feed(signalData([0x71]), at: 0, rssi: nil, emitter: "A")
        try collector.feed(signalData([0x73]), at: 1, emitter: "A")
        try collector.feed(signalData([0x63]), at: 2, emitter: "A")
        collector.recordLabel(.button, slot: nil, intersectionID: "00000001", at: seconds(3), context: .init())
        let report = try collector.requireReport(client: "aoshingo-ios/0.2.0")
        let object = try #require(try JSONSerialization.jsonObject(with: report.encoded()) as? [String: Any])
        #expect(object["schema"] as? Int == 4)
        let intersection = try #require((object["intersections"] as? [[String: Any]])?.first)
        #expect(Set(intersection.keys) == ["id", "serviceUUIDs", "emitters", "emitterInfo", "observations", "transitions", "steps", "packets", "coverage", "labels"])

        func only(_ key: String) throws -> [String: Any] {
            try #require((intersection[key] as? [[String: Any]])?.first, "\(key)")
        }
        let info = try only("emitterInfo")
        #expect(Set(info.keys) == ["txPower", "connectable"])
        #expect(info["txPower"] is NSNull && info["connectable"] is NSNull)
        let transition = try only("transitions")
        #expect(Set(transition.keys) == ["t", "ms", "slot", "from", "to", "emitter", "gap", "held", "cycle"])
        #expect(transition["ms"] as? Int == 0)
        #expect(transition["emitter"] as? Int == 0 && transition["gap"] as? Int == 1000)
        #expect(transition["held"] is NSNull && transition["cycle"] is NSNull)
        let step = try only("steps")
        #expect(Set(step.keys) == ["t", "ms", "slot", "state", "from", "to", "emitter", "held"])
        #expect(step["ms"] as? Int == 0)
        #expect(step["state"] as? String == "Green" && step["from"] as? Int == 8 && step["to"] as? Int == 7 && step["held"] as? Int == 1000)
        let packets = try only("packets")
        #expect(Set(packets.keys) == ["emitter", "type", "count", "minInterval", "medianInterval"])
        #expect(packets["count"] as? Int == 3 && packets["minInterval"] as? Int == 1000)
        let coverage = try only("coverage")
        #expect(Set(coverage.keys) == ["start", "end"])
        let label = try only("labels")
        #expect(Set(label.keys) == ["t", "kind", "slot", "heading", "bearing", "distance"])
        #expect(label["kind"] as? String == "button")
        for key in ["slot", "heading", "bearing", "distance"] {
            #expect(label[key] is NSNull, "\(key)")
        }
        let observation = try only("observations")
        #expect(observation["rssi"] is NSNull && observation["emitter"] as? Int == 0)
        #expect(observation["activity"] is NSNull)

        #expect(try JSONDecoder().decode(FieldReport.self, from: report.encoded()) == report)
    }

    @Test("a schema 1 body still decodes: missing schema 2 fields are null or empty")
    func decodesSchema1() throws {
        let json = """
        {"schema":1,"intersections":[{"id":"00000001","serviceUUIDs":[],"emitters":1,
        "observations":[{"t":1794290000,"raw":"CE010000020000000000000131","rssi":-70,"bearing":null,"heading":2}],
        "transitions":[{"t":1794290001,"slot":1,"from":"Red","to":"Green"}]}]}
        """
        let report = try JSONDecoder().decode(FieldReport.self, from: Data(json.utf8))
        #expect(report.schema == 1)
        let intersection = report.intersections[0]
        #expect(intersection.observations == [.init(t: t0, raw: "CE010000020000000000000131", rssi: -70, bearing: nil, heading: 2)])
        #expect(intersection.transitions == [.init(t: t0 + 1, slot: 1, from: .red, to: .green)])
        #expect(intersection.emitterInfo.isEmpty && intersection.steps.isEmpty && intersection.packets.isEmpty)
        #expect(intersection.coverage.isEmpty && intersection.labels.isEmpty)
    }
}
