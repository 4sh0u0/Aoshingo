// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
@testable import PICSKit

private let green = PedestrianSignal(remaining: 5, state: .green)
private let blink = PedestrianSignal(remaining: 2, state: .blinkGreen)
private let red = PedestrianSignal(remaining: 8, state: .red)

@Suite("Signal debouncer")
struct SignalDebouncerTests {
    @Test("dangerous changes are confirmed by a single packet")
    func dangerImmediate() {
        var debouncer = SignalDebouncer()
        debouncer.feed(green)
        debouncer.feed(green)
        #expect(debouncer.confirmed?.state == .green)
        #expect(debouncer.feed(blink) == blink)
        #expect(debouncer.feed(red) == red)
        #expect(debouncer.feed(PedestrianSignal(remaining: nil, state: .noSignal))?.state == .noSignal)
    }

    @Test("safer changes need two consecutive identical states")
    func saferNeedsTwo() {
        var debouncer = SignalDebouncer()
        #expect(debouncer.feed(red) == red)
        #expect(debouncer.feed(green) == nil)
        #expect(debouncer.confirmed == red)
        #expect(debouncer.feed(green)?.state == .green)
    }

    @Test("an interrupted safer change starts counting again")
    func interrupted() {
        var debouncer = SignalDebouncer()
        debouncer.feed(red)
        #expect(debouncer.feed(green) == nil)
        #expect(debouncer.feed(red) == nil) // same state as confirmed: no change, pending cleared
        #expect(debouncer.feed(green) == nil)
        #expect(debouncer.feed(green)?.state == .green)
    }

    @Test("the first packet is held when it says green, confirmed at once when red")
    func firstPacket() {
        var first = SignalDebouncer()
        #expect(first.feed(green) == nil)
        #expect(first.confirmed == nil)
        #expect(first.feed(green) == green)

        var second = SignalDebouncer()
        #expect(second.feed(red) == red)
    }

    @Test("remaining-time updates within one state apply silently")
    func remainingUpdates() {
        var debouncer = SignalDebouncer()
        debouncer.feed(red)
        let later = PedestrianSignal(remaining: 3, state: .red)
        #expect(debouncer.feed(later) == nil)
        #expect(debouncer.confirmed == later)
    }

    @Test("slot debouncers report changed slots, numbered from 1")
    func slots() {
        var slots = SlotDebouncers()
        let first = slots.feed([red, green])
        #expect(first.map(\.slot) == [1])
        let second = slots.feed([red, green])
        #expect(second.map(\.slot) == [2])
        #expect(slots.confirmed.prefix(2).map { $0?.state } == [.red, .green])
        slots.reset()
        #expect(slots.confirmed.allSatisfy { $0 == nil })
    }
}

@Suite("Recording")
struct RecordingTests {
    @Test("JSON Lines round-trip and invalid lines are counted")
    func roundTrip() throws {
        let first = RecordedAdvertisement(
            timestamp: Date(timeIntervalSince1970: 1_794_290_000.1234),
            manufacturerData: DemoAdvertiser.manufacturerData(step: 1)[0],
            metadata: AdvertisementMetadata(rssi: -61, serviceUUIDs: ["FFF0"], emitter: "E1")
        )
        let second = RecordedAdvertisement(timestamp: Date(timeIntervalSince1970: 1_794_290_001), manufacturerData: [0xCE, 0x01])
        var data = try RecordingFormat.encodeLine(first)
        data.append(Data("not json\n\n".utf8))
        data.append(try RecordingFormat.encodeLine(second))
        let decoded = RecordingFormat.decode(data)
        #expect(decoded.records == [first, second])
        #expect(decoded.invalidLines == 1)
        #expect(first.t == 1_794_290_000.123)
        #expect(try PICSParser.parse(manufacturerData: try #require(first.bytes)).intersectionID == "00000001")
        #expect(first.metadata.serviceUUIDs == ["FFF0"])
    }

    @Test("emitter aliases are stable and recording-local")
    func aliases() {
        var aliases = EmitterAliases()
        #expect(aliases.alias(for: "A") == "E1")
        #expect(aliases.alias(for: "B") == "E2")
        #expect(aliases.alias(for: "A") == "E1")
        aliases.reset()
        #expect(aliases.alias(for: "B") == "E1")
    }

    @Test("demo manufacturer data carries the iOS company identifier prefix")
    func demoManufacturerData() throws {
        for data in DemoAdvertiser.manufacturerData(step: 0) {
            #expect(Array(data.prefix(2)) == [0xCE, 0x01])
            _ = try PICSParser.parse(manufacturerData: data)
        }
    }
}
