// SPDX-License-Identifier: Apache-2.0

import Foundation
import PICSKit

/// The server's rules for `POST /v1/reports` (docs/field-data-api.md, server/src/report.ts).
///
/// The server rejects a whole report for a single bad value, and a rejected report is dropped, so
/// reports are brought into line before they are queued (schema 4):
///
/// - Invalid observations, transitions, steps, packet statistics, coverage periods and labels are
///   dropped; invalid optional values become `null`, including emitter numbers outside
///   `0..<emitters`. `emitterInfo` is cut or padded with `null`s to `emitters` entries.
/// - An intersection without any observation, transition, step or label is dropped.
/// - `packets`, `coverage` and `labels` are cut to 96, 60 and 20 entries. Reports are split so that
///   every body has at most 50 intersections, unique intersection IDs, at most 600 observations,
///   300 transitions and 600 steps per intersection and at most 256 KiB. A split intersection repeats
///   `emitterInfo` in every piece and carries `packets`, `coverage` and `labels` in the first only.
/// - Bodies leave `sentAtAllowance` bytes of the 256 KiB free for the `sentAt` that `ReportUploader`
///   adds to every attempt, and never contain `sentAt` themselves.
public enum ReportContract {
    public static let maximumBodyBytes = 256 * 1024
    /// Room kept free in every queued body for `"sentAt":<Unix milliseconds>,`, which the uploader
    /// inserts before each `POST` (9 bytes for the key and colon, up to 20 for the number, 1 comma).
    public static let sentAtAllowance = 30
    /// The largest queued body: `maximumBodyBytes` less `sentAtAllowance`.
    public static var maximumQueuedBodyBytes: Int { maximumBodyBytes - sentAtAllowance }
    public static let maximumIntersections = 50
    public static let maximumServiceUUIDs = 8
    public static let maximumEmitters = 32
    public static let maximumObservations = 600
    public static let maximumTransitions = 300
    public static let maximumSteps = 600
    public static let maximumPackets = 96
    public static let maximumCoverage = 60
    public static let maximumLabels = 20
    public static let maximumPacketCount = 100_000
    /// The longest transition `gap`, in milliseconds.
    public static let maximumGap = 5000
    public static let maximumClientLength = 40
    /// Length of `raw` in hexadecimal digits.
    public static let rawLength = 24...128
    public static let slots = 1...6
    /// Remaining-time indications ("残り目安") in steps.
    public static let remainingRange = 1...8
    /// PICS message types the server accepts.
    public static let messageTypes = 0...2
    /// The server accepts `t` at most this far ahead of its clock.
    public static let maximumFutureSkew: TimeInterval = 300
    /// The server accepts times (`t`, `start`, `end`) up to seven days old at upload time and queued
    /// reports are deleted after six days, so entries more than one day older than their report are dropped.
    public static let maximumAgeWhenQueued: TimeInterval = 7 * 24 * 60 * 60 - FieldDataPipeline.maximumReportAge

    /// JSON bodies for `report` that the server accepts, in the original order. Empty when nothing
    /// valid is left.
    public static func encode(_ report: FieldReport, now: Date) -> [Data] {
        let client = report.client.flatMap { isValidClient($0) ? $0 : nil }
        let times = timeRange(now: now)
        let intersections = report.intersections.compactMap { sanitized($0, times: times) }
        return pack(intersections, client: client).compactMap { report in
            guard let body = try? report.encoded(), body.count <= maximumQueuedBodyBytes else { return nil }
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
        let emitters = min(max(intersection.emitters, 0), maximumEmitters)
        func emitter(_ value: Int?) -> Int? { value.flatMap { (0..<emitters).contains($0) ? $0 : nil } }

        var emitterInfo = intersection.emitterInfo.prefix(emitters).map { info in
            FieldReport.EmitterInfo(txPower: Bucketing.txPower(info.txPower), connectable: info.connectable)
        }
        emitterInfo += Array(repeating: FieldReport.EmitterInfo(), count: emitters - emitterInfo.count)

        let observations = intersection.observations.compactMap { observation -> FieldReport.Observation? in
            guard times.contains(observation.t),
                  isValidRaw(observation.raw, intersectionID: intersection.id)
            else { return nil }
            var observation = observation
            if let rssi = observation.rssi, !((-130...0).contains(rssi) && rssi.isMultiple(of: 5)) { observation.rssi = nil }
            observation.bearing = sector(observation.bearing)
            observation.heading = sector(observation.heading)
            observation.emitter = emitter(observation.emitter)
            observation.distance = member(observation.distance, of: Bucketing.distanceRings)
            observation.accuracy = member(observation.accuracy, of: Bucketing.accuracyClasses)
            observation.course = sector(observation.course)
            observation.speed = observation.speed.flatMap { Bucketing.speedClasses.contains($0) ? $0 : nil }
            observation.nearby = member(observation.nearby, of: Bucketing.nearbyClasses)
            return observation
        }
        let transitions = intersection.transitions.compactMap { transition -> FieldReport.Transition? in
            guard times.contains(transition.t), slots.contains(transition.slot), transition.from != transition.to else { return nil }
            var transition = transition
            transition.ms = multiple(transition.ms, of: 100, upTo: Bucketing.maximumSubsecond)
            transition.emitter = emitter(transition.emitter)
            transition.gap = multiple(transition.gap, of: 100, upTo: maximumGap)
            transition.held = multiple(transition.held, of: 100, upTo: Bucketing.maximumDuration)
            transition.cycle = multiple(transition.cycle, of: 100, upTo: Bucketing.maximumDuration)
            return transition
        }
        let steps = intersection.steps.compactMap { step -> FieldReport.Step? in
            var step = step
            step.from = step.from.flatMap { remainingRange.contains($0) ? $0 : nil }
            step.to = step.to.flatMap { remainingRange.contains($0) ? $0 : nil }
            guard times.contains(step.t), slots.contains(step.slot), step.from != step.to else { return nil }
            step.ms = multiple(step.ms, of: 100, upTo: Bucketing.maximumSubsecond)
            step.emitter = emitter(step.emitter)
            step.held = multiple(step.held, of: 100, upTo: Bucketing.maximumDuration)
            return step
        }
        var packetKeys: Set<[Int]> = []
        let packets = intersection.packets.compactMap { stats -> FieldReport.PacketStats? in
            guard (0..<emitters).contains(stats.emitter), messageTypes.contains(stats.type),
                  (1...maximumPacketCount).contains(stats.count),
                  packetKeys.insert([stats.emitter, stats.type]).inserted
            else { return nil }
            var stats = stats
            stats.minInterval = multiple(stats.minInterval, of: 10, upTo: Bucketing.maximumInterval)
            stats.medianInterval = multiple(stats.medianInterval, of: 10, upTo: Bucketing.maximumInterval)
            if stats.count == 1 {
                stats.minInterval = nil
                stats.medianInterval = nil
            } else if let minimum = stats.minInterval, let median = stats.medianInterval, minimum > median {
                stats.minInterval = nil
                stats.medianInterval = nil
            }
            return stats
        }
        let coverage = intersection.coverage.filter { times.contains($0.start) && times.contains($0.end) && $0.start <= $0.end }
        let labels = intersection.labels.compactMap { label -> FieldReport.Label? in
            var label = label
            label.slot = label.slot.flatMap { slots.contains($0) ? $0 : nil }
            guard times.contains(label.t), label.kind != .crosswalk || label.slot != nil else { return nil }
            label.heading = sector(label.heading)
            label.bearing = sector(label.bearing)
            label.distance = member(label.distance, of: Bucketing.distanceRings)
            return label
        }
        guard !(observations.isEmpty && transitions.isEmpty && steps.isEmpty && labels.isEmpty) else { return nil }
        return FieldReport.Intersection(
            id: intersection.id,
            serviceUUIDs: Array(serviceUUIDs.prefix(maximumServiceUUIDs)),
            emitters: emitters,
            emitterInfo: emitterInfo,
            observations: observations,
            transitions: transitions,
            steps: steps,
            // These are not split across reports (they go into the first piece only), so they are cut to their limits.
            packets: Array(packets.prefix(maximumPackets)),
            coverage: Array(coverage.prefix(maximumCoverage)),
            labels: Array(labels.prefix(maximumLabels))
        )
    }

    private static func sector(_ value: Int?) -> Int? {
        value.flatMap { (0...7).contains($0) ? $0 : nil }
    }

    private static func member(_ value: Int?, of allowed: [Int]) -> Int? {
        value.flatMap { allowed.contains($0) ? $0 : nil }
    }

    private static func multiple(_ value: Int?, of step: Int, upTo maximum: Int) -> Int? {
        value.flatMap { (0...maximum).contains($0) && $0.isMultiple(of: step) ? $0 : nil }
    }

    // MARK: - Splitting

    /// Packs intersections into as few reports as the limits allow, keeping their order.
    static func pack(_ intersections: [FieldReport.Intersection], client: String?) -> [FieldReport] {
        let envelope = encodedSize(FieldReport(client: client, intersections: []))
        // Bytes left for the contents of the `intersections` array.
        let budget = maximumQueuedBodyBytes - envelope
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
    /// Observations, transitions and steps are divided; every piece repeats `emitterInfo` (so emitter
    /// numbers stay valid), and `packets`, `coverage` and `labels` stay in the first piece only.
    static func pieces(of intersection: FieldReport.Intersection, budget: Int) -> [FieldReport.Intersection] {
        let observations = intersection.observations
        let transitions = intersection.transitions
        let steps = intersection.steps
        if observations.count <= maximumObservations, transitions.count <= maximumTransitions,
           steps.count <= maximumSteps, encodedSize(intersection) <= budget {
            return [intersection]
        }
        // A single entry that cannot fit.
        guard observations.count + transitions.count + steps.count > 1 else { return [] }
        var first = intersection
        var second = intersection
        second.packets = []
        second.coverage = []
        second.labels = []
        let observationSplit = observations.count / 2
        let transitionSplit = transitions.count / 2
        let stepSplit = steps.count / 2
        if observationSplit == 0, transitionSplit == 0, stepSplit == 0 {
            // At most one entry of each kind, and at least two in all: the first piece takes one.
            if !observations.isEmpty {
                first.transitions = []
                first.steps = []
                second.observations = []
            } else {
                first.steps = []
                second.transitions = []
            }
        } else {
            first.observations = Array(observations[..<observationSplit])
            first.transitions = Array(transitions[..<transitionSplit])
            first.steps = Array(steps[..<stepSplit])
            second.observations = Array(observations[observationSplit...])
            second.transitions = Array(transitions[transitionSplit...])
            second.steps = Array(steps[stepSplit...])
        }
        return [first, second]
            .filter { !($0.observations.isEmpty && $0.transitions.isEmpty && $0.steps.isEmpty && $0.labels.isEmpty) }
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
