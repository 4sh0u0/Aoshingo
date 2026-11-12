// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
@testable import PICSKit

private func at(_ seconds: Double) -> Date { Date(timeIntervalSinceReferenceDate: 800_000_000 + seconds) }

private let green = SignalCondition.state(.green)
private let blink = SignalCondition.state(.blinkGreen)
private let red = SignalCondition.state(.red)

@Suite struct SignalChangeMonitorTests {
    @Test func theFirstStatesOfAnIntersectionAreNotSpoken() {
        var monitor = SignalChangeMonitor()
        monitor.update(intersectionID: "A", conditions: [1: red, 2: blink])
        #expect(!monitor.hasPendingChanges)
        #expect(monitor.flush(at: at(0)).isEmpty)
    }

    @Test func changesIntoWarningsAreSpokenForEverySlot() {
        var monitor = SignalChangeMonitor()
        monitor.update(intersectionID: "A", conditions: [1: green, 2: red, 3: green])
        monitor.update(intersectionID: "A", conditions: [1: blink, 2: red, 3: blink])
        #expect(monitor.hasPendingChanges)
        #expect(monitor.flush(at: at(1)) == [.init(condition: blink, slots: [1, 3])])
        #expect(!monitor.hasPendingChanges)

        monitor.update(intersectionID: "A", conditions: [1: red, 2: red, 3: red])
        #expect(monitor.flush(at: at(5)) == [.init(condition: red, slots: [1, 3])])
    }

    @Test func changesTowardsGreenAreNotSpoken() {
        var monitor = SignalChangeMonitor()
        monitor.update(intersectionID: "A", conditions: [1: red])
        monitor.update(intersectionID: "A", conditions: [1: .pending])
        monitor.update(intersectionID: "A", conditions: [1: green])
        #expect(!monitor.hasPendingChanges)
        #expect(monitor.flush(at: at(1)).isEmpty)
    }

    @Test func aChangeStraightFromGreenToRedIsSpoken() {
        // The baseline follows changes towards green, so 赤 → 青 → 赤 without 青点滅 (for example
        // when the blinking was missed) still speaks the second 赤.
        var monitor = SignalChangeMonitor()
        monitor.update(intersectionID: "A", conditions: [1: red])
        monitor.update(intersectionID: "A", conditions: [1: green])
        monitor.update(intersectionID: "A", conditions: [1: red])
        #expect(monitor.flush(at: at(1)) == [.init(condition: red, slots: [1])])
    }

    @Test func changesInTheCollectionWindowAreSpokenTogether() {
        var monitor = SignalChangeMonitor()
        monitor.update(intersectionID: "A", conditions: [1: green, 2: green, 3: red])
        monitor.update(intersectionID: "A", conditions: [1: red, 2: green, 3: red])
        monitor.update(intersectionID: "A", conditions: [1: red, 2: blink, 3: red])
        #expect(monitor.flush(at: at(1)) == [
            .init(condition: red, slots: [1]),
            .init(condition: blink, slots: [2]),
        ])
    }

    @Test func aWarningThatEndedBeforeTheFlushIsNotSpoken() {
        var monitor = SignalChangeMonitor()
        monitor.update(intersectionID: "A", conditions: [1: green])
        monitor.update(intersectionID: "A", conditions: [1: .stale])
        monitor.update(intersectionID: "A", conditions: [1: green])
        #expect(!monitor.hasPendingChanges)
        #expect(monitor.flush(at: at(1)).isEmpty)
    }

    @Test func staleIsSpokenOnceForAllSlots() {
        var monitor = SignalChangeMonitor()
        monitor.update(intersectionID: "A", conditions: [1: green, 2: red])
        monitor.update(intersectionID: "A", conditions: [1: .stale, 2: .stale])
        #expect(monitor.flush(at: at(6)) == [.init(condition: .stale, slots: [1, 2])])
        monitor.update(intersectionID: "A", conditions: [1: .stale, 2: .stale])
        #expect(monitor.flush(at: at(7)).isEmpty)
    }

    @Test func dropoutsAtTheEdgeOfTheRangeAreNotRepeatedWithinTheInterval() {
        var monitor = SignalChangeMonitor()
        monitor.update(intersectionID: "A", conditions: [1: red])
        monitor.update(intersectionID: "A", conditions: [1: .stale])
        #expect(monitor.flush(at: at(0)) == [.init(condition: .stale, slots: [1])])
        monitor.update(intersectionID: "A", conditions: [1: red])
        #expect(monitor.flush(at: at(1)) == [.init(condition: red, slots: [1])])
        monitor.update(intersectionID: "A", conditions: [1: .stale])
        #expect(monitor.flush(at: at(6)).isEmpty)
        monitor.update(intersectionID: "A", conditions: [1: red])
        #expect(monitor.flush(at: at(7)).isEmpty)
        // After the interval the same change is spoken again.
        monitor.update(intersectionID: "A", conditions: [1: .stale])
        #expect(monitor.flush(at: at(12)) == [.init(condition: .stale, slots: [1])])
    }

    @Test func anotherIntersectionStartsAgainSilently() {
        var monitor = SignalChangeMonitor()
        monitor.update(intersectionID: "A", conditions: [1: green])
        monitor.update(intersectionID: "A", conditions: [1: red])
        monitor.update(intersectionID: "B", conditions: [1: blink, 2: red])
        #expect(!monitor.hasPendingChanges)
        #expect(monitor.flush(at: at(1)).isEmpty)
        monitor.update(intersectionID: "B", conditions: [1: red, 2: red])
        #expect(monitor.flush(at: at(2)) == [.init(condition: red, slots: [1])])
    }

    @Test func aSlotHeardForTheFirstTimeIsNotSpoken() {
        var monitor = SignalChangeMonitor()
        monitor.update(intersectionID: "A", conditions: [1: green])
        monitor.update(intersectionID: "A", conditions: [1: green, 2: red])
        #expect(monitor.flush(at: at(1)).isEmpty)
    }

    @Test func conditionsThatNeedAttention() {
        #expect(SignalCondition.stale.needsAttention)
        #expect(SignalCondition.state(.red).needsAttention)
        #expect(SignalCondition.state(.blinkGreen).needsAttention)
        #expect(SignalCondition.state(.noSignal).needsAttention)
        #expect(SignalCondition.state(.unknown).needsAttention)
        #expect(!SignalCondition.state(.green).needsAttention)
        #expect(!SignalCondition.state(.none).needsAttention)
        #expect(!SignalCondition.pending.needsAttention)
    }
}
