// SPDX-License-Identifier: Apache-2.0

import Foundation
import PICSKit

/// The signal timing plans of `GET /v1/plans` (docs/timing-estimation.md): per intersection, signal
/// slot, day type and 30-minute time bin, the cycle and phase of the start of green.
///
/// Decoding is lenient element by element: an intersection or plan that cannot be read, or whose
/// values are outside the contract (`Plan.isValid`), is left out instead of failing the whole
/// response. Leaving a cell out only means that no estimate is shown for it.
public struct TimingPlans: Sendable, Hashable, Codable {
    public var intersections: [Intersection]

    public init(intersections: [Intersection]) {
        self.intersections = intersections
    }

    private enum CodingKeys: String, CodingKey { case intersections }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let items = try container.decode([Lossy<Intersection>].self, forKey: .intersections)
        intersections = items.compactMap(\.value)
    }

    /// The intersection with `id`, if it has plans.
    public subscript(id: String) -> Intersection? {
        intersections.first { $0.id == id }
    }

    /// One intersection and its plans.
    public struct Intersection: Sendable, Hashable, Codable, Identifiable {
        public var id: String
        /// The last Type 0 (name) message the server kept, as uppercase hex starting with `CE01`.
        public var name: String?
        /// The last Type 1 (position) message the server kept, likewise.
        public var position: String?
        public var plans: [Plan]

        public init(id: String, name: String? = nil, position: String? = nil, plans: [Plan]) {
            self.id = id
            self.name = name
            self.position = position
            self.plans = plans
        }

        private enum CodingKeys: String, CodingKey { case id, name, position, plans }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let id = try container.decode(String.self, forKey: .id)
            guard ReportContract.isValidIntersectionID(id) else {
                throw DecodingError.dataCorruptedError(forKey: .id, in: container, debugDescription: "invalid intersection ID")
            }
            self.id = id
            name = try? container.decodeIfPresent(String.self, forKey: .name)
            position = try? container.decodeIfPresent(String.self, forKey: .position)
            let items = try container.decodeIfPresent([Lossy<Plan>].self, forKey: .plans) ?? []
            plans = items.compactMap(\.value).filter(\.isValid)
        }

        /// The name from the Type 0 message (decoded with `PICSParser`), or `nil` when there is none
        /// or it is empty.
        public var decodedName: String? {
            guard let packet = Self.packet(name, id: id), let identifier = packet.identifier,
                  !identifier.isEmpty
            else { return nil }
            return identifier
        }

        /// The intersection's coordinate from the Type 1 message, or `nil`.
        public var coordinate: Coordinate? {
            Self.packet(position, id: id)?.coordinate
        }

        /// Slots that have at least one plan, ascending.
        public var slots: [Int] {
            Set(plans.map(\.slot)).sorted()
        }

        /// The valid plan of one cell.
        public func plan(slot: Int, dayType: DayType, bin: Int) -> Plan? {
            plans.first { $0.slot == slot && $0.dayType == dayType && $0.bin == bin && $0.isValid }
        }

        /// A raw message of this intersection, parsed.
        private static func packet(_ raw: String?, id: String) -> PICSPacket? {
            guard let raw, raw.hasPrefix("CE01"), let bytes = Hex.bytes(raw),
                  let packet = try? PICSParser.parse(manufacturerData: bytes),
                  packet.intersectionID == id
            else { return nil }
            return packet
        }
    }

    /// Where the phase of a plan is counted from.
    public enum Reference: String, Sendable, Hashable, Codable {
        /// The Unix epoch.
        case epoch
        /// Midnight (JST) of the day.
        case midnight
    }

    /// The fit of one cell: intersection × slot × day type × time bin.
    public struct Plan: Sendable, Hashable, Codable {
        /// 1…6.
        public var slot: Int
        public var dayType: DayType
        /// 0…47, the JST half hour.
        public var bin: Int
        /// Cycle in milliseconds (a multiple of 1000).
        public var cycle: Int
        public var reference: Reference
        /// When green starts, in milliseconds after the reference, modulo `cycle` (0 ≤ phase < cycle).
        public var phase: Int
        /// Spread of the daily phase, in milliseconds.
        public var spread: Int
        /// Median length of green, in milliseconds.
        public var green: Int?
        /// Median length of blinking green, in milliseconds.
        public var blink: Int?
        /// Days and report rows the fit used.
        public var days: Int
        public var reports: Int
        /// The last JST day with a start of green, `YYYY-MM-DD`.
        public var lastDay: String

        public init(
            slot: Int,
            dayType: DayType,
            bin: Int,
            cycle: Int,
            reference: Reference,
            phase: Int,
            spread: Int,
            green: Int? = nil,
            blink: Int? = nil,
            days: Int,
            reports: Int,
            lastDay: String
        ) {
            self.slot = slot
            self.dayType = dayType
            self.bin = bin
            self.cycle = cycle
            self.reference = reference
            self.phase = phase
            self.spread = spread
            self.green = green
            self.blink = blink
            self.days = days
            self.reports = reports
            self.lastDay = lastDay
        }

        /// `lastDay` as a date, or `nil` when it is not a valid `YYYY-MM-DD`.
        public var lastDate: JapanDate? { JapanDate(lastDay) }

        /// Whether the values are within what the server publishes: slot 1…6, bin 0…47, a cycle of
        /// 30…300 s, a phase inside the cycle, a spread of at most 3 s and a valid `lastDay`. Other
        /// plans are never used for an estimate.
        public var isValid: Bool {
            ReportContract.slots.contains(slot)
                && (0..<JapanCalendar.binsPerDay).contains(bin)
                && TimingEstimator.cycleRange.contains(cycle)
                && (0..<cycle).contains(phase)
                && (0...TimingEstimator.maximumSpread).contains(spread)
                && lastDate != nil
        }
    }
}

/// A `GET /v1/plans` response: the decoded plans and the body as received (for `TimingPlanCache`).
public struct TimingPlanDownload: Sendable, Hashable {
    public var plans: TimingPlans
    public var body: Data

    public init(plans: TimingPlans, body: Data) {
        self.plans = plans
        self.body = body
    }
}

/// Decodes one element of a list, or gives `nil` when that element cannot be decoded, so that the
/// other elements are still read.
private struct Lossy<Value: Decodable>: Decodable {
    var value: Value?

    init(from decoder: any Decoder) throws {
        value = try? decoder.singleValueContainer().decode(Value.self)
    }
}
