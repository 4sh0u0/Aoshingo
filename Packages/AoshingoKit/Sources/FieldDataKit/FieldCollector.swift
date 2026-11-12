// SPDX-License-Identifier: Apache-2.0

import Foundation
import PICSKit

/// Where the user was, and what was around, when a packet arrived or a label was added.
/// Only coarse sectors and classes derived from it leave the device (docs/field-data-api.md).
public struct ObservationContext: Sendable, Hashable {
    /// The user's position, or `nil` when unknown or too inaccurate (worse than 30 m, older than 10 s).
    /// Never uploaded.
    public var userLocation: Coordinate?
    /// Device true heading in degrees, or `nil`/negative when invalid.
    public var trueHeading: Double?
    /// Horizontal accuracy of `userLocation` in metres; set only together with it. A value that is
    /// negative or worse than 30 m makes the collector treat the position as unknown.
    public var horizontalAccuracy: Double?
    /// Direction of travel in degrees, or `nil` when invalid (the app keeps it only when iOS rates it
    /// within 45°). Used only together with `userLocation` and a speed of at least 0.5 m/s.
    public var course: Double?
    /// Speed in m/s, or `nil` when invalid (the app keeps it only when iOS rates it within 1.5 m/s).
    /// Used only together with `userLocation`.
    public var speed: Double?
    /// Distinct non-PICS Bluetooth devices seen in the last 30 s.
    public var nearbyDevices: Int?
    /// How the user is moving, from iOS's motion activity classifier (`Bucketing.activity`), or `nil`
    /// when unknown. Independent of the position, so it is sent even without a usable fix.
    public var activity: FieldReport.Activity?

    public init(
        userLocation: Coordinate? = nil,
        trueHeading: Double? = nil,
        horizontalAccuracy: Double? = nil,
        course: Double? = nil,
        speed: Double? = nil,
        nearbyDevices: Int? = nil,
        activity: FieldReport.Activity? = nil
    ) {
        self.userLocation = userLocation
        self.trueHeading = trueHeading
        self.horizontalAccuracy = horizontalAccuracy
        self.course = course
        self.speed = speed
        self.nearbyDevices = nearbyDevices
        self.activity = activity
    }

    /// `userLocation` unless its stated accuracy is invalid or worse than 30 m.
    var usableLocation: Coordinate? {
        if let horizontalAccuracy, Bucketing.accuracy(horizontalAccuracy) == nil { return nil }
        return userLocation
    }
}

/// Collects the data of one report window (at most 10 minutes).
///
/// Sampling keeps the upload small: per intersection and message type a packet is kept as an
/// observation when its content (ignoring the message ID byte) changed and at least one second
/// passed, or when the resample interval passed (5 s for signals, 60 s for the static name and
/// position messages). Every packet, kept or not, counts towards the transmitter numbering
/// (`emitters`, `emitterInfo`), the reception statistics (`packets`), the reception periods
/// (`coverage`) and the signal changes (`transitions`, `steps`). Packets the server would not
/// accept as `raw` (unknown message types, odd lengths) are ignored entirely.
///
/// Transmitters are numbered per window and intersection in the order they appear (at most 32;
/// packets of further transmitters carry no number and are left out of `packets`).
///
/// Transitions and steps carry the time of the packet that showed the change, as Unix seconds (`t`)
/// and the sub-second part rounded down to 100 ms (`ms`, schema 4).
///
/// A transition or step is recorded only when the previous signal packet of that intersection
/// arrived at most `maxTransitionGap` earlier: after a longer pause in reception (out of range, or
/// the app in the background) the time of the change is unknown, so it is not recorded. Such a pause,
/// `resetSignalStates()` and `discardAll()` also forget every slot's timing, so `held`, `cycle` and a
/// step's `held` are only set for periods received without a pause. Signal timing is kept across
/// report windows; it lives only in memory.
public struct FieldCollector: Sendable {
    public static let maxIntersections = 50
    public static let maxObservationsPerIntersection = 600
    public static let maxTransitionsPerIntersection = 300
    public static let maxStepsPerIntersection = ReportContract.maximumSteps
    public static let maxCoveragePerIntersection = ReportContract.maximumCoverage
    public static let maxLabelsPerIntersection = ReportContract.maximumLabels
    public static let maxEmitters = ReportContract.maximumEmitters
    /// Intervals kept per transmitter and message type for the median; `count` keeps counting.
    public static let maxIntervalsPerPacketKey = 10_000
    public static let maxPacketCount = ReportContract.maximumPacketCount
    public static let maxWindow: TimeInterval = 600
    public static let minimumChangedInterval: TimeInterval = 1
    /// The same as the app's "stale" threshold for signal data. Also the longest pause within a
    /// `coverage` period.
    public static let maxTransitionGap: TimeInterval = PICS.staleInterval

    public static func resampleInterval(forType type: UInt8) -> TimeInterval {
        type == 0 || type == 1 ? 60 : 5
    }

    private struct PacketKey: Hashable, Comparable, Sendable {
        var emitter: Int
        var type: UInt8

        static func < (lhs: Self, rhs: Self) -> Bool {
            (lhs.emitter, lhs.type) < (rhs.emitter, rhs.type)
        }
    }

    private struct PacketTally: Sendable {
        var count = 0
        var last: Date?
        /// Milliseconds, rounded to 10 ms.
        var intervals: [Int] = []

        mutating func record(at timestamp: Date) {
            count += 1
            guard let last else {
                self.last = timestamp
                return
            }
            if intervals.count < FieldCollector.maxIntervalsPerPacketKey,
               let interval = Bucketing.intervalMilliseconds(timestamp.timeIntervalSince(last)) {
                intervals.append(interval)
            }
            self.last = max(last, timestamp)
        }

        func stats(for key: PacketKey) -> FieldReport.PacketStats {
            let sorted = intervals.sorted()
            return FieldReport.PacketStats(
                emitter: key.emitter,
                type: Int(key.type),
                count: min(count, FieldCollector.maxPacketCount),
                minInterval: sorted.first,
                medianInterval: sorted.isEmpty ? nil : sorted[(sorted.count - 1) / 2]
            )
        }
    }

    private struct Bucket: Sendable {
        var serviceUUIDs: Set<String> = []
        var emitterIndices: [String: Int] = [:]
        var emitterInfo: [FieldReport.EmitterInfo] = []
        var observations: [FieldReport.Observation] = []
        var transitions: [FieldReport.Transition] = []
        var steps: [FieldReport.Step] = []
        var packets: [PacketKey: PacketTally] = [:]
        var coverage: [FieldReport.Coverage] = []
        /// When the last packet arrived, and whether reception since belongs to the last `coverage` entry.
        var lastPacket: Date?
        var coverageOpen = false
        var labels: [FieldReport.Label] = []

        var hasEntries: Bool {
            !(observations.isEmpty && transitions.isEmpty && steps.isEmpty && labels.isEmpty)
        }

        /// The transmitter's index, assigning the next one on first sight; `nil` beyond `maxEmitters`.
        mutating func index(ofEmitter alias: String) -> Int? {
            if let index = emitterIndices[alias] { return index }
            guard emitterInfo.count < FieldCollector.maxEmitters else { return nil }
            let index = emitterInfo.count
            emitterIndices[alias] = index
            emitterInfo.append(FieldReport.EmitterInfo())
            return index
        }

        mutating func extendCoverage(at timestamp: Date) {
            let seconds = Bucketing.seconds(timestamp)
            defer { lastPacket = max(lastPacket ?? timestamp, timestamp) }
            if let lastPacket, timestamp.timeIntervalSince(lastPacket) <= FieldCollector.maxTransitionGap {
                if coverageOpen { coverage[coverage.count - 1].end = max(coverage[coverage.count - 1].end, seconds) }
                return
            }
            // Keep the first entries; the last one kept may still grow while reception continues.
            coverageOpen = coverage.count < FieldCollector.maxCoveragePerIntersection
            if coverageOpen { coverage.append(FieldReport.Coverage(start: seconds, end: seconds)) }
        }
    }

    /// Timing of one signal slot under continuous reception. Local only.
    private struct SlotTiming: Sendable {
        var state: SignalState
        var remaining: Int?
        /// When the slot last changed into each state.
        var entered: [SignalState: Date] = [:]
        /// When the current remaining-time indication began (a state change or a step), if received.
        var remainingSince: Date?
    }

    private struct SignalTiming: Sendable {
        var slots: [SlotTiming]
        /// The last signal packet of the intersection.
        var at: Date
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
    private var signalTimings: [String: SignalTiming] = [:]
    private var coordinates: [String: Coordinate] = [:]

    public init() {}

    public var isEmpty: Bool { buckets.isEmpty }

    public var observationCount: Int { buckets.values.reduce(0) { $0 + $1.observations.count } }

    public var transitionCount: Int { buckets.values.reduce(0) { $0 + $1.transitions.count } }

    /// Records one received PICS packet.
    /// - Parameters:
    ///   - manufacturerData: the bytes as iOS delivered them, starting with `CE 01`.
    ///   - emitter: a session-local alias of the transmitter; only its per-report index is uploaded.
    ///   - txPower: the advertised transmit power in dBm (values outside −127…20 are ignored).
    ///   - connectable: whether the advertisement was connectable.
    public mutating func record(
        _ packet: PICSPacket,
        manufacturerData: [UInt8],
        at timestamp: Date,
        rssi: Int?,
        serviceUUIDs: [String] = [],
        emitter: String? = nil,
        txPower: Int? = nil,
        connectable: Bool? = nil,
        context: ObservationContext = ObservationContext()
    ) {
        guard ReportContract.isUploadable(packet, manufacturerData: manufacturerData) else { return }
        let id = packet.intersectionID
        if let coordinate = packet.coordinate { coordinates[id] = coordinate }
        guard openBucket(id) else { return }
        if windowStart == nil { windowStart = timestamp }

        buckets[id]!.serviceUUIDs.formUnion(serviceUUIDs.compactMap(Bucketing.serviceUUID))
        let emitterIndex = emitter.flatMap { buckets[id]!.index(ofEmitter: $0) }
        if let emitterIndex {
            if let txPower = Bucketing.txPower(txPower) { buckets[id]!.emitterInfo[emitterIndex].txPower = txPower }
            if let connectable { buckets[id]!.emitterInfo[emitterIndex].connectable = connectable }
            let key = PacketKey(emitter: emitterIndex, type: packet.messageType)
            buckets[id]!.packets[key, default: PacketTally()].record(at: timestamp)
        }
        buckets[id]!.extendCoverage(at: timestamp)

        if let signals = packet.signals {
            recordSignals(id: id, signals: signals, emitter: emitterIndex, at: timestamp)
        }

        guard buckets[id]!.observations.count < Self.maxObservationsPerIntersection,
              shouldKeep(packet: packet, manufacturerData: manufacturerData, at: timestamp)
        else { return }

        let place = position(of: id, context: context)
        let location = context.usableLocation
        // Speed and course describe the same fix as the position, so they need it too.
        let speed = location == nil ? nil : context.speed.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        buckets[id]!.observations.append(FieldReport.Observation(
            t: Bucketing.seconds(timestamp),
            raw: Hex.string(manufacturerData, separator: ""),
            rssi: Bucketing.rssi(rssi),
            bearing: place.bearing,
            heading: Bucketing.sector(degrees: context.trueHeading),
            emitter: emitterIndex,
            distance: place.distance,
            accuracy: location == nil ? nil : Bucketing.accuracy(context.horizontalAccuracy),
            course: (speed ?? 0) >= 0.5 ? Bucketing.sector(degrees: context.course) : nil,
            speed: Bucketing.speed(speed),
            nearby: Bucketing.nearby(context.nearbyDevices),
            activity: context.activity
        ))
    }

    /// Records a tester's mark for `intersectionID`, with the heading, bearing and distance ring at
    /// that moment (bearing and distance need a received Type 1 position of the intersection).
    /// - Returns: `false` when nothing was recorded: an invalid intersection ID, `crosswalk` without
    ///   a slot in 1…6, a `button` slot outside 1…6, the intersection limit of the window, or 20 labels
    ///   for this intersection in this window.
    @discardableResult
    public mutating func recordLabel(
        _ kind: FieldReport.Label.Kind,
        slot: Int?,
        intersectionID: String,
        at timestamp: Date,
        context: ObservationContext
    ) -> Bool {
        guard ReportContract.isValidIntersectionID(intersectionID) else { return false }
        if let slot {
            guard ReportContract.slots.contains(slot) else { return false }
        } else if kind == .crosswalk {
            return false
        }
        if let bucket = buckets[intersectionID] {
            guard bucket.labels.count < Self.maxLabelsPerIntersection else { return false }
        } else {
            guard openBucket(intersectionID) else { return false }
        }
        if windowStart == nil { windowStart = timestamp }
        let place = position(of: intersectionID, context: context)
        buckets[intersectionID]!.labels.append(FieldReport.Label(
            t: Bucketing.seconds(timestamp),
            kind: kind,
            slot: slot,
            heading: Bucketing.sector(degrees: context.trueHeading),
            bearing: place.bearing,
            distance: place.distance
        ))
        return true
    }

    /// `true` when the window is ten minutes old or an intersection hit its observation or step limit.
    public func shouldFlush(at now: Date) -> Bool {
        guard let windowStart else { return false }
        if now.timeIntervalSince(windowStart) >= Self.maxWindow { return true }
        return buckets.values.contains {
            $0.observations.count >= Self.maxObservationsPerIntersection || $0.steps.count >= Self.maxStepsPerIntersection
        }
    }

    /// Builds a report from the current window and starts a new one. Returns `nil` when empty.
    /// An intersection is included when it has an observation, transition, step or label.
    public mutating func makeReport(client: String?) -> FieldReport? {
        defer {
            windowStart = nil
            order.removeAll()
            buckets.removeAll()
        }
        let intersections = order.compactMap { id -> FieldReport.Intersection? in
            guard let bucket = buckets[id], bucket.hasEntries else { return nil }
            return FieldReport.Intersection(
                id: id,
                serviceUUIDs: Array(bucket.serviceUUIDs.sorted().prefix(ReportContract.maximumServiceUUIDs)),
                emitters: bucket.emitterInfo.count,
                emitterInfo: bucket.emitterInfo,
                observations: bucket.observations,
                transitions: bucket.transitions,
                steps: bucket.steps,
                packets: bucket.packets.sorted { $0.key < $1.key }.map { $0.value.stats(for: $0.key) },
                coverage: bucket.coverage,
                labels: bucket.labels
            )
        }
        return intersections.isEmpty ? nil : FieldReport(client: client, intersections: intersections)
    }

    /// Forgets everything, including the signal timing. Used when the user opts out.
    public mutating func discardAll() {
        self = FieldCollector()
    }

    /// Forgets the signal timing (for example when the app goes to the background), so the next
    /// packet of each intersection starts afresh instead of producing a transition or step, and no
    /// `held` or `cycle` spans the pause.
    public mutating func resetSignalStates() {
        signalTimings.removeAll()
    }

    /// Makes sure the window has a bucket for `id`; `false` when the intersection limit is reached.
    private mutating func openBucket(_ id: String) -> Bool {
        guard buckets[id] == nil else { return true }
        guard buckets.count < Self.maxIntersections else { return false }
        buckets[id] = Bucket()
        order.append(id)
        return true
    }

    /// Bearing sector and distance ring from the intersection to the user, when both positions are known.
    private func position(of id: String, context: ObservationContext) -> (bearing: Int?, distance: Int?) {
        guard let user = context.usableLocation, let origin = coordinates[id] else { return (nil, nil) }
        return (
            Bucketing.sector(degrees: Bucketing.bearing(from: origin, to: user)),
            Bucketing.distanceRing(Bucketing.distance(from: origin, to: user))
        )
    }

    private mutating func recordSignals(id: String, signals: [PedestrianSignal], emitter: Int?, at timestamp: Date) {
        let fresh = signals.map { SlotTiming(state: $0.state, remaining: $0.remaining) }
        guard let previous = signalTimings[id] else {
            signalTimings[id] = SignalTiming(slots: fresh, at: timestamp)
            return
        }
        let gap = timestamp.timeIntervalSince(previous.at)
        guard gap >= 0, gap <= Self.maxTransitionGap else {
            // The time of any change is unknown, and so is how long the current states have lasted.
            signalTimings[id] = SignalTiming(slots: fresh, at: timestamp)
            return
        }
        let seconds = Bucketing.seconds(timestamp)
        let subsecond = Bucketing.subsecondMilliseconds(timestamp)
        func since(_ start: Date?) -> Int? {
            start.flatMap { Bucketing.durationMilliseconds(timestamp.timeIntervalSince($0)) }
        }
        var slots = fresh
        for (index, signal) in signals.enumerated() where index < previous.slots.count {
            var slot = previous.slots[index]
            if slot.state != signal.state {
                if buckets[id]!.transitions.count < Self.maxTransitionsPerIntersection {
                    buckets[id]!.transitions.append(FieldReport.Transition(
                        t: seconds,
                        ms: subsecond,
                        slot: index + 1,
                        from: slot.state,
                        to: signal.state,
                        emitter: emitter,
                        gap: Bucketing.durationMilliseconds(gap),
                        held: since(slot.entered[slot.state]),
                        cycle: since(slot.entered[signal.state])
                    ))
                }
                slot.entered[signal.state] = timestamp
                slot.state = signal.state
                slot.remaining = signal.remaining
                slot.remainingSince = timestamp
            } else if slot.remaining != signal.remaining {
                if buckets[id]!.steps.count < Self.maxStepsPerIntersection {
                    buckets[id]!.steps.append(FieldReport.Step(
                        t: seconds,
                        ms: subsecond,
                        slot: index + 1,
                        state: signal.state,
                        from: slot.remaining,
                        to: signal.remaining,
                        emitter: emitter,
                        held: since(slot.remainingSince)
                    ))
                }
                slot.remaining = signal.remaining
                slot.remainingSince = timestamp
            }
            slots[index] = slot
        }
        signalTimings[id] = SignalTiming(slots: slots, at: timestamp)
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
