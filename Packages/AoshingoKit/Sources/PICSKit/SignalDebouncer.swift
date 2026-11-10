// SPDX-License-Identifier: Apache-2.0

/// Asymmetric debounce for one pedestrian signal slot.
///
/// Changes towards danger (青 → 青点滅 → 赤, or to anything unknown) are confirmed by a single packet.
/// Changes towards safety (for example 赤 → 青) need `saferConfirmations` consecutive identical packets,
/// so the app may say "you can walk" a little late but never early because of one stray packet.
public struct SignalDebouncer: Sendable, Hashable {
    public let saferConfirmations: Int
    public private(set) var confirmed: PedestrianSignal?
    private var pending: PedestrianSignal?
    private var pendingCount = 0

    public init(saferConfirmations: Int = 2) {
        precondition(saferConfirmations >= 1)
        self.saferConfirmations = saferConfirmations
    }

    /// How safe a state is for starting to cross. Only 青 is safe; 青点滅 means "do not start".
    public static func safetyRank(_ state: SignalState) -> Int {
        switch state {
        case .green: 2
        case .blinkGreen: 1
        case .red, .noSignal, .none, .unknown: 0
        }
    }

    /// Feeds one received signal. Returns the newly confirmed signal when the confirmed **state**
    /// changed, otherwise `nil`. Remaining-time updates within the same state are applied silently.
    @discardableResult
    public mutating func feed(_ signal: PedestrianSignal) -> PedestrianSignal? {
        guard let current = confirmed else {
            return Self.safetyRank(signal.state) > 0 ? hold(signal) : confirm(signal)
        }
        if signal.state == current.state {
            confirmed = signal
            clearPending()
            return nil
        }
        if Self.safetyRank(signal.state) <= Self.safetyRank(current.state) {
            return confirm(signal)
        }
        return hold(signal)
    }

    /// Forgets everything, for example when the signal became stale.
    public mutating func reset() {
        confirmed = nil
        clearPending()
    }

    private mutating func hold(_ signal: PedestrianSignal) -> PedestrianSignal? {
        if pending?.state == signal.state {
            pendingCount += 1
        } else {
            pendingCount = 1
        }
        pending = signal
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
    }
}

/// One debouncer per signal slot of an intersection.
public struct SlotDebouncers: Sendable, Hashable {
    public private(set) var slots: [SignalDebouncer]

    public init(saferConfirmations: Int = 2) {
        slots = Array(repeating: SignalDebouncer(saferConfirmations: saferConfirmations), count: PICS.maximumSignals)
    }

    /// Feeds a Type 2 signal list. Returns the slots (1-based) whose confirmed state changed.
    @discardableResult
    public mutating func feed(_ signals: [PedestrianSignal]) -> [(slot: Int, signal: PedestrianSignal)] {
        var changes: [(slot: Int, signal: PedestrianSignal)] = []
        for (index, signal) in signals.prefix(PICS.maximumSignals).enumerated() {
            if let changed = slots[index].feed(signal) {
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
