// SPDX-License-Identifier: Apache-2.0

import Foundation
import Observation
import PICSKit

/// The user's settings for each signal slot of each intersection, kept in UserDefaults on this
/// device only. They are never part of the field data.
@MainActor
@Observable
final class SlotPreferenceStore {
    private(set) var preferences: SlotPreferences

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        preferences = SlotPreferences.decode(defaults.data(forKey: SettingsKey.slotPreferences))
    }

    subscript(intersectionID: String, slot: Int) -> SlotPreference {
        get { preferences[intersectionID, slot] }
        set {
            var updated = preferences
            updated[intersectionID, slot] = newValue
            guard updated != preferences else { return }
            preferences = updated
            save()
        }
    }

    func removeAll() {
        preferences = SlotPreferences()
        save()
    }

    private func save() {
        if preferences.isEmpty {
            defaults.removeObject(forKey: SettingsKey.slotPreferences)
        } else {
            defaults.set(preferences.encoded(), forKey: SettingsKey.slotPreferences)
        }
    }
}
