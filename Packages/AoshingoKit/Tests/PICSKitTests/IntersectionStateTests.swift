// SPDX-License-Identifier: Apache-2.0
//
// Cases ported from web/tests/pics.test.mjs of yumu19/ble-pics-viewer
// (MIT License, Copyright (c) 2025 Tsubasa Yumura), plus Aoshingo-specific cases.

import Foundation
import Testing
@testable import PICSKit

private func packet(type: UInt8, length: Int = 24) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: length)
    bytes[2] = type
    bytes[3] = 42
    bytes.replaceSubrange(6..<10, with: [0x12, 0x34, 0xAB, 0xCD])
    return bytes
}

private func ms(_ value: Double) -> Date { Date(timeIntervalSince1970: value / 1000) }

private func update(_ previous: IntersectionState?, _ bytes: [UInt8], _ time: Double, metadata: AdvertisementMetadata = .init()) throws -> IntersectionState {
    IntersectionState.updated(previous, with: try PICSParser.parse(payload: bytes), raw: bytes, at: ms(time), metadata: metadata)
}

@Suite("Intersection state (ported from pics.test.mjs)")
struct IntersectionStatePortedTests {
    @Test("Type 0/1 updates retain the last signal and signal timestamp")
    func retainsSignals() throws {
        let demo = DemoAdvertiser.payloads(step: 0)
        let (name, position, signals) = (demo[0], demo[1], demo[2])
        var entry = try update(nil, signals, 1000)
        let originalSignals = entry.signals
        entry = try update(entry, name, 2000)
        entry = try update(entry, position, 3000)
        #expect(entry.signals == originalSignals)
        #expect(entry.identifier == "DEMO CROSSING")
        #expect(entry.coordinate?.latitude == 35.681236)
        #expect(entry.signalTimestamp == ms(1000))
        #expect(entry.timestamp == ms(3000))
        #expect(entry.history.count == 1)
        #expect(entry.count == 3)
        #expect(entry.latest.messageType == 1)
    }

    @Test("raw bytes are copied so later changes to the received buffer cannot alter the monitor")
    func rawIsCopied() throws {
        var bytes = packet(type: 2, length: 16)
        let entry = try update(nil, bytes, 1000)
        for index in bytes.indices { bytes[index] = 255 }
        #expect(entry.raw[2] == 2)
    }

    @Test("history retains five Type 2 packets and expires entries after 30 seconds")
    func historyWindow() throws {
        let bytes = packet(type: 2, length: 16)
        var entry: IntersectionState?
        for index in 0..<10 { entry = try update(entry, bytes, Double(index) * 1000) }
        let history = try #require(entry?.history)
        #expect(history.map(\.timestamp) == [5000, 6000, 7000, 8000, 9000].map(ms))
        #expect(recentHistory(history, now: ms(35_000)).count == 5)
        #expect(recentHistory(history, now: ms(35_001)).count == 4)
        #expect(recentHistory(history, now: ms(39_001)).isEmpty)
    }

    @Test("intersection entries do not share signals or history")
    func entriesIndependent() throws {
        var bytes = packet(type: 2, length: 16)
        let first = try update(nil, bytes, 1000)
        bytes[9] = 0xCE
        let second = try update(nil, bytes, 2000)
        #expect(first.id != second.id)
        #expect(first.history[0].timestamp == ms(1000))
        #expect(second.history[0].timestamp == ms(2000))
    }

    @Test("demo cycles through red, green, and blinking green using real parser")
    func demoCycles() throws {
        var states = Set<SignalState>()
        for step in 0..<48 {
            for bytes in DemoAdvertiser.payloads(step: step) {
                let info = try PICSParser.parse(payload: bytes)
                #expect(info.intersectionID == DemoAdvertiser.intersectionID)
                states.formUnion((info.signals ?? []).map(\.state))
            }
        }
        #expect(states.isSuperset(of: [.red, .green, .blinkGreen]))
    }
}

@Suite("Intersection state (Aoshingo)")
struct IntersectionStateTests {
    @Test("signal becomes stale after five seconds without Type 2, and is stale before any Type 2")
    func staleness() throws {
        let demo = DemoAdvertiser.payloads(step: 0)
        var entry = try update(nil, demo[0], 0)
        #expect(entry.isSignalStale(at: ms(0)))
        entry = try update(entry, demo[2], 1000)
        #expect(!entry.isSignalStale(at: ms(5999)))
        #expect(entry.isSignalStale(at: ms(6000)))
        // Type 0/1 do not refresh the signal age.
        entry = try update(entry, demo[1], 5500)
        #expect(entry.isSignalStale(at: ms(6000)))
        #expect(entry.signalAge(at: ms(3000)) == 2)
    }

    @Test("metadata: RSSI smoothing ignores 127, service UUIDs and emitters accumulate")
    func metadata() throws {
        let bytes = packet(type: 2, length: 16)
        var entry = try update(nil, bytes, 0, metadata: .init(rssi: -60, serviceUUIDs: ["fff0"], emitter: "E1"))
        entry = try update(entry, bytes, 100, metadata: .init(rssi: 127, emitter: "E2"))
        #expect(entry.rssi == -60)
        #expect(entry.smoothedRSSI == -60)
        entry = try update(entry, bytes, 200, metadata: .init(rssi: -70))
        #expect(entry.rssi == -70)
        #expect(abs((entry.smoothedRSSI ?? 0) - -63) < 0.0001)
        #expect(entry.serviceUUIDs == ["FFF0"])
        #expect(entry.emitters == ["E1", "E2"])
    }

    @Test("per-type statistics measure advertising intervals")
    func intervals() throws {
        let bytes = packet(type: 2, length: 16)
        var entry: IntersectionState?
        for time in [0.0, 100, 300, 600] { entry = try update(entry, bytes, time) }
        let stats = try #require(entry?.messageTypes[2])
        #expect(stats.count == 4)
        #expect(abs((stats.meanInterval ?? 0) - 0.2) < 0.0001)
        #expect(abs((stats.shortestInterval ?? 0) - 0.1) < 0.0001)
    }

    @Test("active slots skip unused (None) signals and are numbered from 1")
    func activeSlots() throws {
        var bytes = packet(type: 2, length: 16)
        bytes.replaceSubrange(10..<16, with: [0x84, 0x13, 0x84, 0x31, 0x84, 0x84])
        let entry = try update(nil, bytes, 0)
        #expect(entry.activeSlots.map(\.slot) == [2, 4])
        #expect(entry.activeSlots.map(\.signal.state) == [.green, .red])
    }
}

@Suite("Intersection store")
struct IntersectionStoreTests {
    @Test("keeps at most `capacity` intersections and drops the first registered")
    func capacity() throws {
        var store = IntersectionStore(capacity: 2)
        for (index, last) in [UInt8(1), 2, 3].enumerated() {
            var bytes = packet(type: 2, length: 16)
            bytes[9] = last
            store.ingest(try PICSParser.parse(payload: bytes), raw: bytes, at: ms(Double(index) * 1000))
        }
        #expect(store.order == ["1234AB02", "1234AB03"])
        #expect(store["1234AB01"] == nil)
        #expect(store.all.count == 2)
    }

    @Test("nearest picks the strongest recent RSSI, then the most recent packet")
    func nearest() throws {
        var store = IntersectionStore()
        var near = packet(type: 2, length: 16)
        near[9] = 0x01
        var far = packet(type: 2, length: 16)
        far[9] = 0x02
        store.ingest(try PICSParser.parse(payload: near), raw: near, at: ms(0), metadata: .init(rssi: -55))
        store.ingest(try PICSParser.parse(payload: far), raw: far, at: ms(500), metadata: .init(rssi: -80))
        #expect(store.nearest(at: ms(1000))?.id == "1234AB01")
        #expect(store.nearest(at: ms(10_200))?.id == "1234AB02")
        #expect(store.nearest(at: ms(20_000)) == nil)

        var noRSSI = IntersectionStore()
        noRSSI.ingest(try PICSParser.parse(payload: near), raw: near, at: ms(0))
        noRSSI.ingest(try PICSParser.parse(payload: far), raw: far, at: ms(100))
        #expect(noRSSI.nearest(at: ms(200))?.id == "1234AB02")
    }
}
