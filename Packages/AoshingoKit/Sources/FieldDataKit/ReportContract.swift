// SPDX-License-Identifier: Apache-2.0

import Foundation
import PICSKit

/// The server's rules for `POST /v1/reports` (docs/field-data-api.md, server/src/report.ts).
///
/// The server rejects a whole report for a single bad value, and a rejected report is dropped, so
/// reports are brought into line before they are queued: invalid observations and transitions are
/// dropped, invalid optional values become `null`, and reports are split so that every body has at
/// most 50 intersections, unique intersection IDs, at most 600 observations and 300 transitions per
/// intersection and at most 256 KiB.
public enum ReportContract {
    public static let maximumBodyBytes = 256 * 1024
    public static let maximumIntersections = 50
    public static let maximumServiceUUIDs = 8
    public static let maximumEmitters = 32
    public static let maximumObservations = 600
    public static let maximumTransitions = 300
    public static let maximumClientLength = 40
    /// Length of `raw` in hexadecimal digits.
    public static let rawLength = 24...128
    public static let slots = 1...6
    /// The server accepts `t` at most this far ahead of its clock.
    public static let maximumFutureSkew: TimeInterval = 300
    /// The server accepts `t` up to seven days old at upload time and queued reports are deleted
    /// after six days, so observations more than one day older than their report are dropped.
    public static let maximumAgeWhenQueued: TimeInterval = 7 * 24 * 60 * 60 - FieldDataPipeline.maximumReportAge

    /// JSON bodies for `report` that the server accepts, in the original order. Empty when nothing
    /// valid is left.
    public static func encode(_ report: FieldReport, now: Date) -> [Data] {
        let client = report.client.flatMap { isValidClient($0) ? $0 : nil }
        let times = timeRange(now: now)
        let intersections = report.intersections.compactMap { sanitized($0, times: times) }
        return pack(intersections, client: client).compactMap { report in
            guard let body = try? report.encoded(), body.count <= maximumBodyBytes else { return nil }
            return body
        }
    }

    // MARK: - Field rules

    /// Whether manufacturer data may be uploaded as `raw`: a length the server accepts and a PICS
    /// message type this app can decode (the server rejects unknown types).
    public static func isUploadable(_ packet: PICSPacket, manufacturerData: [UInt8]) -> Bool {
        guard rawLength.contains(manufacturerData.count * 2),
              manufacturerData.starts(with: PICS.companyIDBytes)
        else { return false }
        if case .unknown = packet.content { return false }
        return true
    }

    /// `raw` as the server checks it, plus: it parses as a PICS packet of a known type for `intersectionID`.
    public static func isValidRaw(_ raw: String, intersectionID: String) -> Bool {
        guard rawLength.contains(raw.utf8.count), raw.utf8.count.isMultiple(of: 2), raw.hasPrefix("CE01"),
              raw.utf8.allSatisfy(isUppercaseHexDigit),
              let bytes = Hex.bytes(raw),
              let packet = try? PICSParser.parse(manufacturerData: bytes),
              packet.intersectionID == intersectionID
        else { return false }
        return isUploadable(packet, manufacturerData: bytes)
    }

    public static func isValidIntersectionID(_ id: String) -> Bool {
        id.utf8.count == 8 && id.utf8.allSatisfy(isUppercaseHexDigit)
    }

    /// `^aoshingo-[a-z]+/[0-9A-Za-z.+-]+$`, at most 40 characters.
    public static func isValidClient(_ client: String) -> Bool {
        let bytes = Array(client.utf8)
        let prefix = Array("aoshingo-".utf8)
        guard bytes.count <= maximumClientLength, bytes.starts(with: prefix),
              let slash = bytes.firstIndex(of: UInt8(ascii: "/"))
        else { return false }
        let platform = bytes[prefix.count..<slash]
        let version = bytes[(slash + 1)...]
        return !platform.isEmpty && platform.allSatisfy { (UInt8(ascii: "a")...UInt8(ascii: "z")).contains($0) }
            && !version.isEmpty && version.allSatisfy(isVersionCharacter)
    }

    static func timeRange(now: Date) -> ClosedRange<Int> {
        let seconds = Bucketing.seconds(now)
        return (seconds - Int(maximumAgeWhenQueued))...(seconds + Int(maximumFutureSkew))
    }

    static func sanitized(_ intersection: FieldReport.Intersection, times: ClosedRange<Int>) -> FieldReport.Intersection? {
        guard isValidIntersectionID(intersection.id) else { return nil }
        var serviceUUIDs: [String] = []
        for uuid in intersection.serviceUUIDs.compactMap(Bucketing.serviceUUID) where !serviceUUIDs.contains(uuid) {
            serviceUUIDs.append(uuid)
        }
        let observations = intersection.observations.compactMap { observation -> FieldReport.Observation? in
            guard times.contains(observation.t),
                  isValidRaw(observation.raw, intersectionID: intersection.id)
            else { return nil }
            var observation = observation
            if let rssi = observation.rssi, !((-130...0).contains(rssi) && rssi.isMultiple(of: 5)) { observation.rssi = nil }
            if let bearing = observation.bearing, !(0...7).contains(bearing) { observation.bearing = nil }
            if let heading = observation.heading, !(0...7).contains(heading) { observation.heading = nil }
            return observation
        }
        let transitions = intersection.transitions.filter {
            times.contains($0.t) && slots.contains($0.slot) && $0.from != $0.to
        }
        guard !observations.isEmpty || !transitions.isEmpty else { return nil }
        return FieldReport.Intersection(
            id: intersection.id,
            serviceUUIDs: Array(serviceUUIDs.prefix(maximumServiceUUIDs)),
            emitters: min(max(intersection.emitters, 0), maximumEmitters),
            observations: observations,
            transitions: transitions
        )
    }

    // MARK: - Splitting

    /// Packs intersections into as few reports as the limits allow, keeping their order.
    static func pack(_ intersections: [FieldReport.Intersection], client: String?) -> [FieldReport] {
        let envelope = encodedSize(FieldReport(client: client, intersections: []))
        // Bytes left for the contents of the `intersections` array.
        let budget = maximumBodyBytes - envelope
        var reports: [FieldReport] = []
        var current: [FieldReport.Intersection] = []
        var used = 0
        var ids: Set<String> = []
        for piece in intersections.flatMap({ pieces(of: $0, budget: budget) }) {
            let size = encodedSize(piece)
            if current.count == maximumIntersections || ids.contains(piece.id)
                || used + size + (current.isEmpty ? 0 : 1) > budget {
                if !current.isEmpty { reports.append(FieldReport(client: client, intersections: current)) }
                current = []
                used = 0
                ids = []
            }
            used += size + (current.isEmpty ? 0 : 1) // A comma separates array elements.
            current.append(piece)
            ids.insert(piece.id)
        }
        if !current.isEmpty { reports.append(FieldReport(client: client, intersections: current)) }
        return reports
    }

    /// Splits one intersection into entries within the per-intersection list limits and `budget` bytes.
    static func pieces(of intersection: FieldReport.Intersection, budget: Int) -> [FieldReport.Intersection] {
        let observations = intersection.observations
        let transitions = intersection.transitions
        if observations.count <= maximumObservations, transitions.count <= maximumTransitions,
           encodedSize(intersection) <= budget {
            return [intersection]
        }
        guard observations.count + transitions.count > 1 else { return [] } // A single entry that cannot fit.
        var first = intersection
        var second = intersection
        let observationSplit = observations.count / 2
        let transitionSplit = transitions.count / 2
        if observationSplit == 0, transitionSplit == 0 {
            // One observation and one transition.
            first.transitions = []
            second.observations = []
        } else {
            first.observations = Array(observations[..<observationSplit])
            first.transitions = Array(transitions[..<transitionSplit])
            second.observations = Array(observations[observationSplit...])
            second.transitions = Array(transitions[transitionSplit...])
        }
        return [first, second]
            .filter { !($0.observations.isEmpty && $0.transitions.isEmpty) }
            .flatMap { pieces(of: $0, budget: budget) }
    }

    static func encodedSize(_ value: some Encodable) -> Int {
        (try? FieldReport.makeEncoder().encode(value).count) ?? .max
    }

    private static func isUppercaseHexDigit(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) || (UInt8(ascii: "A")...UInt8(ascii: "F")).contains(byte)
    }

    private static func isVersionCharacter(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
            || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
            || (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
            || byte == UInt8(ascii: ".") || byte == UInt8(ascii: "+") || byte == UInt8(ascii: "-")
    }
}
