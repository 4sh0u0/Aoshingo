// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
@testable import PICSKit

private let green = PedestrianSignal(remaining: 5, state: .green)
private let blink = PedestrianSignal(remaining: 2, state: .blinkGreen)
private let red = PedestrianSignal(remaining: 8, state: .red)

/// Seconds since an arbitrary reference, as a `Date`.
private func at(_ seconds: Double) -> Date { Date(timeIntervalSinceReferenceDate: 800_000_000 + seconds) }

@Suite("Signal debouncer")
struct SignalDebouncerTests {
    @Test("dangerous changes are confirmed by a single packet")
    func dangerImmediate() {
        var debouncer = SignalDebouncer()
        debouncer.feed(green, at: at(0))
        debouncer.feed(green, at: at(1))
        #expect(debouncer.confirmed?.state == .green)
        #expect(debouncer.feed(blink, at: at(1.01)) == blink)
        #expect(debouncer.feed(red, at: at(1.02)) == red)
        #expect(debouncer.feed(PedestrianSignal(remaining: nil, state: .noSignal), at: at(1.03))?.state == .noSignal)
    }

    @Test("safer changes need two consecutive identical states")
    func saferNeedsTwo() {
        var debouncer = SignalDebouncer()
        #expect(debouncer.feed(red, at: at(0)) == red)
        #expect(debouncer.feed(green, at: at(1)) == nil)
        #expect(debouncer.confirmed == red)
        #expect(debouncer.feed(green, at: at(2))?.state == .green)
    }

    @Test("an interrupted safer change starts counting again")
    func interrupted() {
        var debouncer = SignalDebouncer()
        debouncer.feed(red, at: at(0))
        #expect(debouncer.feed(green, at: at(1)) == nil)
        #expect(debouncer.feed(red, at: at(2)) == nil) // same state as confirmed: no change, pending cleared
        #expect(debouncer.feed(green, at: at(3)) == nil)
        #expect(debouncer.feed(green, at: at(4))?.state == .green)
    }

    @Test("the first packet is held when it says green, confirmed at once when red")
    func firstPacket() {
        var first = SignalDebouncer()
        #expect(first.feed(green, at: at(0)) == nil)
        #expect(first.confirmed == nil)
        #expect(first.feed(green, at: at(1)) == green)

        var second = SignalDebouncer()
        #expect(second.feed(red, at: at(0)) == red)
    }

    @Test("remaining-time updates within one state apply silently")
    func remainingUpdates() {
        var debouncer = SignalDebouncer()
        debouncer.feed(red, at: at(0))
        let later = PedestrianSignal(remaining: 3, state: .red)
        #expect(debouncer.feed(later, at: at(1)) == nil)
        #expect(debouncer.confirmed == later)
    }

    @Test("slot debouncers report changed slots, numbered from 1")
    func slots() {
        var slots = SlotDebouncers()
        let first = slots.feed([red, green], at: at(0))
        #expect(first.map(\.slot) == [1])
        let second = slots.feed([red, green], at: at(1))
        #expect(second.map(\.slot) == [2])
        #expect(slots.confirmed.prefix(2).map { $0?.state } == [.red, .green])
        slots.reset()
        #expect(slots.confirmed.allSatisfy { $0 == nil })
    }
}

@Suite("Signal debouncer: duplicate deliveries")
struct SignalDebouncerSpacingTests {
    @Test("a repeat within the minimum spacing does not confirm green; 判定中 stays until a later packet")
    func duplicateDoesNotConfirm() {
        var debouncer = SignalDebouncer()
        #expect(debouncer.feed(green, at: at(0)) == nil)
        // The same broadcast delivered again a few milliseconds later.
        #expect(debouncer.feed(green, at: at(0.005)) == nil)
        #expect(debouncer.feed(green, at: at(0.3)) == nil)
        // Nothing confirmed yet: the UI shows 判定中.
        #expect(debouncer.confirmed == nil)
        #expect(debouncer.feed(green, at: at(0.5))?.state == .green)
    }

    @Test("spacing is measured from the first counted packet, not from the ignored repeats")
    func spacingFromCountedPacket() {
        var debouncer = SignalDebouncer()
        debouncer.feed(red, at: at(0))
        #expect(debouncer.feed(green, at: at(10)) == nil)
        #expect(debouncer.feed(green, at: at(10.2)) == nil)
        #expect(debouncer.feed(green, at: at(10.4)) == nil)
        #expect(debouncer.confirmed == red)
        #expect(debouncer.feed(green, at: at(10.49)) == nil)
        #expect(debouncer.feed(green, at: at(10.5))?.state == .green)
    }

    @Test("the newest remaining time is kept while a safer change is pending")
    func pendingKeepsNewestRemaining() {
        var debouncer = SignalDebouncer()
        debouncer.feed(red, at: at(0))
        debouncer.feed(PedestrianSignal(remaining: 8, state: .green), at: at(1))
        debouncer.feed(PedestrianSignal(remaining: 7, state: .green), at: at(1.1))
        #expect(debouncer.feed(PedestrianSignal(remaining: 6, state: .green), at: at(1.6)) == PedestrianSignal(remaining: 6, state: .green))
    }

    @Test("danger is still confirmed at once, even right after a held green")
    func dangerNotDelayed() {
        var debouncer = SignalDebouncer()
        #expect(debouncer.feed(green, at: at(0)) == nil)
        #expect(debouncer.feed(red, at: at(0.01)) == red)
        // The pending green was dropped: it has to be confirmed again from scratch.
        #expect(debouncer.feed(green, at: at(0.6)) == nil)
        #expect(debouncer.feed(green, at: at(1.2))?.state == .green)
    }

    @Test("blinking green to green also waits for a spaced second packet")
    func blinkToGreen() {
        var debouncer = SignalDebouncer()
        debouncer.feed(blink, at: at(0))
        debouncer.feed(blink, at: at(1))
        #expect(debouncer.confirmed?.state == .blinkGreen)
        #expect(debouncer.feed(green, at: at(2)) == nil)
        #expect(debouncer.feed(green, at: at(2.1)) == nil)
        #expect(debouncer.confirmed?.state == .blinkGreen)
        #expect(debouncer.feed(green, at: at(2.5))?.state == .green)
    }

    @Test("a clock that goes backwards restarts the count instead of confirming")
    func clockBackwards() {
        var debouncer = SignalDebouncer()
        debouncer.feed(red, at: at(100))
        #expect(debouncer.feed(green, at: at(100)) == nil)
        #expect(debouncer.feed(green, at: at(40)) == nil)
        #expect(debouncer.feed(green, at: at(40.2)) == nil)
        #expect(debouncer.confirmed == red)
        #expect(debouncer.feed(green, at: at(40.5))?.state == .green)
    }

    @Test("slot debouncers apply the spacing to every slot")
    func slotsSpacing() {
        var slots = SlotDebouncers()
        #expect(slots.feed([red, green], at: at(0)).map(\.slot) == [1])
        #expect(slots.feed([red, green], at: at(0.01)).isEmpty)
        #expect(slots.confirmed.prefix(2).map { $0?.state } == [.red, nil])
        #expect(slots.feed([red, green], at: at(0.5)).map(\.slot) == [2])
    }

    @Test("a zero spacing counts every packet, as before")
    func zeroSpacing() {
        var debouncer = SignalDebouncer(minimumSpacing: 0)
        #expect(debouncer.feed(green, at: at(0)) == nil)
        #expect(debouncer.feed(green, at: at(0))?.state == .green)
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
