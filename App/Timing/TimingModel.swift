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
/// - Plans give no estimate once more than seven days have passed since the UTC day the server built
///   them (`TimingPlans.generated`), or when that day is unknown; the estimator checks this for every
///   estimate.
/// - Every intersection's plans are downloaded, never only those the user has heard, so the server
///   does not learn which intersections the user cares about.
/// - Live changes from Red to Green are compared with the plans; a cell more than 5 s off is stopped
///   for the rest of the JST day (「実測との照合」). Demo and played-back data are never checked.
/// - The estimate is never a signal state: this model gives no colour, no announcement, no haptic
///   and no notification, only a range of seconds to the next start of green.
/// - No estimate at all while live packets arrive: one from any intersection within the last 10 s
///   stops every estimate. Nor for an intersection that may be closer than 80 m once the accuracy of
///   the user's position is taken into account.
@MainActor
@Observable
final class TimingModel {
    /// Plans are downloaded again once the last download is this old.
    static let refreshInterval: TimeInterval = 12 * 60 * 60
    /// After a failed download, wait at least this long (the uploader's back-off may ask for longer).
    static let retryInterval: TimeInterval = 15 * 60
    /// After a live packet of any intersection, no estimate is shown for this many seconds.
    static let receptionWindow: TimeInterval = 10
    /// No estimate when the user may be closer to the intersection than this (metres): the distance
    /// less the horizontal accuracy of the user's position.
    static let minimumDistance: Double = 80
    /// The estimate screen lists at most this many intersections, nearest first.
    static let maximumListedIntersections = 20

    /// What the estimate screen shows for one intersection.
    enum Availability: Equatable {
        /// The user's position (within 30 m, at most 10 s old) or the intersection's is unknown.
        case unknownLocation
        /// Possibly closer than 80 m (the distance less the accuracy of the position): receive the
        /// signal instead.
        case tooClose
        /// A live packet of any intersection arrived within the last 10 seconds: look at the received
        /// signal. Applies to every intersection at once.
        case receiving
        /// Estimates may be shown.
        case available
    }

    /// The user's position for the estimate screen.
    struct UserPosition: Equatable {
        let coordinate: Coordinate
        /// Horizontal accuracy in metres (0…30): the user may be this much closer to an intersection.
        let accuracy: Double
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
    /// When the last live PICS packet of any intersection arrived; demo and played-back packets never
    /// set it. Not observed: the estimate screen redraws every second anyway, and is not redrawn for
    /// every packet.
    @ObservationIgnored private var lastLiveReception: Date?
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

    // MARK: - Live reception

    /// Records that a live PICS packet of any intersection arrived at `timestamp`, with or without
    /// signals: no estimate is shown for the next 10 seconds (`isReceiving(at:)`). Demo and
    /// played-back packets must never be passed here.
    func recordLiveReception(at timestamp: Date) {
        lastLiveReception = timestamp
    }

    /// Whether a live packet of any intersection arrived within the last 10 seconds. Then no estimate
    /// is shown for any intersection: the user should look at the signal being received.
    func isReceiving(at now: Date) -> Bool {
        guard let lastLiveReception else { return false }
        return abs(now.timeIntervalSince(lastLiveReception)) <= Self.receptionWindow
    }

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

    /// The user's position and its accuracy if it is within 30 m and at most 10 s old.
    func userPosition(at now: Date) -> UserPosition? {
        let context = location.context(at: now)
        guard let coordinate = context.userLocation, let accuracy = context.horizontalAccuracy else { return nil }
        return UserPosition(coordinate: coordinate, accuracy: accuracy)
    }

    /// The intersections with plans, nearest first, and what to show for each at `now`.
    /// - Parameter user: the user's position (`userPosition(at:)`), or `nil` when unknown.
    func rows(at now: Date, user: UserPosition?) -> [Row] {
        // Read `plans` so that the screen is redrawn when they change; `places` is derived from them.
        guard let plans, let user else { return [] }
        let receiving = isReceiving(at: now)
        let located = places.map { place in
            (place: place, distance: Bucketing.distance(from: user.coordinate, to: place.coordinate))
        }
        let nearest = located
            .sorted { ($0.distance, $0.place.intersection.id) < ($1.distance, $1.place.intersection.id) }
            .prefix(Self.maximumListedIntersections)
        return nearest.map { entry in
            let intersection = entry.place.intersection
            let distance = entry.distance
            let availability = Self.availability(distance: distance, accuracy: user.accuracy, isReceiving: receiving)
            let slots = intersection.slots.map { slot in
                SlotEstimate(
                    slot: slot,
                    estimate: availability == .available
                        ? TimingEstimator.estimate(for: intersection, generated: plans.generated, slot: slot, at: now, stopped: stopped)
                        : nil
                )
            }
            return Row(id: intersection.id, name: entry.place.name, distance: distance, availability: availability, slots: slots)
        }
    }

    /// Whether the plans in use list intersections but give no estimate because they were built more
    /// than seven days ago, or on an unknown day (`TimingEstimator.isCurrent`).
    func plansAreOutdated(at now: Date) -> Bool {
        guard let plans, !plans.intersections.isEmpty else { return false }
        return !TimingEstimator.isCurrent(generated: plans.generated, at: now)
    }

    /// 「表示の規則」 for one intersection.
    /// - Parameters:
    ///   - distance: metres from the user's position to the intersection, or `nil` when unknown.
    ///   - accuracy: the horizontal accuracy of the user's position in metres, or `nil` when unknown.
    ///   - isReceiving: whether a live packet of any intersection arrived within the last 10 seconds.
    static func availability(distance: Double?, accuracy: Double?, isReceiving: Bool) -> Availability {
        if isReceiving { return .receiving }
        guard let distance, let accuracy, distance.isFinite, distance >= 0, accuracy.isFinite, accuracy >= 0 else {
            return .unknownLocation
        }
        // The user may be up to `accuracy` metres closer than the position says: with an accuracy
        // of 28 m, a position 85 m away may be 57 m away.
        return distance - accuracy < minimumDistance ? .tooClose : .available
    }
}
