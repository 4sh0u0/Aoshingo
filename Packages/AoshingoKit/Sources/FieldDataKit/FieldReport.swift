// SPDX-License-Identifier: Apache-2.0

import Foundation
import PICSKit

/// Body of `POST /v1/reports` (schema 1). See docs/field-data-api.md.
public struct FieldReport: Sendable, Hashable, Codable {
    public static let schemaVersion = 1

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
        public var emitters: Int
        public var observations: [Observation]
        public var transitions: [Transition]

        public init(id: String, serviceUUIDs: [String], emitters: Int, observations: [Observation], transitions: [Transition]) {
            self.id = id
            self.serviceUUIDs = serviceUUIDs
            self.emitters = emitters
            self.observations = observations
            self.transitions = transitions
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

        public init(t: Int, raw: String, rssi: Int?, bearing: Int?, heading: Int?) {
            self.t = t
            self.raw = raw
            self.rssi = rssi
            self.bearing = bearing
            self.heading = heading
        }

        private enum CodingKeys: String, CodingKey { case t, raw, rssi, bearing, heading }

        // The contract spells missing values as explicit `null`.
        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(t, forKey: .t)
            try container.encode(raw, forKey: .raw)
            try container.encode(rssi, forKey: .rssi)
            try container.encode(bearing, forKey: .bearing)
            try container.encode(heading, forKey: .heading)
        }
    }

    public struct Transition: Sendable, Hashable, Codable {
        public var t: Int
        /// 1-based slot.
        public var slot: Int
        public var from: SignalState
        public var to: SignalState

        public init(t: Int, slot: Int, from: SignalState, to: SignalState) {
            self.t = t
            self.slot = slot
            self.from = from
            self.to = to
        }
    }

    public var observationCount: Int { intersections.reduce(0) { $0 + $1.observations.count } }
    public var transitionCount: Int { intersections.reduce(0) { $0 + $1.transitions.count } }

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
