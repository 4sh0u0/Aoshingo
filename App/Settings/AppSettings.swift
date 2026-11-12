// SPDX-License-Identifier: Apache-2.0

import Foundation

/// UserDefaults keys for the app settings (required-reason code CA92.1). FieldDataKit's
/// `UserDefaultsStateStore` also keeps its upload state under the `fieldData.` prefix.
enum SettingsKey {
    static let onboardingCompleted = "onboardingCompleted"
    static let collectionConsent = "collectionConsent"
    /// The `CollectionConsent.currentVersion` the user agreed to when they chose "協力する".
    static let collectionConsentVersion = "collectionConsentVersion"
    /// Set when the user had agreed to an older list of collected data, so the consent page is shown
    /// again on its own (without the safety notice).
    static let collectionConsentReview = "collectionConsentReview"
    static let colorMode = "colorMode"
    static let keepScreenOn = "keepScreenOn"
    /// Whether changes into 青点滅, 赤, 信号なし, 不明 and 更新なし are spoken for every signal of the
    /// displayed intersection, and not only for the one VoiceOver is on.
    static let announceSignalWarnings = "announceSignalWarnings"
    static let announceSignalWarningsDefault = true
    /// Names, notification settings, sounds and vibrations per intersection and signal slot
    /// (`SlotPreferences` as JSON).
    static let slotPreferences = "slotPreferences"
    static let recordingEnabled = "recordingEnabled"
}

/// The user's choice on the field-data consent page. There is deliberately no default answer.
enum CollectionConsent: String, CaseIterable, Sendable {
    case undecided
    case granted
    case declined

    /// Version of what is collected (`CollectionDetails`). Raise it whenever more data is sent; users
    /// who agreed to an older version are asked again, and nothing is collected until they answer.
    /// 1 = report schema 1 (0.1.0), 2 = report schema 2.
    static let currentVersion = 2
}

/// How signal colours are drawn. Shapes and text are always shown in every mode.
enum SignalColorMode: String, CaseIterable, Identifiable, Sendable {
    /// Standard colours, switching to the colour-universal palette when the system setting
    /// "Differentiate Without Color" is on.
    case automatic
    case standard
    /// Colour Universal Design recommended palette (CUD ver.4).
    case colorUniversal
    /// Black, white and shapes only, with light/dark inversion between 青 and 赤.
    case monochrome

    var id: String { rawValue }
}

/// Links used in the app.
enum AppLinks {
    static let repository = URL(string: "https://github.com/4sh0u0/Aoshingo")!
    static let privacyPolicy = URL(string: "https://aoshingo.4sh.es/privacy/")!
    static let blePicsViewer = URL(string: "https://github.com/yumu19/ble-pics-viewer")!
}
