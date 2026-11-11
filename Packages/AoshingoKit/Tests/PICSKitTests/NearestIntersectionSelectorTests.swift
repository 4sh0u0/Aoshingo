// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
@testable import PICSKit

/// Intersections A, B, C, D have IDs 1234AB0A … 1234AB0D.
private enum Crossing: UInt8 {
    case a = 0x0A, b = 0x0B, c = 0x0C, d = 0x0D

    var id: String { "1234AB0" + String(rawValue, radix: 16, uppercase: true) }

    var payload: [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 16)
        bytes[2] = 2
        bytes.replaceSubrange(6..<10, with: [0x12, 0x34, 0xAB, rawValue])
        bytes.replaceSubrange(10..<16, with: [0x31, 0x13, 0x84, 0x84, 0x84, 0x84])
        return bytes
    }
}

private func at(_ seconds: Double) -> Date { Date(timeIntervalSinceReferenceDate: 800_000_000 + seconds) }

/// A store and a selector driven the way AppModel drives them: an update after every packet,
/// plus ticks while nothing arrives.
private struct Scenario {
    var store = IntersectionStore()
    var selector = NearestIntersectionSelector()

    /// Ingests one packet and returns the followed intersection ID afterwards.
    @discardableResult
    mutating func hear(_ crossing: Crossing, rssi: Int?, at seconds: Double) throws -> String? {
        try ingestOnly(crossing, rssi: rssi, at: seconds)
        return selector.update(with: store, at: at(seconds))
    }

    /// Ingests one packet without evaluating the selector.
    mutating func ingestOnly(_ crossing: Crossing, rssi: Int?, at seconds: Double) throws {
        let payload = crossing.payload
        store.ingest(
            try PICSParser.parse(payload: payload),
            raw: payload,
            at: at(seconds),
            metadata: AdvertisementMetadata(rssi: rssi)
        )
    }

    @discardableResult
    mutating func tick(at seconds: Double) -> String? {
        selector.update(with: store, at: at(seconds))
    }
}

@Suite("Nearest intersection selector")
struct NearestIntersectionSelectorTests {
    @Test("the hysteresis constants are 6 dB, 3 s and a 10 s window")
    func constants() {
        #expect(NearestIntersectionSelector.switchMargin == 6)
        #expect(NearestIntersectionSelector.switchDelay == 3)
        #expect(NearestIntersectionSelector.recentWindow == 10)
    }

    @Test("first lock takes the strongest recently heard intersection at once")
    func firstLock() throws {
        var scenario = Scenario()
        #expect(scenario.tick(at: 0) == nil)
        #expect(try scenario.hear(.a, rssi: -70, at: 0) == Crossing.a.id)

        // When several were heard before the first evaluation, the strongest wins.
        var several = Scenario()
        try several.ingestOnly(.a, rssi: -70, at: 0)
        try several.ingestOnly(.b, rssi: -58, at: 0.25)
        try several.ingestOnly(.c, rssi: -64, at: 0.5)
        #expect(several.tick(at: 0.75) == Crossing.b.id)

        // Without any RSSI, the most recently heard one.
        var noRSSI = Scenario()
        try noRSSI.ingestOnly(.a, rssi: nil, at: 0)
        try noRSSI.ingestOnly(.b, rssi: nil, at: 1)
        try noRSSI.ingestOnly(.a, rssi: nil, at: 2)
        #expect(noRSSI.tick(at: 2.5) == Crossing.a.id)
    }

    @Test("a lead below 6 dB never switches, however long it lasts")
    func leadBelowMargin() throws {
        var scenario = Scenario()
        try scenario.hear(.a, rssi: -70, at: 0)
        var time = 0.25
        while time < 60 {
            #expect(try scenario.hear(.b, rssi: -65, at: time) == Crossing.a.id) // lead 5 dB
            #expect(try scenario.hear(.a, rssi: -70, at: time + 0.25) == Crossing.a.id)
            time += 0.5
        }
    }

    @Test("a sustained lead of 6 dB switches after 3 s, and not before")
    func sustainedLeadSwitches() throws {
        var scenario = Scenario()
        try scenario.hear(.a, rssi: -70, at: 0)
        #expect(try scenario.hear(.b, rssi: -64, at: 0.5) == Crossing.a.id) // leads by exactly 6 dB from 0.5 s
        #expect(try scenario.hear(.a, rssi: -70, at: 1) == Crossing.a.id)
        #expect(try scenario.hear(.b, rssi: -64, at: 1.5) == Crossing.a.id)
        #expect(try scenario.hear(.a, rssi: -70, at: 2) == Crossing.a.id)
        #expect(try scenario.hear(.b, rssi: -64, at: 2.5) == Crossing.a.id)
        #expect(try scenario.hear(.a, rssi: -70, at: 3) == Crossing.a.id)
        // Time alone is not enough: the lead has to be confirmed by a packet from B.
        #expect(scenario.tick(at: 3.4) == Crossing.a.id)
        #expect(try scenario.hear(.b, rssi: -64, at: 3.49) == Crossing.a.id)
        #expect(try scenario.hear(.b, rssi: -64, at: 3.5) == Crossing.b.id)
        // Once switched, A needs its own sustained lead to come back.
        #expect(try scenario.hear(.a, rssi: -50, at: 4) == Crossing.b.id)
    }

    @Test("a lead that is interrupted starts counting again")
    func leadNotSustained() throws {
        var scenario = Scenario()
        try scenario.hear(.a, rssi: -70, at: 0)
        try scenario.hear(.b, rssi: -60, at: 0.5)   // lead 10 dB from 0.5 s
        try scenario.hear(.b, rssi: -60, at: 2.5)
        // One weak packet: smoothed RSSI −60 + 0.3 × (−90 + 60) = −69, a lead of 1 dB.
        #expect(try scenario.hear(.b, rssi: -90, at: 3) == Crossing.a.id)
        // Strong again: −69 + 0.3 × (−50 + 69) = −63.3, leading again from 3.25 s.
        #expect(try scenario.hear(.b, rssi: -50, at: 3.25) == Crossing.a.id)
        // Without the interruption this would have switched (3.25 s after 0.5 s).
        #expect(try scenario.hear(.b, rssi: -50, at: 3.75) == Crossing.a.id)
        #expect(try scenario.hear(.b, rssi: -50, at: 6) == Crossing.a.id)
        #expect(try scenario.hear(.b, rssi: -50, at: 6.25) == Crossing.b.id)
    }

    @Test("the followed intersection getting stronger again cancels a pending switch")
    func followedRecovers() throws {
        var scenario = Scenario()
        try scenario.hear(.a, rssi: -70, at: 0)
        try scenario.hear(.b, rssi: -62, at: 0.5)                     // lead 8 dB
        #expect(try scenario.hear(.a, rssi: -50, at: 2) == Crossing.a.id) // A: −64, lead 2 dB
        #expect(try scenario.hear(.b, rssi: -62, at: 4) == Crossing.a.id)
    }

    @Test("one strong packet followed by silence does not take over")
    func singleStrongPacket() throws {
        var scenario = Scenario()
        try scenario.hear(.a, rssi: -70, at: 0)
        try scenario.hear(.b, rssi: -40, at: 0.5)
        for second in 1...9 {
            #expect(try scenario.hear(.a, rssi: -70, at: Double(second)) == Crossing.a.id)
            #expect(scenario.tick(at: Double(second) + 0.5) == Crossing.a.id)
        }
    }

    @Test("of two candidates that both lead, the stronger one is followed")
    func strongestReadyCandidate() throws {
        var scenario = Scenario()
        try scenario.hear(.a, rssi: -80, at: 0)
        try scenario.ingestOnly(.b, rssi: -70, at: 0.25)
        try scenario.ingestOnly(.c, rssi: -60, at: 0.25)
        #expect(scenario.tick(at: 0.5) == Crossing.a.id) // both lead from 0.5 s
        for step in 1...6 {
            let time = 0.5 + Double(step) * 0.5
            try scenario.ingestOnly(.b, rssi: -70, at: time)
            try scenario.ingestOnly(.c, rssi: -60, at: time)
        }
        // Both have led for 3 s at this evaluation; the stronger one is chosen.
        #expect(scenario.tick(at: 3.5) == Crossing.c.id)
    }

    @Test("when the followed intersection expires, the most recently heard one is followed")
    func expiryFallsBackToLastHeard() throws {
        var scenario = Scenario()
        try scenario.hear(.a, rssi: -60, at: 0)
        for second in 1...9 {
            #expect(try scenario.hear(.b, rssi: -80, at: Double(second)) == Crossing.a.id)
        }
        #expect(scenario.tick(at: 10) == Crossing.a.id) // heard exactly 10 s ago: still recent
        #expect(scenario.tick(at: 10.5) == Crossing.b.id)

        // Without RSSI (for example a recording without it) the most recently heard one wins.
        var noRSSI = Scenario()
        try noRSSI.hear(.a, rssi: nil, at: 0)
        try noRSSI.hear(.b, rssi: nil, at: 5)
        try noRSSI.hear(.c, rssi: nil, at: 8)
        #expect(noRSSI.selector.followedID == Crossing.a.id)
        #expect(noRSSI.tick(at: 10.5) == Crossing.c.id)
    }

    @Test("when nothing was heard recently, the followed intersection is kept")
    func expiryWithNothingRecent() throws {
        var scenario = Scenario()
        try scenario.hear(.a, rssi: -60, at: 0)
        try scenario.hear(.b, rssi: -80, at: 2)
        #expect(scenario.tick(at: 100) == Crossing.a.id)
        // And it can still be replaced as soon as something else is heard.
        #expect(try scenario.hear(.b, rssi: -80, at: 101) == Crossing.b.id)
    }

    @Test("with nothing followed, the most recently heard intersection is taken, not the last registered")
    func noLockFallsBackToLastHeard() throws {
        var scenario = Scenario()
        try scenario.hear(.a, rssi: -60, at: 0)   // registered first
        try scenario.hear(.b, rssi: -60, at: 10)  // registered last
        try scenario.hear(.a, rssi: -60, at: 20)  // heard last
        scenario.selector.reset()
        #expect(scenario.store.all.last?.id == Crossing.b.id)
        #expect(scenario.store.mostRecentlyHeard?.id == Crossing.a.id)
        #expect(scenario.tick(at: 100) == Crossing.a.id)
    }

    @Test("a followed intersection dropped from the store is replaced")
    func droppedFromStore() throws {
        var scenario = Scenario()
        try scenario.hear(.a, rssi: -60, at: 0)
        scenario.store.removeAll()
        #expect(scenario.tick(at: 1) == nil)
        #expect(try scenario.hear(.b, rssi: -90, at: 2) == Crossing.b.id)
    }

    @Test("without RSSI for the followed intersection, strength cannot take it over")
    func followedWithoutRSSI() throws {
        var scenario = Scenario()
        try scenario.hear(.a, rssi: nil, at: 0)
        for second in 1...8 {
            try scenario.hear(.b, rssi: -40, at: Double(second))
            #expect(try scenario.hear(.a, rssi: nil, at: Double(second) + 0.5) == Crossing.a.id)
        }
    }
}
