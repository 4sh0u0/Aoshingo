// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
@testable import PICSKit

@Suite struct SlotPreferencesTests {
    @Test func namesAreTrimmedAndTheReadingIsSpoken() {
        var preference = SlotPreference(name: "  駅の方へ ")
        #expect(preference.displayName == "駅の方へ")
        #expect(preference.spokenName == "駅の方へ")
        preference.reading = "えきのほうへ"
        #expect(preference.spokenName == "えきのほうへ")
        #expect(SlotPreference(name: " ").displayName == nil)
        #expect(SlotPreference().spokenName == nil)
    }

    @Test func whichChangesAreAnnounced() {
        #expect(SlotPreference().watch(warningsForEverySignal: true) == .warnings)
        #expect(SlotPreference().watch(warningsForEverySignal: false) == SignalWatch.none)
        // A chosen sound or vibration means the user picked this signal, so its warnings are
        // announced even when warnings are off for the other signals.
        #expect(SlotPreference(sound: .bell).watch(warningsForEverySignal: false) == .warnings)
        #expect(SlotPreference(vibration: .long).watch(warningsForEverySignal: false) == .warnings)
        #expect(SlotPreference(announcesGreen: true).watch(warningsForEverySignal: false) == .warningsAndGreen)
        #expect(SlotPreference(isMuted: true, announcesGreen: true, sound: .bell).watch(warningsForEverySignal: true) == SignalWatch.none)
    }

    @Test func defaultSlotsAreNotKept() {
        var preferences = SlotPreferences()
        preferences["A", 1] = SlotPreference(name: "駅の方へ")
        preferences["A", 2] = SlotPreference(isMuted: true)
        preferences["B", 1] = SlotPreference(sound: .triple)
        #expect(preferences.count == 2)
        #expect(preferences["A", 1].displayName == "駅の方へ")
        #expect(preferences["A", 3] == SlotPreference())

        preferences["A", 1] = SlotPreference(name: "  ")
        preferences["A", 2] = SlotPreference()
        #expect(preferences.intersections["A"] == nil)
        #expect(preferences.count == 1)

        preferences.removeAll()
        #expect(preferences.isEmpty)
    }

    @Test func encodesAndDecodes() {
        var preferences = SlotPreferences()
        preferences["0123", 1] = SlotPreference(
            name: "駅の方へ", reading: "えきのほうへ", announcesGreen: true, sound: .arpeggio, vibration: .double
        )
        preferences["0123", 2] = SlotPreference(isMuted: true)
        let decoded = SlotPreferences.decode(preferences.encoded())
        #expect(decoded == preferences)
    }

    @Test func unknownValuesFallBackToTheDefault() {
        // As a later version might store it: an unknown sound and an extra key.
        let json = #"{"intersections":{"0123":{"1":{"name":"駅の方へ","sound":"siren","vibration":"long","extra":1}}}}"#
        let decoded = SlotPreferences.decode(Data(json.utf8))
        let preference = decoded["0123", 1]
        #expect(preference.displayName == "駅の方へ")
        #expect(preference.sound == SignalCueSound.none)
        #expect(preference.vibration == .long)
        #expect(!preference.isMuted)
    }

    @Test func unreadableDataGivesEmptyPreferences() {
        #expect(SlotPreferences.decode(nil).isEmpty)
        #expect(SlotPreferences.decode(Data("not json".utf8)).isEmpty)
    }
}
