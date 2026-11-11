// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Asymmetric debounce for one pedestrian signal slot.
///
/// Changes towards danger (青 → 青点滅 → 赤, or to anything unknown) are confirmed by a single packet.
/// Changes towards safety (for example 赤 → 青) need `saferConfirmations` consecutive identical packets,
/// so the app may say "you can walk" a little late but never early because of one stray packet.
///
/// The scanner allows duplicates, so iOS may deliver the same advertisement more than once within a
/// few milliseconds. A packet therefore only counts towards a safer change when it arrived at least
/// `minimumSpacing` after the previous one that counted. The PICS header has a message ID byte, but
/// whether it changes with every transmission has not been confirmed on real transmitters, so it is
/// not relied on: if it were constant, requiring different IDs would never confirm 青 at all.
public struct SignalDebouncer: Sendable, Hashable {
    /// Default minimum time between two packets that both count towards a safer change.
    public static let minimumConfirmationSpacing: TimeInterval = 0.5

    public let saferConfirmations: Int
    public let minimumSpacing: TimeInterval
    public private(set) var confirmed: PedestrianSignal?
    private var pending: PedestrianSignal?
    private var pendingCount = 0
    /// Arrival time of the last packet that counted towards `pending`.
    private var pendingCountedAt: Date?

    public init(
        saferConfirmations: Int = 2,
        minimumSpacing: TimeInterval = SignalDebouncer.minimumConfirmationSpacing
    ) {
        precondition(saferConfirmations >= 1)
        precondition(minimumSpacing >= 0)
        self.saferConfirmations = saferConfirmations
        self.minimumSpacing = minimumSpacing
    }

    /// How safe a state is for starting to cross. Only 青 is safe; 青点滅 means "do not start".
    public static func safetyRank(_ state: SignalState) -> Int {
        switch state {
        case .green: 2
        case .blinkGreen: 1
        case .red, .noSignal, .none, .unknown: 0
        }
    }

    /// Feeds one received signal that arrived at `time`. Returns the newly confirmed signal when the
    /// confirmed **state** changed, otherwise `nil`. Remaining-time updates within the same state are
    /// applied silently.
    @discardableResult
    public mutating func feed(_ signal: PedestrianSignal, at time: Date) -> PedestrianSignal? {
        guard let current = confirmed else {
            return Self.safetyRank(signal.state) > 0 ? hold(signal, at: time) : confirm(signal)
        }
        if signal.state == current.state {
            confirmed = signal
            clearPending()
            return nil
        }
        if Self.safetyRank(signal.state) <= Self.safetyRank(current.state) {
            return confirm(signal)
        }
        return hold(signal, at: time)
    }

    /// Forgets everything, for example when the signal became stale.
    public mutating func reset() {
        confirmed = nil
        clearPending()
    }

    private mutating func hold(_ signal: PedestrianSignal, at time: Date) -> PedestrianSignal? {
        if pending?.state == signal.state, let countedAt = pendingCountedAt {
            pending = signal
            let elapsed = time.timeIntervalSince(countedAt)
            if elapsed < 0 {
                // The clock went backwards: start counting again from this packet.
                pendingCount = 1
                pendingCountedAt = time
            } else if elapsed >= minimumSpacing {
                pendingCount += 1
                pendingCountedAt = time
            }
            // Otherwise this is probably the same broadcast delivered again: it does not count.
        } else {
            pending = signal
            pendingCount = 1
            pendingCountedAt = time
        }
        guard pendingCount >= saferConfirmations else { return nil }
        return confirm(signal)
    }

    private mutating func confirm(_ signal: PedestrianSignal) -> PedestrianSignal {
        confirmed = signal
        clearPending()
        return signal
    }

    private mutating func clearPending() {
        pending = nil
        pendingCount = 0
        pendingCountedAt = nil
    }
}

/// One debouncer per signal slot of an intersection.
public struct SlotDebouncers: Sendable, Hashable {
    public private(set) var slots: [SignalDebouncer]

    public init(
        saferConfirmations: Int = 2,
        minimumSpacing: TimeInterval = SignalDebouncer.minimumConfirmationSpacing
    ) {
        slots = Array(
            repeating: SignalDebouncer(saferConfirmations: saferConfirmations, minimumSpacing: minimumSpacing),
            count: PICS.maximumSignals
        )
    }

    /// Feeds a Type 2 signal list that arrived at `time`. Returns the slots (1-based) whose confirmed
    /// state changed.
    @discardableResult
    public mutating func feed(_ signals: [PedestrianSignal], at time: Date) -> [(slot: Int, signal: PedestrianSignal)] {
        var changes: [(slot: Int, signal: PedestrianSignal)] = []
        for (index, signal) in signals.prefix(PICS.maximumSignals).enumerated() {
            if let changed = slots[index].feed(signal, at: time) {
                changes.append((index + 1, changed))
            }
        }
        return changes
    }

    /// Confirmed signals, `nil` for slots that have none yet.
    public var confirmed: [PedestrianSignal?] { slots.map(\.confirmed) }

    public mutating func reset() {
        for index in slots.indices { slots[index].reset() }
    }
}
