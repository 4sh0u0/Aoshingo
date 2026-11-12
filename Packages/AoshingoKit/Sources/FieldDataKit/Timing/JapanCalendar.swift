// SPDX-License-Identifier: Apache-2.0

import Foundation

/// A calendar date in Japan Standard Time (UTC+9, no daylight saving time).
///
/// Encoded as `YYYY-MM-DD`, the form of `lastDay` in the plans.
public struct JapanDate: Sendable, Hashable, Comparable, Codable, CustomStringConvertible {
    public let year: Int
    /// 1…12.
    public let month: Int
    /// 1…31.
    public let day: Int

    /// `nil` for a day that does not exist (for example February 30).
    public init?(year: Int, month: Int, day: Int) {
        guard (1...12).contains(month), (1...31).contains(day) else { return nil }
        let candidate = JapanDate(dayNumber: JapanDate.dayNumber(year: year, month: month, day: day))
        guard candidate.year == year, candidate.month == month, candidate.day == day else { return nil }
        self = candidate
    }

    /// The day `dayNumber` days after 1970-01-01.
    public init(dayNumber: Int) {
        // Howard Hinnant's civil_from_days.
        let z = dayNumber + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let dayOfEra = z - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let shiftedMonth = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * shiftedMonth + 2) / 5 + 1
        let month = shiftedMonth < 10 ? shiftedMonth + 3 : shiftedMonth - 9
        self.year = yearOfEra + era * 400 + (month <= 2 ? 1 : 0)
        self.month = month
        self.day = day
    }

    /// Parses `YYYY-MM-DD`; `nil` for anything else, including days that do not exist.
    public init?(_ text: String) {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        let digits = UInt8(ascii: "0")...UInt8(ascii: "9")
        guard parts.count == 3, parts[0].utf8.count == 4, parts[1].utf8.count == 2, parts[2].utf8.count == 2,
              parts.allSatisfy({ part in part.utf8.allSatisfy { byte in digits.contains(byte) } }),
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2])
        else { return nil }
        self.init(year: year, month: month, day: day)
    }

    /// Days since 1970-01-01.
    public var dayNumber: Int {
        JapanDate.dayNumber(year: year, month: month, day: day)
    }

    /// Monday 0 … Sunday 6.
    public var weekdayFromMonday: Int {
        // 1970-01-01 was a Thursday (3).
        JapanCalendar.floorMod(dayNumber + 3, 7)
    }

    /// The day `days` days later (earlier when negative).
    public func adding(days: Int) -> JapanDate {
        JapanDate(dayNumber: dayNumber + days)
    }

    /// `YYYY-MM-DD`.
    public var description: String {
        "\(Self.padded(year, to: 4))-\(Self.padded(month, to: 2))-\(Self.padded(day, to: 2))"
    }

    public static func < (lhs: JapanDate, rhs: JapanDate) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let date = JapanDate(text) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "not a YYYY-MM-DD date")
        }
        self = date
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }

    /// Howard Hinnant's days_from_civil.
    private static func dayNumber(year: Int, month: Int, day: Int) -> Int {
        let shiftedYear = month <= 2 ? year - 1 : year
        let era = (shiftedYear >= 0 ? shiftedYear : shiftedYear - 399) / 400
        let yearOfEra = shiftedYear - era * 400
        let dayOfYear = (153 * (month > 2 ? month - 3 : month + 9) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    private static func padded(_ value: Int, to width: Int) -> String {
        let digits = String(abs(value))
        let padding = String(repeating: "0", count: max(0, width - digits.count))
        return (value < 0 ? "-" : "") + padding + digits
    }
}

/// The kind of day a plan applies to.
public enum DayType: Int, Sendable, Hashable, Codable, CaseIterable {
    /// Monday to Friday.
    case weekday = 0
    case saturday = 1
    case sunday = 2
}

/// The calendar of the timing plans (docs/timing-estimation.md, 「暦：日の種類と時間帯」): dates and
/// times in JST, the day type, the 30-minute time bin, and the days without estimates.
///
/// Everything is integer arithmetic on Unix milliseconds with a fixed +9 h offset, so the result does
/// not depend on the device's time zone or calendar settings.
public enum JapanCalendar {
    /// Japan Standard Time, UTC+9 all year.
    public static let timeZone = TimeZone(secondsFromGMT: 9 * 60 * 60)!
    public static let binsPerDay = 48
    public static let millisecondsPerDay = 86_400_000
    /// The length of one time bin (30 minutes) in milliseconds.
    public static let binMilliseconds = 1_800_000
    /// The UTC offset of JST in milliseconds.
    public static let offsetMilliseconds = 32_400_000
    /// The years the holiday table covers. Every day outside them is excluded, so the table must be
    /// extended (in the app and on the server) when the Cabinet Office publishes the next year,
    /// around February.
    public static let coveredYears = 2026...2027

    /// 国民の祝日・休日 from the Cabinet Office table (syukujitsu.csv) for `coveredYears`.
    public static let holidays: Set<JapanDate> = Set(holidayList.compactMap { JapanDate($0) })

    private static let holidayList: [String] = [
        // 2026
        "2026-01-01", "2026-01-12", "2026-02-11", "2026-02-23", "2026-03-20", "2026-04-29",
        "2026-05-03", "2026-05-04", "2026-05-05", "2026-05-06", "2026-07-20", "2026-08-11",
        "2026-09-21", "2026-09-22", "2026-09-23", "2026-10-12", "2026-11-03", "2026-11-23",
        // 2027
        "2027-01-01", "2027-01-11", "2027-02-11", "2027-02-23", "2027-03-21", "2027-03-22",
        "2027-04-29", "2027-05-03", "2027-05-04", "2027-05-05", "2027-07-19", "2027-08-11",
        "2027-09-20", "2027-09-23", "2027-10-11", "2027-11-03", "2027-11-23",
    ]

    /// Unix milliseconds of `date`, rounded to the nearest millisecond.
    public static func milliseconds(_ date: Date) -> Int {
        Int((date.timeIntervalSince1970 * 1000).rounded())
    }

    /// The `Date` of Unix milliseconds.
    public static func date(milliseconds: Int) -> Date {
        Date(timeIntervalSince1970: Double(milliseconds) / 1000)
    }

    /// The JST date at `date`.
    public static func day(of date: Date) -> JapanDate {
        day(atMilliseconds: milliseconds(date))
    }

    /// The JST date at Unix milliseconds `milliseconds`.
    public static func day(atMilliseconds milliseconds: Int) -> JapanDate {
        JapanDate(dayNumber: floorDiv(milliseconds + offsetMilliseconds, millisecondsPerDay))
    }

    /// Unix milliseconds of 00:00 JST on `day`.
    public static func startMilliseconds(of day: JapanDate) -> Int {
        day.dayNumber * millisecondsPerDay - offsetMilliseconds
    }

    /// 00:00 JST on `day`.
    public static func start(of day: JapanDate) -> Date {
        date(milliseconds: startMilliseconds(of: day))
    }

    /// The time bin (0…47): minutes since 00:00 JST divided by 30, rounded down.
    public static func bin(of date: Date) -> Int {
        bin(atMilliseconds: milliseconds(date))
    }

    public static func bin(atMilliseconds milliseconds: Int) -> Int {
        floorMod(milliseconds + offsetMilliseconds, millisecondsPerDay) / binMilliseconds
    }

    /// 0 Monday–Friday, 1 Saturday, 2 Sunday. Holidays keep their weekday's type; they are excluded
    /// separately (`isExcluded`).
    public static func dayType(of day: JapanDate) -> DayType {
        switch day.weekdayFromMonday {
        case 5: .saturday
        case 6: .sunday
        default: .weekday
        }
    }

    /// Days without estimates and whose data the fit does not use: national holidays and other
    /// holidays, December 29 to January 3, and every day outside the years of the holiday table.
    public static func isExcluded(_ day: JapanDate) -> Bool {
        guard coveredYears.contains(day.year) else { return true }
        if day.month == 12 && day.day >= 29 { return true }
        if day.month == 1 && day.day <= 3 { return true }
        return holidays.contains(day)
    }

    /// Division rounded towards negative infinity, for a positive divisor.
    static func floorDiv(_ value: Int, _ divisor: Int) -> Int {
        (value - floorMod(value, divisor)) / divisor
    }

    /// The remainder in `0..<divisor`, for a positive divisor.
    static func floorMod(_ value: Int, _ divisor: Int) -> Int {
        let remainder = value % divisor
        return remainder < 0 ? remainder + divisor : remainder
    }
}
