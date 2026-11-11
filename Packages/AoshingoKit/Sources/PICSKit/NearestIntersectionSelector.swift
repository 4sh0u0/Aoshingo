// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Chooses the intersection that "follow the nearest" shows, with hysteresis.
///
/// Two intersections with similar signal strength must not take turns being shown: a VoiceOver user
/// whose focus stays on "1 番" would otherwise hear the other intersection's 青 while facing a red light.
/// The followed intersection therefore changes only when
///
/// - another intersection's smoothed RSSI leads it by at least `switchMargin` on every evaluation for at
///   least `switchDelay`, measured up to a packet heard from that intersection, so one strong packet
///   followed by silence never takes over; or
/// - the followed intersection has not been heard for `recentWindow` seconds, or was dropped from the
///   store. Then the nearest intersection heard within `recentWindow` is followed (the strongest smoothed
///   RSSI, or the most recently heard one when there is no RSSI). If none was heard recently, an expired
///   intersection is kept, and with nothing followed the most recently heard one is taken.
///
/// The first lock takes the nearest recently heard intersection at once.
///
/// Call `update(with:at:)` after every packet and periodically (about once a second), so that the time
/// conditions are noticed while no packets arrive.
public struct NearestIntersectionSelector: Sendable, Hashable {
    /// A candidate must be at least this many dB stronger (smoothed RSSI) than the followed intersection...
    public static let switchMargin: Double = 6
    /// ...continuously for at least this many seconds before it is followed instead.
    public static let switchDelay: TimeInterval = 3
    /// Intersections not heard for longer than this are not candidates, and a followed one has expired.
    public static let recentWindow: TimeInterval = 10

    /// The intersection being followed, or `nil` before anything was heard.
    public private(set) var followedID: String?
    /// When each candidate started to lead the followed intersection by at least `switchMargin`.
    private var leadingSince: [String: Date] = [:]

    public init() {}

    /// Re-evaluates the choice against the store and returns the followed intersection ID.
    @discardableResult
    public mutating func update(with store: IntersectionStore, at now: Date) -> String? {
        guard let currentID = followedID, let current = store[currentID] else {
            // Nothing followed yet, or the followed intersection was dropped from the store.
            follow(store.nearest(at: now, within: Self.recentWindow) ?? store.mostRecentlyHeard)
            return followedID
        }

        guard Self.isRecent(current, at: now) else {
            // The followed intersection has expired. Keep it when nothing else was heard recently:
            // switching between two silent intersections would only add a confusing announcement.
            if let next = store.nearest(at: now, within: Self.recentWindow) {
                follow(next)
            } else {
                leadingSince.removeAll()
            }
            return followedID
        }

        guard let currentRSSI = current.smoothedRSSI else {
            // Without a strength for the followed intersection there is nothing to compare against.
            leadingSince.removeAll()
            return followedID
        }

        var stillLeading: [String: Date] = [:]
        var ready: [IntersectionState] = []
        for candidate in store.all where candidate.id != currentID && Self.isRecent(candidate, at: now) {
            guard let rssi = candidate.smoothedRSSI, rssi - currentRSSI >= Self.switchMargin else { continue }
            let since = leadingSince[candidate.id] ?? now
            stillLeading[candidate.id] = since
            if candidate.timestamp.timeIntervalSince(since) >= Self.switchDelay {
                ready.append(candidate)
            }
        }
        // A candidate that stopped leading, even once, starts from zero next time.
        leadingSince = stillLeading

        if let next = ready.max(by: Self.isWeaker) {
            follow(next)
        }
        return followedID
    }

    /// Forgets the followed intersection, for example when a new source starts.
    public mutating func reset() {
        followedID = nil
        leadingSince.removeAll()
    }

    private mutating func follow(_ state: IntersectionState?) {
        followedID = state?.id
        leadingSince.removeAll()
    }

    private static func isRecent(_ state: IntersectionState, at now: Date) -> Bool {
        now.timeIntervalSince(state.timestamp) <= recentWindow
    }

    /// Orders by smoothed RSSI; ties go to the smaller ID so the result does not depend on order.
    private static func isWeaker(_ lhs: IntersectionState, _ rhs: IntersectionState) -> Bool {
        let left = lhs.smoothedRSSI ?? -.infinity
        let right = rhs.smoothedRSSI ?? -.infinity
        return (left, rhs.id) < (right, lhs.id)
    }
}
