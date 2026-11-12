// SPDX-License-Identifier: Apache-2.0

import Foundation
import PICSKit

/// When the next green of one signal probably starts, as a range of seconds from now.
public struct TimingEstimate: Sendable, Hashable {
    /// Seconds from now to the earliest likely start of green, a multiple of 5 (0 or more).
    public var lowerSeconds: Int
    /// Seconds from now to the latest likely start of green, a multiple of 5.
    public var upperSeconds: Int
    /// The predicted start of the next green.
    public var nextGreenStart: Date

    public init(lowerSeconds: Int, upperSeconds: Int, nextGreenStart: Date) {
        self.lowerSeconds = lowerSeconds
        self.upperSeconds = upperSeconds
        self.nextGreenStart = nextGreenStart
    }
}

/// One cell of the plans: intersection × slot × day type × time bin.
public struct TimingCell: Sendable, Hashable, Codable {
    public var intersectionID: String
    public var slot: Int
    public var dayType: DayType
    public var bin: Int

    public init(intersectionID: String, slot: Int, dayType: DayType, bin: Int) {
        self.intersectionID = intersectionID
        self.slot = slot
        self.dayType = dayType
        self.bin = bin
    }
}

/// The estimate of the next start of green (docs/timing-estimation.md, 「推定のしかた」), and the
/// check of the plans against a change from Red to Green received live (「実測との照合」).
///
/// The estimate is never a signal state: it only says roughly when green should start next, and
/// nothing when any condition is not met.
public enum TimingEstimator {
    /// Plans give no estimate once more than this many milliseconds have passed since 00:00 UTC of
    /// the day they were built (`TimingPlans.generated`). The server publishes only cells with data
    /// from the last 21 days, so no estimate rests on data much older than 28 days.
    public static let maximumPlanAge = 7 * JapanCalendar.millisecondsPerDay
    /// Added to twice the spread to make the margin `u` (milliseconds).
    public static let fixedMargin = 2000
    /// The shown range is widened to multiples of this many seconds.
    public static let roundingSeconds = 5
    /// A live start of green further than this from the nearest predicted one (milliseconds) stops
    /// the cell for the rest of the JST day.
    public static let mismatchTolerance = 5000
    /// Cycles the server publishes (30–300 s), in milliseconds.
    public static let cycleRange = 30_000...300_000
    /// The largest spread the server publishes, in milliseconds.
    public static let maximumSpread = 3000

    /// Why there is no estimate.
    public enum Unavailability: Sendable, Hashable {
        /// Today is a holiday, December 29 to January 3, or outside the holiday table.
        case excludedDay
        /// No plan for this slot, day type and time bin.
        case noPlan
        /// The plans have no valid `generated` day, or were built more than 7 days ago (or, by the
        /// device's clock, on a later day than today).
        case stale
        /// A live change did not match the plan today.
        case stopped
        /// The next start of green falls into another time bin, whose cycle may differ.
        case crossesBin
    }

    public enum Outcome: Sendable, Hashable {
        case estimate(TimingEstimate)
        case unavailable(Unavailability)

        /// The estimate, or `nil` when there is none.
        public var estimated: TimingEstimate? {
            if case .estimate(let value) = self { return value }
            return nil
        }
    }

    /// The estimate for `slot` of `intersection` at `now`, or `nil` (see `outcome`).
    /// - Parameter generated: `generated` of the `TimingPlans` that `intersection` comes from.
    public static func estimate(
        for intersection: TimingPlans.Intersection,
        generated: String?,
        slot: Int,
        at now: Date,
        stopped: StoppedTimingCells = StoppedTimingCells()
    ) -> TimingEstimate? {
        outcome(for: intersection, generated: generated, slot: slot, at: now, stopped: stopped).estimated
    }

    /// Steps 1–8 of 「推定のしかた」.
    /// - Parameter generated: `generated` of the `TimingPlans` that `intersection` comes from.
    public static func outcome(
        for intersection: TimingPlans.Intersection,
        generated: String?,
        slot: Int,
        at now: Date,
        stopped: StoppedTimingCells = StoppedTimingCells()
    ) -> Outcome {
        let nowMilliseconds = JapanCalendar.milliseconds(now)
        let today = JapanCalendar.day(atMilliseconds: nowMilliseconds)
        // 1. Days without estimates.
        guard !JapanCalendar.isExcluded(today) else { return .unavailable(.excludedDay) }
        // 2. The cell of now.
        let dayType = JapanCalendar.dayType(of: today)
        let bin = JapanCalendar.bin(atMilliseconds: nowMilliseconds)
        guard let plan = intersection.plan(slot: slot, dayType: dayType, bin: bin) else { return .unavailable(.noPlan) }
        // 3. Old plans, or plans of unknown age.
        guard isCurrent(generated: generated, at: now) else { return .unavailable(.stale) }
        // 4. Stopped today by the live check.
        let cell = TimingCell(intersectionID: intersection.id, slot: slot, dayType: dayType, bin: bin)
        guard !stopped.contains(cell, on: today) else { return .unavailable(.stopped) }
        // 5. Time to the next start of green.
        let reference = referenceMilliseconds(plan.reference, on: today)
        let elapsed = JapanCalendar.floorMod(nowMilliseconds - reference - plan.phase, plan.cycle)
        var untilNext = plan.cycle - elapsed
        // 6. Too close to call (green may already have started): take the following cycle.
        let margin = 2 * plan.spread + fixedMargin
        if untilNext <= margin { untilNext += plan.cycle }
        // 7. Only within the same time bin.
        let start = nowMilliseconds + untilNext
        guard JapanCalendar.day(atMilliseconds: start) == today, JapanCalendar.bin(atMilliseconds: start) == bin else {
            return .unavailable(.crossesBin)
        }
        // 8. The range, widened to multiples of 5 s.
        let step = roundingSeconds * 1000
        let lower = max(0, JapanCalendar.floorDiv(untilNext - margin, step)) * roundingSeconds
        let upper = JapanCalendar.floorDiv(untilNext + margin + step - 1, step) * roundingSeconds
        return .estimate(TimingEstimate(
            lowerSeconds: lower,
            upperSeconds: upper,
            nextGreenStart: JapanCalendar.date(milliseconds: start)
        ))
    }

    /// Whether plans built on the UTC day `generated` (`TimingPlans.generated`) may still give
    /// estimates at `now`: `generated` is a valid `YYYY-MM-DD`, and `now` is at or after 00:00 UTC of
    /// that day and at most `maximumPlanAge` (7 days) after it. A `now` before that day means the
    /// device's clock is wrong, and every estimate depends on it.
    public static func isCurrent(generated: String?, at now: Date) -> Bool {
        guard let start = TimingPlans.startOfUTCDay(generated) else { return false }
        let age = JapanCalendar.milliseconds(now) - JapanCalendar.milliseconds(start)
        return (0...maximumPlanAge).contains(age)
    }

    /// Milliseconds between `greenStart` and the nearest start of green that `plan` predicts
    /// (0 … cycle / 2).
    public static func distanceToNearestGreenStart(_ greenStart: Date, plan: TimingPlans.Plan) -> Int {
        let milliseconds = JapanCalendar.milliseconds(greenStart)
        let day = JapanCalendar.day(atMilliseconds: milliseconds)
        let offset = JapanCalendar.floorMod(milliseconds - referenceMilliseconds(plan.reference, on: day) - plan.phase, plan.cycle)
        return min(offset, plan.cycle - offset)
    }

    /// 「実測との照合」: compares a live change from Red to Green of `slot` at `greenStart` with the
    /// plan of its cell, and stops that cell for the rest of the JST day when they differ by more
    /// than 5 seconds.
    /// - Returns: the cell that was stopped, or `nil` when there is no plan for it or it matched.
    @discardableResult
    public static func checkLiveGreenStart(
        at greenStart: Date,
        intersectionID: String,
        slot: Int,
        plans: TimingPlans,
        stopped: inout StoppedTimingCells
    ) -> TimingCell? {
        guard let intersection = plans[intersectionID] else { return nil }
        let milliseconds = JapanCalendar.milliseconds(greenStart)
        let day = JapanCalendar.day(atMilliseconds: milliseconds)
        guard !JapanCalendar.isExcluded(day) else { return nil }
        let dayType = JapanCalendar.dayType(of: day)
        let bin = JapanCalendar.bin(atMilliseconds: milliseconds)
        guard let plan = intersection.plan(slot: slot, dayType: dayType, bin: bin),
              distanceToNearestGreenStart(greenStart, plan: plan) > mismatchTolerance
        else { return nil }
        let cell = TimingCell(intersectionID: intersectionID, slot: slot, dayType: dayType, bin: bin)
        stopped.stop(cell, on: day)
        return cell
    }

    /// Unix milliseconds the phase counts from on `day`.
    static func referenceMilliseconds(_ reference: TimingPlans.Reference, on day: JapanDate) -> Int {
        switch reference {
        case .epoch: 0
        case .midnight: JapanCalendar.startMilliseconds(of: day)
        }
    }
}

/// Cells whose estimate is stopped for the rest of a JST day because a live change from Red to
/// Green did not match them. Kept on the device only.
public struct StoppedTimingCells: Sendable, Hashable, Codable {
    public struct Entry: Sendable, Hashable, Codable {
        public var day: JapanDate
        public var cell: TimingCell

        public init(day: JapanDate, cell: TimingCell) {
            self.day = day
            self.cell = cell
        }
    }

    public private(set) var entries: Set<Entry>

    public init(entries: Set<Entry> = []) {
        self.entries = entries
    }

    public var isEmpty: Bool { entries.isEmpty }

    public func contains(_ cell: TimingCell, on day: JapanDate) -> Bool {
        entries.contains(Entry(day: day, cell: cell))
    }

    public mutating func stop(_ cell: TimingCell, on day: JapanDate) {
        entries.insert(Entry(day: day, cell: cell))
    }

    /// Forgets the entries of days before `day`, which no longer stop anything.
    public mutating func removeEntries(before day: JapanDate) {
        entries = entries.filter { $0.day >= day }
    }
}

/// Finds changes from Red to Green in live signal packets, timed as the server times the starts of
/// green it fits the plans to: when the first packet showing Green arrived, less half the time since
/// the previous signal packet of the intersection. After a pause in reception of more than
/// `PICS.staleInterval` (5 s) the time of a change is unknown, so nothing is found, as in
/// `FieldCollector`.
///
/// Feed it live packets only, never demo or played-back data.
public struct GreenStartDetector: Sendable {
    public struct GreenStart: Sendable, Hashable {
        public var intersectionID: String
        /// From 1.
        public var slot: Int
        public var at: Date

        public init(intersectionID: String, slot: Int, at: Date) {
            self.intersectionID = intersectionID
            self.slot = slot
            self.at = at
        }
    }

    private struct Previous: Sendable {
        var states: [SignalState]
        var at: Date
    }

    public static let maximumGap: TimeInterval = PICS.staleInterval

    private var previous: [String: Previous] = [:]

    public init() {}

    /// Records the signals of one live packet and returns the slots that changed from Red to Green.
    public mutating func update(intersectionID: String, signals: [PedestrianSignal], at timestamp: Date) -> [GreenStart] {
        let states = signals.map(\.state)
        let earlier = previous[intersectionID]
        previous[intersectionID] = Previous(states: states, at: timestamp)
        guard let last = earlier else { return [] }
        let gap = timestamp.timeIntervalSince(last.at)
        guard gap >= 0, gap <= Self.maximumGap else { return [] }
        let start = timestamp.addingTimeInterval(-gap / 2)
        var found: [GreenStart] = []
        for (index, state) in states.enumerated() where index < last.states.count {
            if last.states[index] == .red, state == .green {
                found.append(GreenStart(intersectionID: intersectionID, slot: index + 1, at: start))
            }
        }
        return found
    }

    /// Forgets every intersection, for example when reception stops.
    public mutating func reset() {
        previous.removeAll()
    }
}
