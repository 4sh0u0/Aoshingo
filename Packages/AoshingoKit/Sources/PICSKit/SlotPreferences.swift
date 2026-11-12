// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The sound played before a signal's change is announced. The sounds themselves are synthesised
/// by the app; this is only the user's choice.
///
/// None of them may sound like the guidance sounds of real pedestrian signals (the bird calls
/// ピヨピヨ and カッコー, or ピッポ), so that the phone is never mistaken for the signal.
public enum SignalCueSound: String, Codable, CaseIterable, Sendable {
    case none
    /// One high, ringing tone (ポーン).
    case bell
    /// Three rising notes (ドミソ).
    case arpeggio
    /// One low tone (ボン).
    case low
    /// Three short pips at the same pitch (ポポポ).
    case triple
}

/// The vibration played with a signal's cue.
public enum SignalCueVibration: String, Codable, CaseIterable, Sendable {
    case none
    /// One long vibration.
    case long
    /// Two short vibrations.
    case double
    /// Three short vibrations.
    case triple
}

/// Which changes of one signal are announced wherever VoiceOver focus is, with the signal's cue.
public enum SignalWatch: Hashable, Sendable {
    /// None: the signal is not announced and plays no cue.
    case none
    /// Changes into the conditions that need attention (青点滅, 赤, 信号なし, 不明, 更新なし).
    case warnings
    /// Those, and changes into 青. Only for a signal the user has chosen as one they cross.
    case warningsAndGreen

    /// Whether a change into `condition` is announced.
    public func reports(_ condition: SignalCondition) -> Bool {
        switch self {
        case .none: false
        case .warnings: condition.needsAttention
        case .warningsAndGreen: condition.needsAttention || condition == .state(.green)
        }
    }
}

/// What the user set for one signal slot of one intersection, as 信GO! lets users set each
/// direction: a name and its reading, whether it is announced at all, whether its changes into
/// 青 are announced, and a sound and a vibration that tell it apart from the other signals.
///
/// Slot numbers are only the order inside the Type 2 message; which crossing a slot belongs to is
/// known only to the user who has checked it on the spot.
public struct SlotPreference: Codable, Hashable, Sendable {
    /// Shown instead of 「n 番」. Empty means no name.
    public var name: String
    /// Spoken instead of the name when not empty, for names that VoiceOver reads wrongly.
    public var reading: String
    /// Not announced, no cue, and shown folded below the other signals.
    public var isMuted: Bool
    /// Changes into 青 are announced too. Off by default: nobody should start crossing because of
    /// a signal they have not chosen.
    public var announcesGreen: Bool
    public var sound: SignalCueSound
    public var vibration: SignalCueVibration

    public init(
        name: String = "",
        reading: String = "",
        isMuted: Bool = false,
        announcesGreen: Bool = false,
        sound: SignalCueSound = .none,
        vibration: SignalCueVibration = .none
    ) {
        self.name = name
        self.reading = reading
        self.isMuted = isMuted
        self.announcesGreen = announcesGreen
        self.sound = sound
        self.vibration = vibration
    }

    /// Settings written by a later version may have values this version does not know; those fall
    /// back to the default instead of losing every setting.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = (try? container.decodeIfPresent(String.self, forKey: .name)) ?? ""
        reading = (try? container.decodeIfPresent(String.self, forKey: .reading)) ?? ""
        isMuted = (try? container.decodeIfPresent(Bool.self, forKey: .isMuted)) ?? false
        announcesGreen = (try? container.decodeIfPresent(Bool.self, forKey: .announcesGreen)) ?? false
        sound = (try? container.decodeIfPresent(SignalCueSound.self, forKey: .sound)) ?? SignalCueSound.none
        vibration = (try? container.decodeIfPresent(SignalCueVibration.self, forKey: .vibration)) ?? SignalCueVibration.none
    }

    /// The name to show, without surrounding spaces; `nil` when there is none.
    public var displayName: String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The name to speak: the reading if there is one, else the name; `nil` when neither is set.
    public var spokenName: String? {
        let trimmed = reading.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? displayName : trimmed
    }

    /// Whether a sound or a vibration is chosen.
    public var hasCue: Bool {
        sound != SignalCueSound.none || vibration != SignalCueVibration.none
    }

    /// Which changes of this signal are announced.
    /// - Parameter warningsForEverySignal: the setting 「すべての信号の青点滅・赤を読み上げる」, which
    ///   applies to the signals the user has not set up. A signal with a cue or with 青 switched on
    ///   has been chosen, so its warnings are announced either way.
    public func watch(warningsForEverySignal: Bool) -> SignalWatch {
        if isMuted { return .none }
        if announcesGreen { return .warningsAndGreen }
        if hasCue || warningsForEverySignal { return .warnings }
        return .none
    }

    /// `true` when nothing differs from a signal that was never set up.
    public var isDefault: Bool {
        displayName == nil && reading.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isMuted && !announcesGreen && !hasCue
    }
}

/// Every intersection's slot preferences, stored on the device only (never uploaded).
public struct SlotPreferences: Codable, Hashable, Sendable {
    /// Intersection ID → slot number (from 1) → preference. Slots left at the default are not kept.
    public private(set) var intersections: [String: [Int: SlotPreference]]

    public init(intersections: [String: [Int: SlotPreference]] = [:]) {
        self.intersections = intersections.compactMapValues { slots in
            let kept = slots.filter { !$0.value.isDefault }
            return kept.isEmpty ? nil : kept
        }
    }

    public subscript(intersectionID: String, slot: Int) -> SlotPreference {
        get { intersections[intersectionID]?[slot] ?? SlotPreference() }
        set {
            var slots = intersections[intersectionID] ?? [:]
            slots[slot] = newValue.isDefault ? nil : newValue
            intersections[intersectionID] = slots.isEmpty ? nil : slots
        }
    }

    /// The number of intersections with at least one slot set up.
    public var count: Int { intersections.count }

    public var isEmpty: Bool { intersections.isEmpty }

    public mutating func removeAll() {
        intersections = [:]
    }

    /// Decodes stored preferences. Data that cannot be read at all gives empty preferences rather
    /// than an error, so a damaged value never stops the app.
    public static func decode(_ data: Data?) -> SlotPreferences {
        guard let data, let decoded = try? JSONDecoder().decode(SlotPreferences.self, from: data) else {
            return SlotPreferences()
        }
        return SlotPreferences(intersections: decoded.intersections)
    }

    public func encoded() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(self)) ?? Data()
    }
}
