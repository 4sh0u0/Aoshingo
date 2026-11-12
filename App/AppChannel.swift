// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The distribution channel this build was made for, fixed when it is compiled (build setting
/// `AOSHINGO_CHANNEL`; docs/release.md).
///
/// - `appStore`: the build submitted to App Store review. It has none of the features kept for
///   contributors in TestFlight (the 「推定」 screen). Release builds are this unless told otherwise.
/// - `testFlight`: the extended-collection build, uploaded for TestFlight only.
/// - `development`: built from Xcode for development (Debug builds unless told otherwise).
enum AppChannel: Sendable {
    case appStore
    case testFlight
    case development

    static var current: AppChannel {
        #if AOSHINGO_CHANNEL_APPSTORE
        return .appStore
        #elseif AOSHINGO_CHANNEL_TESTFLIGHT
        return .testFlight
        #elseif AOSHINGO_CHANNEL_DEVELOPMENT
        return .development
        #else
        #error("Set AOSHINGO_CHANNEL to appstore, testflight or development (Config/Base.xcconfig).")
        #endif
    }

    /// Appended to the version in Settings and in the `client` field of field reports: nothing for
    /// App Store builds, `-tf` for TestFlight, `-dev` for development builds.
    var versionSuffix: String {
        switch self {
        case .appStore: ""
        case .testFlight: "-tf"
        case .development: "-dev"
        }
    }
}

/// The version of this build, as shown in Settings and sent with field reports.
enum AppVersion {
    /// `CFBundleShortVersionString`, for example `1.1.0` (three numbers: App Store Connect allows no suffix).
    static var marketing: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// `CFBundleVersion`: the App Store Connect build number, one integer shared by every upload.
    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }

    /// Settings: `1.1.0 (60)` for the App Store, `1.1.0-tf.57` for TestFlight (the name of its Git tag
    /// without the `v`), `1.1.0-dev` for development builds.
    static var display: String {
        switch AppChannel.current {
        case .appStore: "\(marketing) (\(build))"
        case .testFlight: "\(marketing)-tf.\(build)"
        case .development: "\(marketing)-dev"
        }
    }

    /// Sent as `aoshingo-ios/<this>` with field reports: the channel without the build number, so
    /// that the few TestFlight testers, each updating at a different time, cannot be told apart by it.
    static var reportVersion: String {
        marketing + AppChannel.current.versionSuffix
    }
}
