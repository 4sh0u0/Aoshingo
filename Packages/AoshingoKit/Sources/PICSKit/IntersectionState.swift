// SPDX-License-Identifier: Apache-2.0
//
// The per-intersection state follows updateIntersection() and recentHistory() in web/pics.mjs of
// yumu19/ble-pics-viewer (MIT License, Copyright (c) 2025 Tsubasa Yumura).

import Foundation

/// Extra facts about one received advertisement, beyond the PICS payload.
public struct AdvertisementMetadata: Sendable, Hashable {
    /// RSSI in dBm. iOS reports 127 when unavailable; that value is ignored.
    public var rssi: Int?
    /// Service UUIDs advertised alongside the manufacturer data, uppercase.
    /// Whether these exist decides if background scanning can ever work.
    public var serviceUUIDs: [String]
    /// A local alias for the transmitter, used to count transmitters per intersection.
    public var emitter: String?
    public var localName: String?
    public var txPower: Int?
    public var isConnectable: Bool?

    public init(
        rssi: Int? = nil,
        serviceUUIDs: [String] = [],
        emitter: String? = nil,
        localName: String? = nil,
        txPower: Int? = nil,
        isConnectable: Bool? = nil
    ) {
        self.rssi = rssi
        self.serviceUUIDs = serviceUUIDs
        self.emitter = emitter
        self.localName = localName
        self.txPower = txPower
        self.isConnectable = isConnectable
    }

    /// The RSSI if it is a real measurement.
    public var validRSSI: Int? {
        guard let rssi, rssi < 0, rssi > -128 else { return nil }
        return rssi
    }
}

/// One Type 2 reception kept in the short history.
public struct SignalHistoryEntry: Sendable, Hashable {
    public var timestamp: Date
    public var signals: [PedestrianSignal]

    public init(timestamp: Date, signals: [PedestrianSignal]) {
        self.timestamp = timestamp
        self.signals = signals
    }
}

/// Reception statistics for one message type, used to answer the field-test questions
/// (advertising interval, rotation of Type 0/1/2).
public struct MessageTypeStatistics: Sendable, Hashable {
    public private(set) var count = 0
    public private(set) var lastTimestamp: Date?
    public private(set) var lastRaw: [UInt8] = []
    public private(set) var shortestInterval: TimeInterval?
    public private(set) var meanInterval: TimeInterval?

    public init() {}

    mutating func record(raw: [UInt8], at timestamp: Date) {
        if let lastTimestamp {
            let interval = timestamp.timeIntervalSince(lastTimestamp)
            if interval >= 0 {
                shortestInterval = min(shortestInterval ?? interval, interval)
                let samples = Double(count - 1)
                meanInterval = ((meanInterval ?? 0) * samples + interval) / (samples + 1)
            }
        }
        count += 1
        lastTimestamp = timestamp
        lastRaw = raw
    }
}

/// Everything known about one intersection, keyed by its intersection ID.
public struct IntersectionState: Sendable, Hashable, Identifiable {
    /// Weight of the newest RSSI sample in the exponential moving average.
    public static let rssiSmoothing = 0.3

    public let id: String
    /// Type 0 name.
    public internal(set) var identifier: String?
    /// Type 1 position.
    public internal(set) var coordinate: Coordinate?
    /// Last Type 2 signals. Type 0/1 receptions keep them.
    public internal(set) var signals: [PedestrianSignal]?
    /// When the last Type 2 arrived.
    public internal(set) var signalTimestamp: Date?
    /// When any packet last arrived.
    public internal(set) var timestamp: Date
    /// The latest packet of any type.
    public internal(set) var latest: PICSPacket
    /// Copy of the latest raw bytes, so later changes to a receive buffer cannot alter the state.
    public internal(set) var raw: [UInt8]
    /// Type 2 receptions within the last 30 seconds, at most five.
    public internal(set) var history: [SignalHistoryEntry]
    /// Number of packets received.
    public internal(set) var count: Int
    public internal(set) var rssi: Int?
    public internal(set) var smoothedRSSI: Double?
    public internal(set) var serviceUUIDs: Set<String>
    public internal(set) var emitters: Set<String>
    public internal(set) var localNames: Set<String>
    public internal(set) var messageTypes: [UInt8: MessageTypeStatistics]

    /// Applies one packet to the previous state (or creates it), like `updateIntersection()`.
    public static func updated(
        _ previous: IntersectionState?,
        with packet: PICSPacket,
        raw: [UInt8],
        at timestamp: Date,
        metadata: AdvertisementMetadata = AdvertisementMetadata()
    ) -> IntersectionState {
        var state = previous ?? IntersectionState(id: packet.intersectionID, packet: packet, timestamp: timestamp)
        switch packet.content {
        case .identifier(let value): state.identifier = value
        case .position(let value): state.coordinate = value
        case .signals: break
        case .unknown: break
        }
        state.timestamp = timestamp
        state.raw = raw
        state.latest = packet
        state.history = recentHistory(state.history, now: timestamp)
        state.count += 1

        if let signals = packet.signals {
            state.signals = signals
            state.signalTimestamp = timestamp
            state.history = recentHistory(
                state.history + [SignalHistoryEntry(timestamp: timestamp, signals: signals)],
                now: timestamp
            )
        }

        if let rssi = metadata.validRSSI {
            state.rssi = rssi
            let sample = Double(rssi)
            state.smoothedRSSI = state.smoothedRSSI.map {
                $0 + rssiSmoothing * (sample - $0)
            } ?? sample
        }
        state.serviceUUIDs.formUnion(metadata.serviceUUIDs.map { $0.uppercased() })
        if let emitter = metadata.emitter { state.emitters.insert(emitter) }
        if let name = metadata.localName, !name.isEmpty { state.localNames.insert(name) }
        state.messageTypes[packet.messageType, default: MessageTypeStatistics()].record(raw: raw, at: timestamp)
        return state
    }

    private init(id: String, packet: PICSPacket, timestamp: Date) {
        self.id = id
        self.timestamp = timestamp
        self.latest = packet
        self.raw = []
        self.history = []
        self.count = 0
        self.serviceUUIDs = []
        self.emitters = []
        self.localNames = []
        self.messageTypes = [:]
    }

    /// Seconds since the last Type 2, or `nil` if none has arrived.
    public func signalAge(at now: Date) -> TimeInterval? {
        signalTimestamp.map { max(0, now.timeIntervalSince($0)) }
    }

    /// `true` when no Type 2 has arrived for `PICS.staleInterval` seconds (or never).
    /// A stale state must not be announced as a current light.
    public func isSignalStale(at now: Date) -> Bool {
        guard let age = signalAge(at: now) else { return true }
        return age >= PICS.staleInterval
    }

    /// Signals in use at this intersection, numbered from 1 (slot numbers have no known direction).
    public var activeSlots: [(slot: Int, signal: PedestrianSignal)] {
        (signals ?? []).enumerated().compactMap { index, signal in
            signal.state.isInUse ? (index + 1, signal) : nil
        }
    }
}

/// Entries within the last 30 seconds, at most the newest five (`recentHistory()`).
public func recentHistory(_ history: [SignalHistoryEntry], now: Date) -> [SignalHistoryEntry] {
    Array(history.filter { now.timeIntervalSince($0.timestamp) <= PICS.historyWindow }.suffix(PICS.historyLimit))
}
