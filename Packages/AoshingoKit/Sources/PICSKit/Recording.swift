// SPDX-License-Identifier: Apache-2.0

import Foundation

/// One received advertisement as stored in a developer recording (JSON Lines, one object per line).
///
/// Recordings stay on the device unless the user shares the file. They contain no location and
/// replace the per-phone peripheral identifier with a short alias (`E1`, `E2`, …).
public struct RecordedAdvertisement: Sendable, Hashable, Codable {
    /// Seconds since 1970-01-01 UTC, millisecond precision.
    public var t: Double
    /// Manufacturer data exactly as iOS delivered it (company identifier included), uppercase hex.
    public var manufacturerData: String
    public var rssi: Int?
    public var serviceUUIDs: [String]?
    public var localName: String?
    public var txPower: Int?
    public var connectable: Bool?
    /// Alias of the transmitter within this recording.
    public var emitter: String?

    public init(
        timestamp: Date,
        manufacturerData: [UInt8],
        metadata: AdvertisementMetadata = AdvertisementMetadata()
    ) {
        self.t = (timestamp.timeIntervalSince1970 * 1000).rounded() / 1000
        self.manufacturerData = Hex.string(manufacturerData, separator: "")
        self.rssi = metadata.rssi
        self.serviceUUIDs = metadata.serviceUUIDs.isEmpty ? nil : metadata.serviceUUIDs
        self.localName = metadata.localName
        self.txPower = metadata.txPower
        self.connectable = metadata.isConnectable
        self.emitter = metadata.emitter
    }

    public var timestamp: Date { Date(timeIntervalSince1970: t) }

    public var bytes: [UInt8]? { Hex.bytes(manufacturerData) }

    public var metadata: AdvertisementMetadata {
        AdvertisementMetadata(
            rssi: rssi,
            serviceUUIDs: serviceUUIDs ?? [],
            emitter: emitter,
            localName: localName,
            txPower: txPower,
            isConnectable: connectable
        )
    }
}

/// Reads and writes JSON Lines recordings.
public enum RecordingFormat {
    public static let fileExtension = "jsonl"

    public static func encodeLine(_ record: RecordedAdvertisement) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(record)
        data.append(0x0A)
        return data
    }

    /// Decodes every non-empty line. Lines that fail to decode are counted, not fatal.
    public static func decode(_ data: Data) -> (records: [RecordedAdvertisement], invalidLines: Int) {
        let decoder = JSONDecoder()
        var records: [RecordedAdvertisement] = []
        var invalid = 0
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            let trimmed = line.drop { $0 == 0x20 || $0 == 0x0D }
            guard !trimmed.isEmpty else { continue }
            if let record = try? decoder.decode(RecordedAdvertisement.self, from: Data(line)) {
                records.append(record)
            } else {
                invalid += 1
            }
        }
        return (records, invalid)
    }
}

/// Assigns short, recording-local aliases to transmitter identifiers.
public struct EmitterAliases: Sendable {
    private var aliases: [String: String] = [:]

    public init() {}

    public mutating func alias(for identifier: String) -> String {
        if let existing = aliases[identifier] { return existing }
        let alias = "E\(aliases.count + 1)"
        aliases[identifier] = alias
        return alias
    }

    public mutating func reset() { aliases.removeAll() }
}
