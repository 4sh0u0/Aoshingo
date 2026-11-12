// SPDX-License-Identifier: Apache-2.0

import Foundation

/// What one signal slot shows, as far as a spoken alert is concerned.
public enum SignalCondition: Hashable, Sendable {
    /// Signal data is current, but the state is not confirmed yet (shown as 判定中).
    case pending
    /// No Type 2 for `PICS.staleInterval` seconds (shown as 更新なし).
    case stale
    /// A confirmed state.
    case state(SignalState)

    /// The states that tell someone not to start crossing, or to check the real signal: 青点滅,
    /// 赤, 信号なし, 不明 and 更新なし. Changes into these are spoken wherever VoiceOver focus is.
    public var needsAttention: Bool {
        switch self {
        case .pending: false
        case .stale: true
        case .state(let state):
            switch state {
            case .blinkGreen, .red, .noSignal, .unknown: true
            case .green, .none: false
            }
        }
    }
}

/// Finds the signal changes of the displayed intersection that are spoken whether or not VoiceOver
/// focus is on that signal.
///
/// Each slot has a `SignalWatch`. Usually only changes into a condition that `needsAttention` are
/// reported; changes towards 青 are reported only for a slot the user has chosen
/// (`.warningsAndGreen`) and only when the slot was seen changing into 青 from a confirmed state,
/// and otherwise spoken only for the signal that VoiceOver is on
/// (`SignalSlotView`), because nobody should start crossing because of a signal they have not
/// chosen. Changes that arrive close together are collected and reported as one announcement
/// (`flush`), so that one announcement does not cut off another, and the same announcement is not
/// repeated within `repeatInterval` (for example when reception keeps dropping out at the edge of
/// the range).
public struct SignalChangeMonitor: Sendable {
    /// How long to wait after the first change before speaking, so that slots that change in the
    /// next packets are spoken together.
    public static let collectionDelay: Duration = .milliseconds(400)
    /// The same announcement is not repeated within this many seconds.
    public static let repeatInterval: TimeInterval = 10

    /// Slots that changed into a condition that needs attention, grouped by that condition.
    public struct Change: Hashable, Sendable {
        public var condition: SignalCondition
        /// Slot numbers from 1, ascending.
        public var slots: [Int]

        public init(condition: SignalCondition, slots: [Int]) {
            self.condition = condition
            self.slots = slots
        }
    }

    private var intersectionID: String?
    /// The last condition of each slot that was spoken or did not need to be spoken.
    private var baseline: [Int: SignalCondition] = [:]
    private var current: [Int: SignalCondition] = [:]
    private var watches: [Int: SignalWatch] = [:]
    /// What was spoken within the last `repeatInterval`.
    private var recentlySpoken: [(changes: [Change], at: Date)] = []

    public init() {}

    /// `true` while a change waits for `flush`.
    public var hasPendingChanges: Bool {
        current.contains { slot, condition in
            isReported(condition, slot: slot) && baseline[slot] != condition
        }
    }

    private func isReported(_ condition: SignalCondition, slot: Int) -> Bool {
        (watches[slot] ?? .warnings).reports(condition)
    }

    /// `true` for 青 that was not seen changing from a confirmed state: right after 判定中 or 更新なし
    /// (reception just started, the intersection changed, or reception dropped out) the green may
    /// have started long ago and be about to end, so it must not be spoken as 「青に変わった」.
    private func isUnconfirmedGreen(_ condition: SignalCondition, slot: Int) -> Bool {
        guard condition == .state(.green) else { return false }
        switch baseline[slot] {
        case .state: return false
        case .pending, .stale, nil: return true
        }
    }

    /// Records what the slots of the displayed intersection show now. A different intersection
    /// starts again without reporting anything: the switch itself is announced with its name.
    /// - Parameters:
    ///   - conditions: slot number (from 1) → condition, for the slots in use.
    ///   - watches: slot number → which of its changes are reported; `.warnings` for a slot that is
    ///     not listed.
    public mutating func update(
        intersectionID id: String,
        conditions: [Int: SignalCondition],
        watches: [Int: SignalWatch] = [:]
    ) {
        self.watches = watches
        if id != intersectionID {
            intersectionID = id
            baseline = conditions
            current = conditions
            recentlySpoken = []
            return
        }
        current = conditions
        for (slot, condition) in conditions {
            // A slot heard for the first time, or a change into a condition that is not reported
            // (for example towards a safer state), is taken as it is, so that the next reported
            // change is compared with it. This also keeps a change of the settings from announcing
            // what a signal already shows. 青 not seen changing from a confirmed state is taken in
            // the same way (`isUnconfirmedGreen`).
            if baseline[slot] == nil || !isReported(condition, slot: slot)
                || isUnconfirmedGreen(condition, slot: slot) {
                baseline[slot] = condition
            }
        }
    }

    /// Returns the changes to speak now and takes them as spoken. Empty when nothing changed since
    /// the last flush, or when the same changes were spoken less than `repeatInterval` ago.
    public mutating func flush(at now: Date) -> [Change] {
        var grouped: [SignalCondition: [Int]] = [:]
        for (slot, condition) in current where isReported(condition, slot: slot) && baseline[slot] != condition {
            grouped[condition, default: []].append(slot)
            baseline[slot] = condition
        }
        let changes = grouped
            .map { Change(condition: $0.key, slots: $0.value.sorted()) }
            .sorted { $0.slots.first ?? 0 < $1.slots.first ?? 0 }
        guard !changes.isEmpty else { return [] }
        recentlySpoken.removeAll { now.timeIntervalSince($0.at) >= Self.repeatInterval }
        if recentlySpoken.contains(where: { $0.changes == changes }) { return [] }
        recentlySpoken.append((changes, now))
        return changes
    }

    /// Forgets everything, for example when reception stops.
    public mutating func reset() {
        self = SignalChangeMonitor()
    }
}
