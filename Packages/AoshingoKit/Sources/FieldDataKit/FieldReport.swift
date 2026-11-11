// SPDX-License-Identifier: Apache-2.0

import Foundation
import PICSKit

/// Body of `POST /v1/reports` (schema 2). See docs/field-data-api.md.
///
/// Every nullable field is encoded as an explicit `null`. Decoding accepts missing keys as `null`
/// (or an empty list), so a schema 1 body still decodes.
public struct FieldReport: Sendable, Hashable, Codable {
    public static let schemaVersion = 2

    public var schema: Int
    public var client: String?
    public var intersections: [Intersection]

    public init(client: String?, intersections: [Intersection]) {
        self.schema = Self.schemaVersion
        self.client = client
        self.intersections = intersections
    }

    public struct Intersection: Sendable, Hashable, Codable {
        public var id: String
        public var serviceUUIDs: [String]
        /// Transmitters seen for this intersection while the report was collected (at most 32).
        /// `emitter` fields elsewhere are indices `0..<emitters`, assigned per report in order of appearance.
        public var emitters: Int
        /// One entry per transmitter: `emitterInfo.count == emitters`.
        public var emitterInfo: [EmitterInfo]
        public var observations: [Observation]
        public var transitions: [Transition]
        public var steps: [Step]
        /// Reception statistics per transmitter and message type, before sampling.
        public var packets: [PacketStats]
        /// Periods of continuous reception (packets at most 5 s apart).
        public var coverage: [Coverage]
        /// Marks a tester added in the "現地確認" section.
        public var labels: [Label]

        public init(
            id: String,
            serviceUUIDs: [String],
            emitters: Int,
            emitterInfo: [EmitterInfo] = [],
            observations: [Observation],
            transitions: [Transition],
            steps: [Step] = [],
            packets: [PacketStats] = [],
            coverage: [Coverage] = [],
            labels: [Label] = []
        ) {
            self.id = id
            self.serviceUUIDs = serviceUUIDs
            self.emitters = emitters
            self.emitterInfo = emitterInfo
            self.observations = observations
            self.transitions = transitions
            self.steps = steps
            self.packets = packets
            self.coverage = coverage
            self.labels = labels
        }

        private enum CodingKeys: String, CodingKey {
            case id, serviceUUIDs, emitters, emitterInfo, observations, transitions, steps, packets, coverage, labels
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            serviceUUIDs = try container.decodeIfPresent([String].self, forKey: .serviceUUIDs) ?? []
            emitters = try container.decodeIfPresent(Int.self, forKey: .emitters) ?? 0
            emitterInfo = try container.decodeIfPresent([EmitterInfo].self, forKey: .emitterInfo) ?? []
            observations = try container.decodeIfPresent([Observation].self, forKey: .observations) ?? []
            transitions = try container.decodeIfPresent([Transition].self, forKey: .transitions) ?? []
            steps = try container.decodeIfPresent([Step].self, forKey: .steps) ?? []
            packets = try container.decodeIfPresent([PacketStats].self, forKey: .packets) ?? []
            coverage = try container.decodeIfPresent([Coverage].self, forKey: .coverage) ?? []
            labels = try container.decodeIfPresent([Label].self, forKey: .labels) ?? []
        }
    }

    /// What the advertisements of one transmitter said about it.
    public struct EmitterInfo: Sendable, Hashable, Codable {
        /// Advertised transmit power in dBm (−127…20).
        public var txPower: Int?
        public var connectable: Bool?

        public init(txPower: Int? = nil, connectable: Bool? = nil) {
            self.txPower = txPower
            self.connectable = connectable
        }

        private enum CodingKeys: String, CodingKey { case txPower, connectable }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(txPower, forKey: .txPower)
            try container.encode(connectable, forKey: .connectable)
        }
    }

    public struct Observation: Sendable, Hashable, Codable {
        /// Unix seconds.
        public var t: Int
        /// Manufacturer data as received on iOS (starts with `CE01`), uppercase hex.
        public var raw: String
        /// 5 dB bucket.
        public var rssi: Int?
        /// Sector 0–7 from the intersection to the user.
        public var bearing: Int?
        /// Sector 0–7 of the device's true heading.
        public var heading: Int?
        /// Index of the transmitter (`0..<emitters`).
        public var emitter: Int?
        /// Distance ring from the intersection to the user: 0, 10, 20, 40, 80 or 160 (lower bound, metres).
        public var distance: Int?
        /// Horizontal accuracy of the user's position: 5, 10, 20 or 30 (upper bound, metres).
        public var accuracy: Int?
        /// Sector 0–7 of the user's direction of travel.
        public var course: Int?
        /// Speed class: 0 (< 0.5 m/s), 1 (< 2.5 m/s) or 2.
        public var speed: Int?
        /// Other Bluetooth devices seen in the last 30 s: 0, 1, 5, 10, 20, 50 or 100 (lower bound).
        public var nearby: Int?

        public init(
            t: Int,
            raw: String,
            rssi: Int?,
            bearing: Int?,
            heading: Int?,
            emitter: Int? = nil,
            distance: Int? = nil,
            accuracy: Int? = nil,
            course: Int? = nil,
            speed: Int? = nil,
            nearby: Int? = nil
        ) {
            self.t = t
            self.raw = raw
            self.rssi = rssi
            self.bearing = bearing
            self.heading = heading
            self.emitter = emitter
            self.distance = distance
            self.accuracy = accuracy
            self.course = course
            self.speed = speed
            self.nearby = nearby
        }

        private enum CodingKeys: String, CodingKey {
            case t, raw, rssi, bearing, heading, emitter, distance, accuracy, course, speed, nearby
        }

        // The contract spells missing values as explicit `null`.
        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(t, forKey: .t)
            try container.encode(raw, forKey: .raw)
            try container.encode(rssi, forKey: .rssi)
            try container.encode(bearing, forKey: .bearing)
            try container.encode(heading, forKey: .heading)
            try container.encode(emitter, forKey: .emitter)
            try container.encode(distance, forKey: .distance)
            try container.encode(accuracy, forKey: .accuracy)
            try container.encode(course, forKey: .course)
            try container.encode(speed, forKey: .speed)
            try container.encode(nearby, forKey: .nearby)
        }
    }

    /// A change of one pedestrian signal's state.
    public struct Transition: Sendable, Hashable, Codable {
        public var t: Int
        /// 1-based slot.
        public var slot: Int
        public var from: SignalState
        public var to: SignalState
        /// Index of the transmitter of the packet that first showed `to`.
        public var emitter: Int?
        /// Milliseconds (multiple of 100, at most 5000) between the last packet showing `from` and this one.
        public var gap: Int?
        /// Milliseconds (multiple of 100, at most one hour) the signal was `from`, when its change into
        /// `from` was received too, with no pause in reception since.
        public var held: Int?
        /// Milliseconds (as `held`) since the signal last changed into `to`, with no pause in reception since.
        public var cycle: Int?

        public init(
            t: Int,
            slot: Int,
            from: SignalState,
            to: SignalState,
            emitter: Int? = nil,
            gap: Int? = nil,
            held: Int? = nil,
            cycle: Int? = nil
        ) {
            self.t = t
            self.slot = slot
            self.from = from
            self.to = to
            self.emitter = emitter
            self.gap = gap
            self.held = held
            self.cycle = cycle
        }

        private enum CodingKeys: String, CodingKey { case t, slot, from, to, emitter, gap, held, cycle }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(t, forKey: .t)
            try container.encode(slot, forKey: .slot)
            try container.encode(from, forKey: .from)
            try container.encode(to, forKey: .to)
            try container.encode(emitter, forKey: .emitter)
            try container.encode(gap, forKey: .gap)
            try container.encode(held, forKey: .held)
            try container.encode(cycle, forKey: .cycle)
        }
    }

    /// A change of a signal's remaining-time indication ("残り目安", 1…8) while its state stayed the same.
    public struct Step: Sendable, Hashable, Codable {
        public var t: Int
        /// 1-based slot.
        public var slot: Int
        public var state: SignalState
        public var from: Int?
        public var to: Int?
        /// Index of the transmitter of the packet that first showed `to`.
        public var emitter: Int?
        /// Milliseconds (multiple of 100, at most one hour) the indication was `from`, when the moment it
        /// became `from` was received too, with no pause in reception since.
        public var held: Int?

        public init(t: Int, slot: Int, state: SignalState, from: Int?, to: Int?, emitter: Int? = nil, held: Int? = nil) {
            self.t = t
            self.slot = slot
            self.state = state
            self.from = from
            self.to = to
            self.emitter = emitter
            self.held = held
        }

        private enum CodingKeys: String, CodingKey { case t, slot, state, from, to, emitter, held }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(t, forKey: .t)
            try container.encode(slot, forKey: .slot)
            try container.encode(state, forKey: .state)
            try container.encode(from, forKey: .from)
            try container.encode(to, forKey: .to)
            try container.encode(emitter, forKey: .emitter)
            try container.encode(held, forKey: .held)
        }
    }

    /// Reception statistics of one transmitter and message type, before sampling.
    public struct PacketStats: Sendable, Hashable, Codable {
        public var emitter: Int
        /// PICS message type 0–2.
        public var type: Int
        public var count: Int
        /// Shortest interval between consecutive packets, in milliseconds (multiple of 10, at most 600000).
        public var minInterval: Int?
        /// Median interval (the lower one for an even number of intervals), as `minInterval`.
        public var medianInterval: Int?

        public init(emitter: Int, type: Int, count: Int, minInterval: Int?, medianInterval: Int?) {
            self.emitter = emitter
            self.type = type
            self.count = count
            self.minInterval = minInterval
            self.medianInterval = medianInterval
        }

        private enum CodingKeys: String, CodingKey { case emitter, type, count, minInterval, medianInterval }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(emitter, forKey: .emitter)
            try container.encode(type, forKey: .type)
            try container.encode(count, forKey: .count)
            try container.encode(minInterval, forKey: .minInterval)
            try container.encode(medianInterval, forKey: .medianInterval)
        }
    }

    /// A period (Unix seconds, inclusive) in which packets of the intersection arrived at most 5 s apart.
    public struct Coverage: Sendable, Hashable, Codable {
        public var start: Int
        public var end: Int

        public init(start: Int, end: Int) {
            self.start = start
            self.end = end
        }
    }

    /// A mark a tester added in the "現地確認" section.
    public struct Label: Sendable, Hashable, Codable {
        public enum Kind: String, Sendable, Hashable, Codable, CaseIterable {
            /// The signal in `slot` is for the crosswalk the device is facing.
            case crosswalk
            /// The tester pressed the push button.
            case button
        }

        public var t: Int
        public var kind: Kind
        /// 1-based slot; required for `crosswalk`.
        public var slot: Int?
        /// Sector 0–7 of the device's true heading.
        public var heading: Int?
        /// Sector 0–7 from the intersection to the user.
        public var bearing: Int?
        /// Distance ring, as `Observation.distance`.
        public var distance: Int?

        public init(t: Int, kind: Kind, slot: Int?, heading: Int?, bearing: Int?, distance: Int?) {
            self.t = t
            self.kind = kind
            self.slot = slot
            self.heading = heading
            self.bearing = bearing
            self.distance = distance
        }

        private enum CodingKeys: String, CodingKey { case t, kind, slot, heading, bearing, distance }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(t, forKey: .t)
            try container.encode(kind, forKey: .kind)
            try container.encode(slot, forKey: .slot)
            try container.encode(heading, forKey: .heading)
            try container.encode(bearing, forKey: .bearing)
            try container.encode(distance, forKey: .distance)
        }
    }

    public var observationCount: Int { intersections.reduce(0) { $0 + $1.observations.count } }
    public var transitionCount: Int { intersections.reduce(0) { $0 + $1.transitions.count } }
    public var stepCount: Int { intersections.reduce(0) { $0 + $1.steps.count } }
    public var labelCount: Int { intersections.reduce(0) { $0 + $1.labels.count } }

    /// Deterministic JSON (sorted keys).
    public func encoded() throws -> Data {
        try Self.makeEncoder().encode(self)
    }

    /// The encoder for report bodies. Parts encode to the same bytes alone as inside a report,
    /// which `ReportContract` relies on to measure them.
    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    /// The client string sent with reports, for example `aoshingo-ios/0.1.0`.
    /// Characters the server does not accept are dropped.
    public static func clientString(platform: String = "ios", version: String) -> String {
        let allowed = Set("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz.+-")
        let cleanVersion = String(version.filter(allowed.contains).prefix(20))
        return "aoshingo-\(platform)/\(cleanVersion.isEmpty ? "0" : cleanVersion)"
    }
}
