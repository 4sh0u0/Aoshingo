// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
@testable import FieldDataKit
import PICSKit

/// Plans and times shared by the timing tests. Expected values were worked out independently from
/// docs/timing-estimation.md.
enum TimingFixtures {
    /// Type 0 of intersection 1234ABCD named 渋谷, and its Type 1 at 35.681236, 139.767125.
    static let nameRaw = "CE010000000000001234ABCDE6B88BE8B0B70000000000000000"
    static let positionRaw = "CE010000010000001234ABCD022073D40854AD55"

    /// Two usable intersections. Of 1234ABCD's plans only slots 1 and 2 are valid; the others have an
    /// unknown reference, a cycle under 30 s, a phase outside the cycle and an unknown day type. The
    /// second entry has an invalid ID.
    static let plansJSON = """
    {"intersections":[
    {"id":"1234ABCD","name":"\(nameRaw)","position":"\(positionRaw)","plans":[
    {"slot":1,"dayType":0,"bin":14,"cycle":120000,"reference":"epoch","phase":37400,"spread":1800,"green":24000,"blink":6000,"days":4,"reports":5,"lastDay":"2026-11-10"},
    {"slot":2,"dayType":0,"bin":14,"cycle":97000,"reference":"midnight","phase":37400,"spread":1800,"green":null,"blink":null,"days":3,"reports":2,"lastDay":"2026-11-10"},
    {"slot":3,"dayType":0,"bin":14,"cycle":120000,"reference":"sunrise","phase":0,"spread":0,"green":null,"blink":null,"days":3,"reports":2,"lastDay":"2026-11-10"},
    {"slot":4,"dayType":0,"bin":14,"cycle":10000,"reference":"epoch","phase":0,"spread":0,"green":null,"blink":null,"days":3,"reports":2,"lastDay":"2026-11-10"},
    {"slot":5,"dayType":0,"bin":14,"cycle":120000,"reference":"epoch","phase":120000,"spread":0,"green":null,"blink":null,"days":3,"reports":2,"lastDay":"2026-11-10"},
    {"slot":6,"dayType":3,"bin":14,"cycle":120000,"reference":"epoch","phase":0,"spread":0,"green":null,"blink":null,"days":3,"reports":2,"lastDay":"2026-11-10"}
    ]},
    {"id":"bad","name":null,"position":null,"plans":[]},
    {"id":"00000002","name":null,"position":null,"plans":[
    {"slot":1,"dayType":1,"bin":0,"cycle":60000,"reference":"epoch","phase":0,"spread":0,"green":null,"blink":null,"days":3,"reports":2,"lastDay":"2026-11-07"}
    ]}
    ]}
    """

    /// Thursday 2026-11-12 07:10:00 JST (time bin 14).
    static let thursday = Date(timeIntervalSince1970: 1_794_435_000)

    static func plan(
        slot: Int = 1,
        dayType: DayType = .weekday,
        bin: Int = 14,
        cycle: Int = 120_000,
        reference: TimingPlans.Reference = .epoch,
        phase: Int = 37_400,
        spread: Int = 1800,
        lastDay: String = "2026-11-10"
    ) -> TimingPlans.Plan {
        TimingPlans.Plan(
            slot: slot, dayType: dayType, bin: bin, cycle: cycle, reference: reference,
            phase: phase, spread: spread, days: 4, reports: 5, lastDay: lastDay
        )
    }

    static func intersection(_ plans: TimingPlans.Plan...) -> TimingPlans.Intersection {
        TimingPlans.Intersection(id: "1234ABCD", plans: plans)
    }
}

private func date(_ seconds: Double) -> Date { Date(timeIntervalSince1970: seconds) }

private func day(_ text: String) throws -> JapanDate { try #require(JapanDate(text)) }

@Suite("Japan calendar")
struct JapanCalendarTests {
    @Test("dates parse strictly and count days from 1970-01-01")
    func dates() throws {
        let november12 = try day("2026-11-12")
        #expect(november12.year == 2026 && november12.month == 11 && november12.day == 12)
        #expect(november12.dayNumber == 20_769)
        #expect(JapanDate(dayNumber: 20_769) == november12)
        #expect(JapanDate(dayNumber: 0).description == "1970-01-01")
        #expect(november12.description == "2026-11-12")
        #expect(try november12.adding(days: 20) == day("2026-12-02"))
        #expect(try day("2028-02-29").adding(days: 1) == day("2028-03-01"))
        #expect(JapanDate("2026-02-29") == nil)
        #expect(JapanDate("2026-13-01") == nil)
        #expect(JapanDate("2026-1-01") == nil)
        #expect(JapanDate("2026-11-12T00") == nil)
        #expect(JapanDate("abcd-ef-gh") == nil)
        #expect(try day("2026-11-10") < november12)

        let encoded = try JSONEncoder().encode(november12)
        #expect(String(decoding: encoded, as: UTF8.self) == "\"2026-11-12\"")
        #expect(try JSONDecoder().decode(JapanDate.self, from: encoded) == november12)
    }

    @Test("the day and the time bin change at midnight JST, whatever the device's time zone")
    func midnight() throws {
        // 2026-11-12 00:00 JST is 2026-11-11 15:00 UTC.
        let midnight = date(1_794_409_200)
        #expect(try JapanCalendar.day(of: midnight) == day("2026-11-12"))
        #expect(JapanCalendar.bin(of: midnight) == 0)
        #expect(try JapanCalendar.start(of: day("2026-11-12")) == midnight)
        let justBefore = date(1_794_409_199.999)
        #expect(try JapanCalendar.day(of: justBefore) == day("2026-11-11"))
        #expect(JapanCalendar.bin(of: justBefore) == 47)
        #expect(JapanCalendar.bin(of: TimingFixtures.thursday) == 14)        // 07:10
        #expect(JapanCalendar.bin(of: date(1_794_436_199)) == 14)            // 07:29:59
        #expect(JapanCalendar.bin(of: date(1_794_436_200)) == 15)            // 07:30:00
        #expect(JapanCalendar.timeZone.secondsFromGMT() == 9 * 60 * 60)
    }

    @Test("day types: Monday to Friday 0, Saturday 1, Sunday 2")
    func dayTypes() throws {
        #expect(try JapanCalendar.dayType(of: day("2026-11-09")) == .weekday)   // Monday
        #expect(try JapanCalendar.dayType(of: day("2026-11-12")) == .weekday)   // Thursday
        #expect(try JapanCalendar.dayType(of: day("2026-11-13")) == .weekday)   // Friday
        #expect(try JapanCalendar.dayType(of: day("2026-11-14")) == .saturday)
        #expect(try JapanCalendar.dayType(of: day("2026-11-15")) == .sunday)
        #expect(DayType.weekday.rawValue == 0 && DayType.saturday.rawValue == 1 && DayType.sunday.rawValue == 2)
    }

    @Test("holidays, December 29 to January 3, and days outside 2026–2027 are excluded")
    func excludedDays() throws {
        #expect(JapanCalendar.holidays.count == 35)
        let excluded = [
            "2026-01-01", "2026-05-06", "2026-09-22", "2026-11-23", "2027-03-22", "2027-11-23", // holidays
            "2026-12-29", "2026-12-31", "2027-01-02", "2027-01-03", "2027-12-29",               // year end
            "2025-11-12", "2025-12-26", "2028-01-05", "2030-06-03",                             // outside the table
        ]
        for text in excluded {
            #expect(try JapanCalendar.isExcluded(day(text)), "\(text)")
        }
        let included = ["2026-01-05", "2026-11-12", "2026-11-14", "2026-11-24", "2026-12-28", "2027-01-04", "2027-12-28"]
        for text in included {
            #expect(try !JapanCalendar.isExcluded(day(text)), "\(text)")
        }
    }
}

@Suite("Timing plans")
struct TimingPlansTests {
    @Test("decoding keeps valid plans and intersections and drops the rest")
    func lenientDecoding() throws {
        let plans = try JSONDecoder().decode(TimingPlans.self, from: Data(TimingFixtures.plansJSON.utf8))
        #expect(plans.intersections.map(\.id) == ["1234ABCD", "00000002"])
        let first = try #require(plans["1234ABCD"])
        #expect(first.slots == [1, 2])
        #expect(first.plans.map(\.reference) == [.epoch, .midnight])
        #expect(first.plans[0].green == 24_000 && first.plans[1].green == nil)
        #expect(first.plan(slot: 1, dayType: .weekday, bin: 14)?.cycle == 120_000)
        #expect(first.plan(slot: 1, dayType: .weekday, bin: 15) == nil)
        #expect(plans["00000002"]?.plans.first?.dayType == .saturday)
        #expect(plans["FFFFFFFF"] == nil)
    }

    @Test("the name and position come from the raw Type 0 and Type 1 messages")
    func places() throws {
        let plans = try JSONDecoder().decode(TimingPlans.self, from: Data(TimingFixtures.plansJSON.utf8))
        let first = try #require(plans["1234ABCD"])
        #expect(first.decodedName == "渋谷")
        let coordinate = try #require(first.coordinate)
        #expect(abs(coordinate.latitude - 35.681236) < 1e-9)
        #expect(abs(coordinate.longitude - 139.767125) < 1e-9)
        let second = try #require(plans["00000002"])
        #expect(second.decodedName == nil && second.coordinate == nil)
        // A message of another intersection, or of the wrong type, is not used.
        let mismatched = TimingPlans.Intersection(id: "00000002", name: TimingFixtures.nameRaw, position: TimingFixtures.nameRaw, plans: [])
        #expect(mismatched.decodedName == nil && mismatched.coordinate == nil)
    }

    @Test("plans outside the published ranges are not valid")
    func validity() {
        #expect(TimingFixtures.plan().isValid)
        #expect(!TimingFixtures.plan(slot: 7).isValid)
        #expect(!TimingFixtures.plan(bin: 48).isValid)
        #expect(!TimingFixtures.plan(cycle: 29_000).isValid)
        #expect(!TimingFixtures.plan(cycle: 301_000).isValid)
        #expect(!TimingFixtures.plan(phase: -1).isValid)
        #expect(!TimingFixtures.plan(phase: 120_000).isValid)
        #expect(!TimingFixtures.plan(spread: 3001).isValid)
        #expect(!TimingFixtures.plan(lastDay: "2026-11-31").isValid)
    }

    @Test("the cache keeps the body and its fetch time, and refuses caches older than seven days")
    func cache() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aoshingo-plans-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = TimingPlanCache(fileURL: directory.appendingPathComponent("plans.json"))
        let fetchedAt = date(1_794_290_000)
        #expect(cache.load(now: fetchedAt) == nil)

        try cache.save(Data(TimingFixtures.plansJSON.utf8), fetchedAt: fetchedAt)
        let entry = try #require(cache.load(now: fetchedAt.addingTimeInterval(3600)))
        #expect(entry.fetchedAt == fetchedAt)
        #expect(entry.plans.intersections.map(\.id) == ["1234ABCD", "00000002"])
        #expect(cache.load(now: fetchedAt.addingTimeInterval(TimingPlanCache.maximumAge)) != nil)
        #expect(cache.load(now: fetchedAt.addingTimeInterval(TimingPlanCache.maximumAge + 1)) == nil)
        #expect(cache.load(now: fetchedAt.addingTimeInterval(-3600)) == nil) // fetched "in the future"

        cache.remove()
        #expect(cache.load(now: fetchedAt) == nil)

        try Data("garbage".utf8).write(to: cache.fileURL)
        #expect(cache.load(now: fetchedAt) == nil)
    }
}

@Suite("Timing estimator")
struct TimingEstimatorTests {
    private let now = TimingFixtures.thursday

    @Test("epoch reference: next green 37.4 s away, margin 5.6 s → 30–45 s")
    func epochReference() throws {
        let intersection = TimingFixtures.intersection(TimingFixtures.plan())
        let estimate = try #require(TimingEstimator.estimate(for: intersection, slot: 1, at: now))
        #expect(estimate.lowerSeconds == 30)
        #expect(estimate.upperSeconds == 45)
        #expect(JapanCalendar.milliseconds(estimate.nextGreenStart) == 1_794_435_037_400)
    }

    @Test("the two references give different starts for a cycle that does not divide the day")
    func references() throws {
        let epoch = TimingFixtures.intersection(TimingFixtures.plan(cycle: 97_000, reference: .epoch))
        let fromEpoch = try #require(TimingEstimator.estimate(for: epoch, slot: 1, at: now))
        #expect(fromEpoch.lowerSeconds == 40 && fromEpoch.upperSeconds == 55)
        #expect(JapanCalendar.milliseconds(fromEpoch.nextGreenStart) == 1_794_435_047_400)

        let midnight = TimingFixtures.intersection(TimingFixtures.plan(cycle: 97_000, reference: .midnight))
        let fromMidnight = try #require(TimingEstimator.estimate(for: midnight, slot: 1, at: now))
        #expect(fromMidnight.lowerSeconds == 30 && fromMidnight.upperSeconds == 45)
        #expect(JapanCalendar.milliseconds(fromMidnight.nextGreenStart) == 1_794_435_039_400)

        let noSpread = TimingFixtures.intersection(TimingFixtures.plan(cycle: 97_000, spread: 0))
        let narrow = try #require(TimingEstimator.estimate(for: noSpread, slot: 1, at: now))
        #expect(narrow.lowerSeconds == 45 && narrow.upperSeconds == 50) // 47.4 s ± 2 s
    }

    @Test("a start of green within the margin moves to the following cycle")
    func marginRollOver() throws {
        let intersection = TimingFixtures.intersection(TimingFixtures.plan())
        // The start predicted at 07:10:37.4 is 3 s away: take the one a cycle later (123 s).
        let close = try #require(TimingEstimator.estimate(for: intersection, slot: 1, at: date(1_794_435_034.4)))
        #expect(close.lowerSeconds == 115 && close.upperSeconds == 130)
        #expect(JapanCalendar.milliseconds(close.nextGreenStart) == 1_794_435_157_400)
        // Exactly the margin (5.6 s) away also moves on.
        let edge = try #require(TimingEstimator.estimate(for: intersection, slot: 1, at: date(1_794_435_031.8)))
        #expect(edge.lowerSeconds == 120 && edge.upperSeconds == 135)
        // One millisecond more does not.
        let outside = try #require(TimingEstimator.estimate(for: intersection, slot: 1, at: date(1_794_435_031.799)))
        #expect(outside.lowerSeconds == 0 && outside.upperSeconds == 15)
        #expect(JapanCalendar.milliseconds(outside.nextGreenStart) == 1_794_435_037_400)
    }

    @Test("no estimate when the next start of green is in the next time bin")
    func binBoundary() throws {
        let intersection = TimingFixtures.intersection(TimingFixtures.plan())
        // 07:29:00: the next start (97.4 s later) is after 07:30.
        #expect(TimingEstimator.outcome(for: intersection, slot: 1, at: date(1_794_436_140)) == .unavailable(.crossesBin))
        // 07:27:00: the next start is at 07:28:37.4, in the same bin.
        let estimate = try #require(TimingEstimator.estimate(for: intersection, slot: 1, at: date(1_794_436_020)))
        #expect(estimate.lowerSeconds == 90 && estimate.upperSeconds == 105)
    }

    @Test("no estimate from a plan whose last day is 28 days old or more")
    func stale() {
        let fresh = TimingFixtures.intersection(TimingFixtures.plan(lastDay: "2026-10-16")) // 27 days before
        #expect(TimingEstimator.estimate(for: fresh, slot: 1, at: now) != nil)
        let stale = TimingFixtures.intersection(TimingFixtures.plan(lastDay: "2026-10-15")) // 28 days before
        #expect(TimingEstimator.outcome(for: stale, slot: 1, at: now) == .unavailable(.stale))
    }

    @Test("no estimate on excluded days, or without a plan for the slot, day type and bin")
    func excludedAndMissing() {
        let intersection = TimingFixtures.intersection(TimingFixtures.plan(lastDay: "2026-11-20"))
        // Monday 2026-11-23 07:10 JST is a holiday.
        #expect(TimingEstimator.outcome(for: intersection, slot: 1, at: date(1_795_385_400)) == .unavailable(.excludedDay))
        // Monday 2026-11-30 07:10 JST is a weekday.
        #expect(TimingEstimator.estimate(for: intersection, slot: 1, at: date(1_795_990_200)) != nil)
        // Saturday 2026-11-14 07:10 JST has no weekday plan; slot 2 has none at all.
        #expect(TimingEstimator.outcome(for: intersection, slot: 1, at: date(1_794_607_800)) == .unavailable(.noPlan))
        #expect(TimingEstimator.outcome(for: intersection, slot: 2, at: now) == .unavailable(.noPlan))
        // 2025 is outside the holiday table.
        let old = TimingFixtures.intersection(TimingFixtures.plan(lastDay: "2025-11-12"))
        #expect(TimingEstimator.outcome(for: old, slot: 1, at: date(1_762_899_000)) == .unavailable(.excludedDay))
    }

    @Test("a live start of green more than 5 s from the plan stops the cell for that JST day only")
    func liveMismatch() throws {
        let plans = TimingPlans(intersections: [TimingFixtures.intersection(TimingFixtures.plan())])
        let intersection = try #require(plans["1234ABCD"])
        let plan = intersection.plans[0]
        // The plan predicts a start of green at 07:10:37.4 JST.
        #expect(TimingEstimator.distanceToNearestGreenStart(date(1_794_435_042.3), plan: plan) == 4900)
        #expect(TimingEstimator.distanceToNearestGreenStart(date(1_794_435_032.3), plan: plan) == 5100)
        #expect(TimingEstimator.distanceToNearestGreenStart(date(1_794_435_097.4), plan: plan) == 60_000)
        #expect(TimingEstimator.distanceToNearestGreenStart(date(1_794_435_150.4), plan: plan) == 7000)

        var stopped = StoppedTimingCells()
        let matched = TimingEstimator.checkLiveGreenStart(at: date(1_794_435_042.3), intersectionID: "1234ABCD", slot: 1, plans: plans, stopped: &stopped)
        #expect(matched == nil)
        #expect(stopped.isEmpty)
        // Another intersection or slot without plans changes nothing.
        #expect(TimingEstimator.checkLiveGreenStart(at: date(1_794_435_042.5), intersectionID: "00000009", slot: 1, plans: plans, stopped: &stopped) == nil)
        #expect(TimingEstimator.checkLiveGreenStart(at: date(1_794_435_042.5), intersectionID: "1234ABCD", slot: 2, plans: plans, stopped: &stopped) == nil)
        #expect(stopped.isEmpty)

        let cell = try #require(TimingEstimator.checkLiveGreenStart(
            at: date(1_794_435_042.5), intersectionID: "1234ABCD", slot: 1, plans: plans, stopped: &stopped
        ))
        #expect(cell == TimingCell(intersectionID: "1234ABCD", slot: 1, dayType: .weekday, bin: 14))
        #expect(try stopped.contains(cell, on: day("2026-11-12")))
        #expect(TimingEstimator.outcome(for: intersection, slot: 1, at: now, stopped: stopped) == .unavailable(.stopped))
        // The next day (Friday 07:10 JST) the plan is used again.
        #expect(TimingEstimator.estimate(for: intersection, slot: 1, at: date(1_794_521_400), stopped: stopped) != nil)

        try stopped.removeEntries(before: day("2026-11-12"))
        #expect(!stopped.isEmpty)
        let encoded = try JSONEncoder().encode(stopped)
        #expect(try JSONDecoder().decode(StoppedTimingCells.self, from: encoded) == stopped)
        try stopped.removeEntries(before: day("2026-11-13"))
        #expect(stopped.isEmpty)
    }
}

@Suite("Green start detector")
struct GreenStartDetectorTests {
    private let red = PedestrianSignal(remaining: nil, state: .red)
    private let green = PedestrianSignal(remaining: nil, state: .green)
    private let base = Date(timeIntervalSince1970: 1_794_435_000)

    @Test("a change from Red to Green is timed half-way between the two packets")
    func detects() {
        var detector = GreenStartDetector()
        #expect(detector.update(intersectionID: "1234ABCD", signals: [red, red], at: base).isEmpty)
        let found = detector.update(intersectionID: "1234ABCD", signals: [green, red], at: base.addingTimeInterval(0.4))
        #expect(found.map(\.slot) == [1])
        #expect(found.map(\.intersectionID) == ["1234ABCD"])
        #expect(found.map { JapanCalendar.milliseconds($0.at) } == [1_794_435_000_200])
        // Green to Red, and Green that stays Green, are not starts of green.
        #expect(detector.update(intersectionID: "1234ABCD", signals: [red, red], at: base.addingTimeInterval(1)).isEmpty)
        #expect(detector.update(intersectionID: "1234ABCD", signals: [red, green], at: base.addingTimeInterval(2)).map(\.slot) == [2])
        #expect(detector.update(intersectionID: "1234ABCD", signals: [red, green], at: base.addingTimeInterval(3)).isEmpty)
    }

    @Test("nothing is found after a pause of more than 5 s, for another intersection, or after reset")
    func pauses() {
        var detector = GreenStartDetector()
        _ = detector.update(intersectionID: "1234ABCD", signals: [red], at: base)
        #expect(detector.update(intersectionID: "1234ABCD", signals: [green], at: base.addingTimeInterval(5.1)).isEmpty)
        _ = detector.update(intersectionID: "1234ABCD", signals: [red], at: base.addingTimeInterval(6))
        #expect(detector.update(intersectionID: "00000002", signals: [green], at: base.addingTimeInterval(6.5)).isEmpty)
        detector.reset()
        #expect(detector.update(intersectionID: "1234ABCD", signals: [green], at: base.addingTimeInterval(7)).isEmpty)
        _ = detector.update(intersectionID: "1234ABCD", signals: [red], at: base.addingTimeInterval(8))
        #expect(detector.update(intersectionID: "1234ABCD", signals: [green], at: base.addingTimeInterval(13)).map(\.slot) == [1])
    }
}
