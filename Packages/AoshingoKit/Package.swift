// swift-tools-version: 6.0
// SPDX-License-Identifier: Apache-2.0

import PackageDescription

let package = Package(
    name: "AoshingoKit",
    defaultLocalization: "ja",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
    ],
    products: [
        .library(name: "PICSKit", targets: ["PICSKit"]),
        .library(name: "FieldDataKit", targets: ["FieldDataKit"]),
    ],
    targets: [
        // Platform-independent decoding of 高度化PICS advertisements (no CoreBluetooth, no UIKit),
        // so it can be tested with `swift test` on macOS and Linux.
        .target(name: "PICSKit"),
        .testTarget(name: "PICSKitTests", dependencies: ["PICSKit"]),

        // Opt-in field data collection: bucketing, local queue and the upload client.
        // Network and App Attest are injected so the logic stays testable without a device.
        .target(name: "FieldDataKit", dependencies: ["PICSKit"]),
        .testTarget(name: "FieldDataKitTests", dependencies: ["FieldDataKit", "PICSKit"]),
    ],
    swiftLanguageModes: [.v6]
)
