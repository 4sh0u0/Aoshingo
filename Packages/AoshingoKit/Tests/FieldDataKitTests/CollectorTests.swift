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
    mutating func feed(_ data: [UInt8], at time: Double, rssi: Int? = -67, context: ObservationContext = .init(), emitter: String? = nil, serviceUUIDs: [String] = []) throws {
        let packet = try PICSParser.parse(manufacturerData: data)
        record(packet, manufacturerData: data, at: seconds(time), rssi: rssi, serviceUUIDs: serviceUUIDs, emitter: emitter, context: context)
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

    @Test func clientString() {
        #expect(FieldReport.clientString(version: "0.1.0") == "aoshingo-ios/0.1.0")
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

    @Test("transitions are recorded per slot with second resolution and survive a window boundary")
    func transitions() throws {
        var collector = FieldCollector()
        try collector.feed(signalData([0x31, 0x13]), at: 0.4)
        try collector.feed(signalData([0x33, 0x13]), at: 1.7)
        try collector.feed(signalData([0x32, 0x11]), at: 2.2)
        let first = try collector.requireReport(client: "aoshingo-ios/0.1.0")
        #expect(first.intersections[0].transitions == [
            .init(t: 1_794_290_001, slot: 1, from: .red, to: .green),
            .init(t: 1_794_290_002, slot: 1, from: .green, to: .blinkGreen),
            .init(t: 1_794_290_002, slot: 2, from: .green, to: .red),
        ])
        try collector.feed(signalData([0x31, 0x11]), at: 3.0)
        let second = try collector.requireReport(client: nil)
        #expect(second.intersections[0].transitions == [.init(t: 1_794_290_003, slot: 1, from: .blinkGreen, to: .red)])
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

    @Test("discardAll forgets the window and the last states")
    func discard() throws {
        var collector = FieldCollector()
        try collector.feed(signalData([0x31]), at: 0)
        collector.discardAll()
        try collector.feed(signalData([0x33]), at: 1)
        #expect(try collector.requireReport(client: nil).intersections[0].transitions.isEmpty)
    }

    @Test("report JSON follows the contract: schema 1, explicit nulls, uppercase raw hex starting with CE01")
    func json() throws {
        var collector = FieldCollector()
        try collector.feed(signalData([0x31]), at: 0, rssi: nil)
        let report = try collector.requireReport(client: "aoshingo-ios/0.1.0")
        let object = try #require(try JSONSerialization.jsonObject(with: report.encoded()) as? [String: Any])
        #expect(object["schema"] as? Int == 1)
        #expect(object["client"] as? String == "aoshingo-ios/0.1.0")
        let intersection = try #require((object["intersections"] as? [[String: Any]])?.first)
        #expect(intersection["id"] as? String == "00000001")
        let observation = try #require((intersection["observations"] as? [[String: Any]])?.first)
        #expect(observation["raw"] as? String == "CE010000020000000000000131")
        #expect(observation["rssi"] is NSNull)
        #expect(observation["bearing"] is NSNull)
        #expect(observation["heading"] is NSNull)
        #expect(Set(observation.keys) == ["t", "raw", "rssi", "bearing", "heading"])
    }
}
