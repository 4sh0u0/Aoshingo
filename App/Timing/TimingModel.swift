// SPDX-License-Identifier: Apache-2.0

import CoreLocation
import FieldDataKit
import Foundation
import Observation
import PICSKit
import UIKit

/// The signal timing plans and what the 「推定」 screen shows (docs/timing-estimation.md).
///
/// - Plans are downloaded only while the user contributes field data (the server gives them only to
///   holders of an upload token), only while the app is in the foreground, and only when the last
///   download is 12 hours old or more. They are kept in a cache that is not used once it is more
///   than seven days old. Stopping the contribution deletes them.
/// - Every intersection's plans are downloaded, never only those the user has heard, so the server
///   does not learn which intersections the user cares about.
/// - Live changes from Red to Green are compared with the plans; a cell more than 5 s off is stopped
///   for the rest of the JST day (「実測との照合」). Demo and played-back data are never checked.
/// - The estimate is never a signal state: this model gives no colour, no announcement, no haptic
///   and no notification, only a range of seconds to the next start of green.
@MainActor
@Observable
final class TimingModel {
    /// Plans are downloaded again once the last download is this old.
    static let refreshInterval: TimeInterval = 12 * 60 * 60
    /// After a failed download, wait at least this long (the uploader's back-off may ask for longer).
    static let retryInterval: TimeInterval = 15 * 60
    /// An intersection heard within this many seconds shows its received signal, not an estimate.
    static let receptionWindow: TimeInterval = 10
    /// No estimate closer to the intersection than this (metres).
    static let minimumDistance: Double = 80
    /// The estimate screen lists at most this many intersections, nearest first.
    static let maximumListedIntersections = 20

    /// What the estimate screen shows for one intersection.
    enum Availability: Equatable {
        /// The user's position (within 30 m, at most 10 s old) or the intersection's is unknown.
        case unknownLocation
        /// Closer than 80 m: receive the signal instead.
        case tooClose
        /// Heard within the last 10 seconds: look at the received signal.
        case receiving
        /// Estimates may be shown.
        case available
    }

    /// One signal slot of a listed intersection.
    struct SlotEstimate: Identifiable, Equatable {
        let slot: Int
        /// `nil` when there is no estimate for this time.
        let estimate: TimingEstimate?

        var id: Int { slot }
    }

    /// One listed intersection.
    struct Row: Identifiable, Equatable {
        let id: String
        /// From the plans' Type 0 message; `nil` when unknown.
        let name: String?
        /// Metres from the user, when both positions are known.
        let distance: Double?
        let availability: Availability
        /// Every slot with plans; estimates only when `availability` is `.available`.
        let slots: [SlotEstimate]
    }

    /// The plans in use; `nil` while there are none (never downloaded, cache too old, or not contributing).
    private(set) var plans: TimingPlans?
    private(set) var fetchedAt: Date?
    private(set) var isContributing = false
    private(set) var stopped: StoppedTimingCells

    /// Location for the estimate screen only, separate from the field-data location.
    @ObservationIgnored private let location = LocationProvider()
    @ObservationIgnored private let uploader: ReportUploader?
    @ObservationIgnored private let cache: TimingPlanCache
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var fetchTask: Task<Void, Never>?
    /// Incremented for every download and every opt-out, so that a late result of an older one is ignored.
    @ObservationIgnored private var fetchGeneration = 0
    @ObservationIgnored private var nextAttempt: Date?
    @ObservationIgnored private var detector = GreenStartDetector()
    /// The intersections of `plans` that have plans and a known position, decoded once per download
    /// instead of on every refresh of the estimate screen.
    @ObservationIgnored private var places: [Place] = []

    private struct Place {
        let intersection: TimingPlans.Intersection
        let coordinate: Coordinate
        let name: String?
    }

    init(uploader: ReportUploader?, defaults: UserDefaults = .standard) {
        self.uploader = uploader
        self.defaults = defaults
        cache = TimingPlanCache(fileURL: URL.cachesDirectory
            .appendingPathComponent("TimingPlans", isDirectory: true)
            .appendingPathComponent("plans.json"))
        var stopped = defaults.data(forKey: SettingsKey.timingStoppedCells)
            .flatMap { try? JSONDecoder().decode(StoppedTimingCells.self, from: $0) } ?? StoppedTimingCells()
        stopped.removeEntries(before: JapanCalendar.day(of: Date()))
        self.stopped = stopped
    }

    // MARK: - Contribution and downloads

    /// Applies the field-data choice. Turning it off stops a download in progress and deletes the
    /// plans and the stopped cells.
    func setContributing(_ contributing: Bool) {
        isContributing = contributing
        guard contributing else {
            fetchGeneration += 1
            fetchTask?.cancel()
            fetchTask = nil
            nextAttempt = nil
            use(nil, fetchedAt: nil)
            cache.remove()
            detector.reset()
            stopped = StoppedTimingCells()
            defaults.removeObject(forKey: SettingsKey.timingStoppedCells)
            return
        }
        if plans == nil, let entry = cache.load(now: Date()) {
            use(entry.plans, fetchedAt: entry.fetchedAt)
        }
        refreshIfNeeded()
    }

    /// Downloads the plans when the user contributes, the app is in the foreground, and the last
    /// download is 12 hours old or more. Called when the app becomes active, when the user opts in
    /// and when the estimate screen opens.
    func refreshIfNeeded() {
        let now = Date()
        dropExpiredPlans(now: now)
        guard isContributing, let uploader, fetchTask == nil,
              UIApplication.shared.applicationState != .background
        else { return }
        if let fetchedAt, (0..<Self.refreshInterval).contains(now.timeIntervalSince(fetchedAt)) { return }
        if let nextAttempt, now < nextAttempt { return }
        fetchGeneration += 1
        let generation = fetchGeneration
        fetchTask = Task { [weak self] in
            let result: Result<TimingPlanDownload, any Error>
            do {
                result = .success(try await uploader.fetchPlans())
            } catch {
                result = .failure(error)
            }
            self?.finishFetch(result, generation: generation)
        }
    }

    /// Called when the app moves to the background: no download runs there.
    func sceneDidEnterBackground() {
        fetchGeneration += 1
        fetchTask?.cancel()
        fetchTask = nil
        detector.reset()
    }

    private func finishFetch(_ result: Result<TimingPlanDownload, any Error>, generation: Int) {
        // Opted out, or moved to the background, meanwhile: keep nothing.
        guard generation == fetchGeneration else { return }
        fetchTask = nil
        guard isContributing else { return }
        let now = Date()
        switch result {
        case .success(let download):
            use(download.plans, fetchedAt: now)
            nextAttempt = nil
            try? cache.save(download.body, fetchedAt: now)
        case .failure(let error):
            var next = now.addingTimeInterval(Self.retryInterval)
            if case .backingOff(let until)? = error as? UploadError {
                next = max(next, until)
            }
            nextAttempt = next
        }
    }

    /// Plans older than seven days are not used, also while the app stays open.
    private func dropExpiredPlans(now: Date) {
        guard let fetchedAt else { return }
        let age = now.timeIntervalSince(fetchedAt)
        guard age > TimingPlanCache.maximumAge || age < -TimingPlanCache.clockTolerance else { return }
        use(nil, fetchedAt: nil)
    }

    private func use(_ newPlans: TimingPlans?, fetchedAt date: Date?) {
        plans = newPlans
        fetchedAt = date
        places = newPlans?.intersections.compactMap { intersection in
            guard !intersection.plans.isEmpty, let coordinate = intersection.coordinate else { return nil }
            return Place(intersection: intersection, coordinate: coordinate, name: intersection.decodedName)
        } ?? []
    }

    // MARK: - Live check

    /// Compares the signals of one live packet with the plans (「実測との照合」). Demo and played-back
    /// packets must never be passed here.
    func recordLiveSignals(intersectionID: String, signals: [PedestrianSignal], at timestamp: Date) {
        guard isContributing else { return }
        let starts = detector.update(intersectionID: intersectionID, signals: signals, at: timestamp)
        guard !starts.isEmpty, let plans else { return }
        var updated = stopped
        for start in starts {
            TimingEstimator.checkLiveGreenStart(
                at: start.at, intersectionID: start.intersectionID, slot: start.slot, plans: plans, stopped: &updated
            )
        }
        updated.removeEntries(before: JapanCalendar.day(of: timestamp))
        guard updated != stopped else { return }
        stopped = updated
        if let data = try? JSONEncoder().encode(updated) {
            defaults.set(data, forKey: SettingsKey.timingStoppedCells)
        }
    }

    /// Called when live reception stops: the next packet starts afresh.
    func receptionDidStop() {
        detector.reset()
    }

    // MARK: - Estimate screen

    /// Starts location updates for the estimate screen, only if the user already allowed location
    /// access (this screen never asks for it).
    func startLocationUpdates() {
        switch location.authorization {
        case .authorizedWhenInUse, .authorizedAlways:
            location.start()
        default:
            break
        }
    }

    func stopLocationUpdates() {
        location.stop()
    }

    /// Whether location access was refused or is not allowed on this device.
    var isLocationDenied: Bool {
        switch location.authorization {
        case .denied, .restricted: true
        default: false
        }
    }

    /// The user's position if it is within 30 m and at most 10 s old.
    func userLocation(at now: Date) -> Coordinate? {
        location.context(at: now).userLocation
    }

    /// The intersections with plans, nearest first, and what to show for each at `now`.
    /// - Parameters:
    ///   - user: the user's position (`userLocation(at:)`), or `nil` when unknown.
    ///   - lastHeard: when a packet of an intersection last arrived, if it did.
    func rows(at now: Date, user: Coordinate?, lastHeard: (String) -> Date?) -> [Row] {
        // Read `plans` so that the screen is redrawn when they change; `places` is derived from them.
        guard plans != nil, let user else { return [] }
        let located = places.map { place in
            (place: place, distance: Bucketing.distance(from: user, to: place.coordinate))
        }
        let nearest = located
            .sorted { ($0.distance, $0.place.intersection.id) < ($1.distance, $1.place.intersection.id) }
            .prefix(Self.maximumListedIntersections)
        return nearest.map { entry in
            let intersection = entry.place.intersection
            let distance = entry.distance
            let availability = Self.availability(distance: distance, lastHeard: lastHeard(intersection.id), now: now)
            let slots = intersection.slots.map { slot in
                SlotEstimate(
                    slot: slot,
                    estimate: availability == .available
                        ? TimingEstimator.estimate(for: intersection, slot: slot, at: now, stopped: stopped)
                        : nil
                )
            }
            return Row(id: intersection.id, name: entry.place.name, distance: distance, availability: availability, slots: slots)
        }
    }

    /// 「表示の規則」 for an intersection whose distance from the user is known.
    static func availability(distance: Double?, lastHeard: Date?, now: Date) -> Availability {
        if let lastHeard, abs(now.timeIntervalSince(lastHeard)) <= receptionWindow { return .receiving }
        guard let distance else { return .unknownLocation }
        return distance < minimumDistance ? .tooClose : .available
    }
}
