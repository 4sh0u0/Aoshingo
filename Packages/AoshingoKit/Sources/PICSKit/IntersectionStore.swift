// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Holds the state of every intersection heard during a session.
///
/// Like ble-pics-viewer's Web version it keeps at most 100 intersections and drops the one that was
/// registered first when a new one arrives.
public struct IntersectionStore: Sendable {
    public static let defaultCapacity = 100

    public let capacity: Int
    /// Intersection IDs in registration order.
    public private(set) var order: [String] = []
    private var states: [String: IntersectionState] = [:]

    public init(capacity: Int = IntersectionStore.defaultCapacity) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    public subscript(id: String) -> IntersectionState? { states[id] }

    /// All intersections in registration order.
    public var all: [IntersectionState] { order.compactMap { states[$0] } }

    public var isEmpty: Bool { states.isEmpty }

    /// Applies one decoded packet and returns the updated state.
    @discardableResult
    public mutating func ingest(
        _ packet: PICSPacket,
        raw: [UInt8],
        at timestamp: Date,
        metadata: AdvertisementMetadata = AdvertisementMetadata()
    ) -> IntersectionState {
        let id = packet.intersectionID
        if states[id] == nil {
            if states.count >= capacity, let oldest = order.first {
                order.removeFirst()
                states[oldest] = nil
            }
            order.append(id)
        }
        let state = IntersectionState.updated(states[id], with: packet, raw: raw, at: timestamp, metadata: metadata)
        states[id] = state
        return state
    }

    public mutating func removeAll() {
        order.removeAll()
        states.removeAll()
    }

    /// The intersection most likely being approached: the strongest smoothed RSSI among the
    /// intersections heard within `window` seconds. Falls back to the most recently heard one when
    /// no RSSI is available.
    public func nearest(at now: Date, within window: TimeInterval = 10) -> IntersectionState? {
        let recent = states.values.filter { now.timeIntervalSince($0.timestamp) <= window }
        let withRSSI = recent.filter { $0.smoothedRSSI != nil }
        if let strongest = withRSSI.max(by: { lhs, rhs in
            (lhs.smoothedRSSI!, rhs.id) < (rhs.smoothedRSSI!, lhs.id)
        }) {
            return strongest
        }
        return recent.max { ($0.timestamp, $1.id) < ($1.timestamp, $0.id) }
    }
}
