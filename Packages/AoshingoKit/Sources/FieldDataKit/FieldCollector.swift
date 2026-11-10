// SPDX-License-Identifier: Apache-2.0

import Foundation
import PICSKit

/// Where the user was when a packet arrived. Only coarse sectors derived from it leave the device.
public struct ObservationContext: Sendable, Hashable {
    /// The user's position, or `nil` when unknown or too inaccurate. Never uploaded.
    public var userLocation: Coordinate?
    /// Device true heading in degrees, or `nil`/negative when invalid.
    public var trueHeading: Double?

    public init(userLocation: Coordinate? = nil, trueHeading: Double? = nil) {
        self.userLocation = userLocation
        self.trueHeading = trueHeading
    }
}

/// Collects observations and signal transitions for one report window (at most 10 minutes).
///
/// Sampling keeps the upload small: per intersection and message type a packet is kept when its
/// content (ignoring the message ID byte) changed and at least one second passed, or when the
/// resample interval passed (5 s for signals, 60 s for the static name and position messages).
public struct FieldCollector: Sendable {
    public static let maxIntersections = 50
    public static let maxObservationsPerIntersection = 600
    public static let maxTransitionsPerIntersection = 300
    public static let maxWindow: TimeInterval = 600
    public static let minimumChangedInterval: TimeInterval = 1

    public static func resampleInterval(forType type: UInt8) -> TimeInterval {
        type == 0 || type == 1 ? 60 : 5
    }

    private struct Bucket: Sendable {
        var serviceUUIDs: Set<String> = []
        var emitters: Set<String> = []
        var observations: [FieldReport.Observation] = []
        var transitions: [FieldReport.Transition] = []
    }

    private struct SampleKey: Hashable, Sendable {
        var intersection: String
        var type: UInt8
    }

    public private(set) var windowStart: Date?
    private var order: [String] = []
    private var buckets: [String: Bucket] = [:]
    private var lastKept: [SampleKey: (content: [UInt8], at: Date)] = [:]
    // Kept across report windows so the first transition of a window is not lost. Local only.
    private var lastStates: [String: [SignalState]] = [:]
    private var coordinates: [String: Coordinate] = [:]

    public init() {}

    public var isEmpty: Bool { buckets.isEmpty }

    public var observationCount: Int { buckets.values.reduce(0) { $0 + $1.observations.count } }

    public var transitionCount: Int { buckets.values.reduce(0) { $0 + $1.transitions.count } }

    /// Records one received PICS packet.
    /// - Parameters:
    ///   - manufacturerData: the bytes as iOS delivered them, starting with `CE 01`.
    ///   - emitter: a session-local alias of the transmitter; only the count is uploaded.
    public mutating func record(
        _ packet: PICSPacket,
        manufacturerData: [UInt8],
        at timestamp: Date,
        rssi: Int?,
        serviceUUIDs: [String] = [],
        emitter: String? = nil,
        context: ObservationContext = ObservationContext()
    ) {
        let id = packet.intersectionID
        if let coordinate = packet.coordinate { coordinates[id] = coordinate }

        if buckets[id] == nil {
            guard buckets.count < Self.maxIntersections else { return }
            buckets[id] = Bucket()
            order.append(id)
        }
        if windowStart == nil { windowStart = timestamp }
        let seconds = Bucketing.seconds(timestamp)

        buckets[id]!.serviceUUIDs.formUnion(serviceUUIDs.compactMap(Bucketing.serviceUUID))
        if let emitter { buckets[id]!.emitters.insert(emitter) }

        if let signals = packet.signals {
            recordTransitions(id: id, signals: signals, seconds: seconds)
        }

        guard buckets[id]!.observations.count < Self.maxObservationsPerIntersection,
              shouldKeep(packet: packet, manufacturerData: manufacturerData, at: timestamp)
        else { return }

        var bearing: Int?
        if let user = context.userLocation, let origin = coordinates[id] {
            bearing = Bucketing.sector(degrees: Bucketing.bearing(from: origin, to: user))
        }
        buckets[id]!.observations.append(FieldReport.Observation(
            t: seconds,
            raw: Hex.string(manufacturerData, separator: ""),
            rssi: Bucketing.rssi(rssi),
            bearing: bearing,
            heading: Bucketing.sector(degrees: context.trueHeading)
        ))
    }

    /// `true` when the window is ten minutes old or an intersection hit its observation limit.
    public func shouldFlush(at now: Date) -> Bool {
        guard let windowStart else { return false }
        if now.timeIntervalSince(windowStart) >= Self.maxWindow { return true }
        return buckets.values.contains { $0.observations.count >= Self.maxObservationsPerIntersection }
    }

    /// Builds a report from the current window and starts a new one. Returns `nil` when empty.
    public mutating func makeReport(client: String?) -> FieldReport? {
        defer {
            windowStart = nil
            order.removeAll()
            buckets.removeAll()
        }
        let intersections = order.compactMap { id -> FieldReport.Intersection? in
            guard let bucket = buckets[id], !(bucket.observations.isEmpty && bucket.transitions.isEmpty) else { return nil }
            return FieldReport.Intersection(
                id: id,
                serviceUUIDs: Array(bucket.serviceUUIDs.sorted().prefix(8)),
                emitters: min(bucket.emitters.count, 32),
                observations: bucket.observations,
                transitions: bucket.transitions
            )
        }
        return intersections.isEmpty ? nil : FieldReport(client: client, intersections: intersections)
    }

    /// Forgets everything, including the last known signal states. Used when the user opts out.
    public mutating func discardAll() {
        self = FieldCollector()
    }

    private mutating func recordTransitions(id: String, signals: [PedestrianSignal], seconds: Int) {
        let states = signals.map(\.state)
        defer { lastStates[id] = states }
        guard let previous = lastStates[id] else { return }
        for (index, state) in states.enumerated() where index < previous.count && previous[index] != state {
            guard buckets[id]!.transitions.count < Self.maxTransitionsPerIntersection else { return }
            buckets[id]!.transitions.append(FieldReport.Transition(t: seconds, slot: index + 1, from: previous[index], to: state))
        }
    }

    private mutating func shouldKeep(packet: PICSPacket, manufacturerData: [UInt8], at timestamp: Date) -> Bool {
        let key = SampleKey(intersection: packet.intersectionID, type: packet.messageType)
        // Ignore the message ID (payload byte 3, after the two company identifier bytes); it may be
        // a sequence counter that changes with every packet.
        var content = manufacturerData
        if content.count > 5 { content[5] = 0 }
        if let last = lastKept[key] {
            let elapsed = timestamp.timeIntervalSince(last.at)
            let changed = last.content != content
            guard elapsed >= Self.resampleInterval(forType: packet.messageType)
                    || (changed && elapsed >= Self.minimumChangedInterval)
            else { return false }
        }
        lastKept[key] = (content, timestamp)
        return true
    }
}
