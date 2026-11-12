// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Keeps the last `GET /v1/plans` response on the device, with the time it was fetched, in one file.
/// A cache fetched more than seven days ago is not used (docs/timing-estimation.md, 「表示の規則」).
/// Independently, plans give no estimate once seven days have passed since the day the server built
/// them (`TimingEstimator.isCurrent`), which is the stricter of the two when the clock is right.
public struct TimingPlanCache: Sendable {
    public static let maximumAge: TimeInterval = 7 * 24 * 60 * 60
    /// A cache that seems to come from up to this far in the future (the clock was set back a
    /// little) is still used; anything further is not.
    public static let clockTolerance: TimeInterval = 60

    public struct Entry: Sendable, Hashable {
        public var plans: TimingPlans
        public var fetchedAt: Date

        public init(plans: TimingPlans, fetchedAt: Date) {
            self.plans = plans
            self.fetchedAt = fetchedAt
        }
    }

    private struct Stored: Codable {
        /// Unix milliseconds.
        var fetchedAt: Int
        /// The response body as received.
        var body: Data
    }

    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// The cached plans, or `nil` when there are none, they cannot be read, or they were fetched
    /// more than seven days before `now` (or after it).
    public func load(now: Date) -> Entry? {
        guard let data = try? Data(contentsOf: fileURL),
              let stored = try? JSONDecoder().decode(Stored.self, from: data),
              let plans = try? JSONDecoder().decode(TimingPlans.self, from: stored.body)
        else { return nil }
        let fetchedAt = JapanCalendar.date(milliseconds: stored.fetchedAt)
        let age = now.timeIntervalSince(fetchedAt)
        guard age >= -Self.clockTolerance, age <= Self.maximumAge else { return nil }
        return Entry(plans: plans, fetchedAt: fetchedAt)
    }

    /// Replaces the cache with `body`, a response of `GET /v1/plans` fetched at `fetchedAt`.
    public func save(_ body: Data, fetchedAt: Date) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        FileReportStore.excludeFromBackup(directory)
        let stored = Stored(fetchedAt: JapanCalendar.milliseconds(fetchedAt), body: body)
        try JSONEncoder().encode(stored).write(to: fileURL, options: [.atomic])
    }

    /// Deletes the cache, if there is one.
    public func remove() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
