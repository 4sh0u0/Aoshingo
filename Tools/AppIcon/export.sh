#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
#
# Writes the app icon and the brand SVGs from App/Views/Brand/AoshingoLogo.swift. Needs a Mac with Xcode.
#
#   Tools/AppIcon/export.sh

set -eu
cd "$(dirname "$0")/../.."

build="$(mktemp -d)"
trap 'rm -rf "$build"' EXIT

xcrun swiftc -swift-version 6 -parse-as-library -O \
    -target "$(uname -m)-apple-macos14" \
    App/Views/Brand/AoshingoLogo.swift Tools/AppIcon/ExportAppIcon.swift \
    -o "$build/export-app-icon"
"$build/export-app-icon" .
