// SPDX-License-Identifier: Apache-2.0
//
// Byte offsets and signal encodings are ported from process_pics() in ble-pics-viewer.py and
// processPics() in web/pics.mjs of yumu19/ble-pics-viewer
// (MIT License, Copyright (c) 2025 Tsubasa Yumura). See THIRD_PARTY_NOTICES.md.

import Foundation

/// Constants shared with ble-pics-viewer's Web version.
public enum PICS {
    /// Bluetooth SIG company identifier carried in the manufacturer data (0x01CE).
    public static let companyID: UInt16 = 0x01CE
    /// The company identifier as it appears on the air and on iOS: little-endian `CE 01`.
    public static let companyIDBytes: [UInt8] = [0xCE, 0x01]
    /// Signal data at least this old is shown as "更新なし" (`STALE_AFTER_MS`).
    public static let staleInterval: TimeInterval = 5
    /// History window (`HISTORY_WINDOW_MS`).
    public static let historyWindow: TimeInterval = 30
    /// Maximum history entries kept per intersection.
    public static let historyLimit = 5
    /// Type 2 carries at most six pedestrian signals.
    public static let maximumSignals = 6
}

/// Pedestrian signal state: the low four bits of each Type 2 signal byte.
public enum SignalState: String, Sendable, Hashable, Codable, CaseIterable {
    case noSignal = "NoSignal"
    case red = "Red"
    case blinkGreen = "BlinkGreen"
    case green = "Green"
    /// 4: this slot is not used at the intersection ("対象なし").
    case none = "None"
    case unknown = "Unknown"

    public init(nibble: UInt8) {
        switch nibble & 0x0F {
        case 0: self = .noSignal
        case 1: self = .red
        case 2: self = .blinkGreen
        case 3: self = .green
        case 4: self = .none
        default: self = .unknown
        }
    }

    /// Japanese label used by ble-pics-viewer (`SIGNAL_LABELS`).
    public var viewerLabel: String {
        switch self {
        case .noSignal: "信号なし"
        case .red: "赤"
        case .blinkGreen: "青点滅"
        case .green: "青"
        case .none: "対象なし"
        case .unknown: "不明"
        }
    }

    /// Whether the slot carries a pedestrian signal at all.
    public var isInUse: Bool { self != .none }
}

/// One pedestrian signal from a Type 2 message.
public struct PedestrianSignal: Sendable, Hashable {
    /// Remaining-time indication 1...8 ("残り目安"), or `nil` when unknown.
    /// This is **not** a number of seconds.
    public var remaining: Int?
    public var state: SignalState

    public init(remaining: Int?, state: SignalState) {
        self.remaining = remaining
        self.state = state
    }

    /// Decodes one signal byte: high nibble 0–7 → remaining 1–8, 8 or more → unknown.
    public init(byte: UInt8) {
        let high = Int(byte >> 4)
        self.remaining = high >= 8 ? nil : high + 1
        self.state = SignalState(nibble: byte)
    }
}

extension PedestrianSignal: Codable {
    // Same JSON shape as ble-pics-viewer: unknown remaining time is -1.
    private enum CodingKeys: String, CodingKey {
        case remaining = "remaining_time"
        case state = "signal_state"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let value = try container.decode(Int.self, forKey: .remaining)
        self.remaining = value < 0 ? nil : value
        self.state = try container.decode(SignalState.self, forKey: .state)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(remaining ?? -1, forKey: .remaining)
        try container.encode(state, forKey: .state)
    }
}

/// WGS 84 coordinate in degrees.
public struct Coordinate: Sendable, Hashable, Codable {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }
}

/// A decoded 高度化PICS advertisement.
public struct PICSPacket: Sendable, Hashable {
    public enum Content: Sendable, Hashable {
        /// Type 0: intersection identifier (UTF-8, at most 14 bytes).
        case identifier(String)
        /// Type 1: position (signed 32-bit big-endian, divided by 1,000,000).
        case position(Coordinate)
        /// Type 2: up to six pedestrian signals.
        case signals([PedestrianSignal])
        /// Any other message type: only the common header is known.
        case unknown
    }

    public var messageType: UInt8
    public var messageID: UInt8
    /// Bytes 6..<10 as eight uppercase hexadecimal digits.
    public var intersectionID: String
    public var content: Content

    public init(messageType: UInt8, messageID: UInt8, intersectionID: String, content: Content) {
        self.messageType = messageType
        self.messageID = messageID
        self.intersectionID = intersectionID
        self.content = content
    }

    public var identifier: String? {
        if case .identifier(let value) = content { return value }
        return nil
    }

    public var coordinate: Coordinate? {
        if case .position(let value) = content { return value }
        return nil
    }

    public var signals: [PedestrianSignal]? {
        if case .signals(let value) = content { return value }
        return nil
    }
}

extension PICSPacket: Encodable {
    // Same keys as processPics() so the developer view matches ble-pics-viewer's JSON.
    private enum CodingKeys: String, CodingKey {
        case messageType = "message_type"
        case messageID = "message_id"
        case intersectionID = "intersection_id"
        case identifier
        case latitude
        case longitude
        case pedestrianSignals = "pedestrian_signals"
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(messageType, forKey: .messageType)
        try container.encode(messageID, forKey: .messageID)
        try container.encode(intersectionID, forKey: .intersectionID)
        switch content {
        case .identifier(let value):
            try container.encode(value, forKey: .identifier)
        case .position(let value):
            try container.encode(value.latitude, forKey: .latitude)
            try container.encode(value.longitude, forKey: .longitude)
        case .signals(let value):
            try container.encode(value, forKey: .pedestrianSignals)
        case .unknown:
            break
        }
    }

    /// Pretty-printed JSON with sorted keys, for the developer view.
    public func prettyJSON() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}

public enum PICSParseError: Error, Sendable, Hashable {
    /// The common header needs at least 10 bytes.
    case headerTooShort(length: Int)
    /// A known message type is shorter than its minimum length.
    case messageTooShort(type: UInt8, length: Int, minimum: Int)
    /// Manufacturer data that does not start with company identifier 0x01CE.
    case notPICS(companyID: UInt16?)
}

public enum PICSParser {
    public static let headerLength = 10

    /// Minimum payload length per message type, as validated by pics.mjs.
    public static func minimumLength(forType type: UInt8) -> Int {
        switch type {
        case 0: 24
        case 1: 18
        case 2: 11
        default: headerLength
        }
    }

    /// Parses the manufacturer-specific payload **without** the two company identifier bytes.
    /// This is the shape Bleak and Web Bluetooth deliver, so offsets match ble-pics-viewer.
    public static func parse<Bytes: Sequence>(payload: Bytes) throws(PICSParseError) -> PICSPacket
    where Bytes.Element == UInt8 {
        // Copy into an array so slices of `Data` with a non-zero start index decode the same way.
        let bytes = Array(payload)
        guard bytes.count >= headerLength else {
            throw .headerTooShort(length: bytes.count)
        }
        let type = bytes[2]
        let minimum = minimumLength(forType: type)
        guard bytes.count >= minimum else {
            throw .messageTooShort(type: type, length: bytes.count, minimum: minimum)
        }

        let content: PICSPacket.Content
        switch type {
        case 0:
            content = .identifier(decodeIdentifier(bytes[10..<24]))
        case 1:
            content = .position(Coordinate(
                latitude: Double(int32BigEndian(bytes, at: 10)) / 1_000_000,
                longitude: Double(int32BigEndian(bytes, at: 14)) / 1_000_000
            ))
        case 2:
            let end = min(bytes.count, 10 + PICS.maximumSignals)
            content = .signals(bytes[10..<end].map(PedestrianSignal.init(byte:)))
        default:
            content = .unknown
        }

        return PICSPacket(
            messageType: type,
            messageID: bytes[3],
            intersectionID: Hex.string(bytes[6..<10], separator: ""),
            content: content
        )
    }

    /// Parses `CBAdvertisementDataManufacturerDataKey` as delivered by iOS: the first two bytes are
    /// the little-endian company identifier (`CE 01`), followed by the PICS payload.
    public static func parse<Bytes: Sequence>(manufacturerData: Bytes) throws(PICSParseError) -> PICSPacket
    where Bytes.Element == UInt8 {
        let bytes = Array(manufacturerData)
        let company = companyID(ofManufacturerData: bytes)
        guard company == PICS.companyID else {
            throw .notPICS(companyID: company)
        }
        return try parse(payload: bytes.dropFirst(2))
    }

    /// The little-endian company identifier at the start of manufacturer data, if present.
    public static func companyID<Bytes: Sequence>(ofManufacturerData data: Bytes) -> UInt16?
    where Bytes.Element == UInt8 {
        var iterator = data.makeIterator()
        guard let low = iterator.next(), let high = iterator.next() else { return nil }
        return UInt16(low) | UInt16(high) << 8
    }

    /// Mirrors `TextDecoder().decode(...)` followed by removing U+FFFD and trimming NUL characters
    /// at both ends, as pics.mjs does.
    static func decodeIdentifier(_ slice: ArraySlice<UInt8>) -> String {
        var bytes = Array(slice)
        // TextDecoder (UTF-8, ignoreBOM: false) consumes a leading byte order mark.
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            bytes.removeFirst(3)
        }
        var scalars = String(decoding: bytes, as: UTF8.self).unicodeScalars.filter { $0 != "\u{FFFD}" }
        while scalars.first == "\0" { scalars.removeFirst() }
        while scalars.last == "\0" { scalars.removeLast() }
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars)
        return String(view)
    }

    static func int32BigEndian(_ bytes: [UInt8], at offset: Int) -> Int32 {
        let value = UInt32(bytes[offset]) << 24
            | UInt32(bytes[offset + 1]) << 16
            | UInt32(bytes[offset + 2]) << 8
            | UInt32(bytes[offset + 3])
        return Int32(bitPattern: value)
    }
}
