// SPDX-License-Identifier: Apache-2.0

import Foundation

/// UserDefaults keys for the app settings (required-reason code CA92.1). FieldDataKit's
/// `UserDefaultsStateStore` also keeps its upload state under the `fieldData.` prefix.
enum SettingsKey {
    static let onboardingCompleted = "onboardingCompleted"
    static let collectionConsent = "collectionConsent"
    static let colorMode = "colorMode"
    static let keepScreenOn = "keepScreenOn"
    static let recordingEnabled = "recordingEnabled"
}

/// The user's choice on the field-data consent page. There is deliberately no default answer.
enum CollectionConsent: String, CaseIterable, Sendable {
    case undecided
    case granted
    case declined
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
    static let privacyPolicy = URL(string: "https://4sh0u0.github.io/Aoshingo/privacy/")!
    static let blePicsViewer = URL(string: "https://github.com/yumu19/ble-pics-viewer")!
}
