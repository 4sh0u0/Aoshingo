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
    ],
    targets: [
        // Platform-independent decoding of 高度化PICS advertisements (no CoreBluetooth, no UIKit),
        // so it can be tested with `swift test` on macOS and Linux.
        .target(name: "PICSKit"),
        .testTarget(name: "PICSKitTests", dependencies: ["PICSKit"]),
    ],
    swiftLanguageModes: [.v6]
)
