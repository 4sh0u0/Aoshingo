// SPDX-License-Identifier: Apache-2.0
//
// Writes the app icon and the brand files from the SwiftUI master artwork in
// App/Views/Brand/AoshingoLogo.swift. Build and run it with Tools/AppIcon/export.sh on a Mac.
//
//   App/Resources/AppIcon.icon/icon.json, Assets/*.svg        Icon Composer document (iOS 26 and later)
//   App/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png   flat 1024 × 1024 icon (iOS 18–25)
//   docs/assets/brand/aoshingo-*.svg                            logo files for the README and the website
//
// The SVG paths are the SwiftUI paths themselves (strokes already outlined), so every output matches the
// logo the app draws.

import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

@main
@MainActor
enum ExportAppIcon {
    static func main() throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.arguments.dropFirst().first ?? ".", isDirectory: true)
        let iconDocument = root.appending(path: "App/Resources/AppIcon.icon")
        let iconAssets = iconDocument.appending(path: "Assets")
        let appIconSet = root.appending(path: "App/Resources/Assets.xcassets/AppIcon.appiconset")
        let brand = root.appending(path: "docs/assets/brand")
        for directory in [iconAssets, appIconSet, brand] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        // Icon Composer: one SVG per group, in the tile colours, on a transparent canvas. The background
        // gradient is the document fill, so the system can change it per appearance.
        for group in AoshingoLogoGroup.allCases {
            let layers = AoshingoLogoArtwork.layers.filter { $0.group == group }
            try write(SVG.document(layers, appearance: .tile), to: iconAssets.appending(path: "\(group.rawValue).svg"))
        }
        try write(iconJSON(), to: iconDocument.appending(path: "icon.json"))

        // iOS 18–25 do not read the Icon Composer document and use this single opaque square instead.
        try writeFlatPNG(of: AoshingoLogoMark(appearance: .tile, roundedTile: false), side: 1024, to: appIconSet.appending(path: "AppIcon.png"))

        let all = AoshingoLogoArtwork.layers
        try write(SVG.document(all, appearance: .tile, tile: true), to: brand.appending(path: "aoshingo-icon.svg"))
        try write(SVG.document(all, appearance: .dark), to: brand.appending(path: "aoshingo-mark-dark.svg"))
        try write(SVG.document(all, appearance: .light), to: brand.appending(path: "aoshingo-mark-light.svg"))
    }

    // MARK: Icon Composer document

    /// The Liquid Glass settings live here, not only in Icon Composer: this file is written again on
    /// every export. Groups are listed front to back.
    static func iconJSON() throws -> String {
        func group(_ name: String, _ layerGroup: AoshingoLogoGroup, glass: Bool, shadowKind: String) -> [String: Any] {
            let layer: [String: Any] = ["name": layerGroup.rawValue, "image-name": "\(layerGroup.rawValue).svg", "glass": glass]
            let shadow: [String: Any] = ["kind": shadowKind, "opacity": 0.5]
            // Translucency would let the navy show through and lower the lit / unlit contrast.
            let translucency: [String: Any] = ["enabled": false, "value": 0.5]
            return ["name": name, "layers": [layer], "shadow": shadow, "translucency": translucency]
        }
        func gradient(_ top: UInt32, _ bottom: UInt32) -> [String: Any] {
            let orientation: [String: [String: Double]] = ["start": ["x": 0.5, "y": 0], "stop": ["x": 0.5, "y": 1]]
            return ["linear-gradient": [colour(top), colour(bottom)], "orientation": orientation]
        }
        let fills: [[String: Any]] = [
            ["value": gradient(AoshingoLogoPalette.navyTop, AoshingoLogoPalette.navyBottom)],
            ["appearance": "dark", "value": gradient(AoshingoLogoPalette.navyDarkTop, AoshingoLogoPalette.navyDarkBottom)],
        ]
        // No "color-space-for-untagged-svg-colors": without it Icon Composer reads the SVG hex colours as
        // sRGB, which is what they are. It accepts only "display-p3" there and rejects "srgb".
        let document: [String: Any] = [
            "fill-specializations": fills,
            "groups": [
                group("Figure", .figure, glass: true, shadowKind: "neutral"),
                group("Lit steps", .lit, glass: true, shadowKind: "layer-color"),
                group("Unlit steps", .unlit, glass: false, shadowKind: "none"),
            ],
            "supported-platforms": ["squares": "shared"],
        ]
        let data = try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    static func colour(_ hex: UInt32) -> String {
        let components = [(hex >> 16) & 0xFF, (hex >> 8) & 0xFF, hex & 0xFF].map { String(format: "%.5f", Double($0) / 255) }
        return "srgb:" + components.joined(separator: ",") + ",1.00000"
    }

    // MARK: Flat PNG

    static func writeFlatPNG(of view: some View, side: Int, to url: URL) throws {
        let renderer = ImageRenderer(content: view.frame(width: CGFloat(side), height: CGFloat(side)))
        renderer.scale = 1
        renderer.isOpaque = true
        guard let image = renderer.cgImage else { throw ExportError("ImageRenderer returned no image") }

        // Redraw as 8-bit sRGB without alpha: App Store Connect rejects an app icon with an alpha channel.
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              )
        else { throw ExportError("could not create the sRGB context") }
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        try checkColours(in: context, side: side)

        guard let flat = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw ExportError("could not encode \(url.lastPathComponent)") }
        CGImageDestinationAddImage(destination, flat, nil)
        guard CGImageDestinationFinalize(destination) else { throw ExportError("could not write \(url.path)") }
        print("wrote \(url.path)")
    }

    /// Samples one point of each colour, so that a colour-space slip or an upside-down gradient fails the
    /// export instead of reaching the App Store.
    static func checkColours(in context: CGContext, side: Int) throws {
        guard let data = context.data else { throw ExportError("no pixel data") }
        let pixels = data.assumingMemoryBound(to: UInt8.self)
        let scale = Double(side) / Double(AoshingoLogoArtwork.grid)
        let r = Double(AoshingoLogoArtwork.ringRadius)
        func onRing(_ degrees: Double) -> CGPoint {
            CGPoint(x: 512 + r * cos(degrees * .pi / 180), y: 512 + r * sin(degrees * .pi / 180))
        }
        let k = AoshingoLogoArtwork.figureSize / 100
        let head = AoshingoLogoArtwork.figureHead.center
        let samples: [(String, CGPoint, UInt32)] = [
            ("background, top", CGPoint(x: 4, y: 4), AoshingoLogoPalette.navyTop),
            ("background, bottom", CGPoint(x: 4, y: 1019), AoshingoLogoPalette.navyBottom),
            ("first lit step", onRing(-67.5), AoshingoLogoPalette.litOnDark),
            ("last unlit step", onRing(247.5), AoshingoLogoPalette.unlitOnDark),
            ("head", CGPoint(x: AoshingoLogoArtwork.figureOrigin.x + head.x * k, y: AoshingoLogoArtwork.figureOrigin.y + head.y * k), 0xFFFFFF),
        ]
        for (name, point, expected) in samples {
            let x = Int(point.x * scale), y = Int(point.y * scale)
            let offset = y * context.bytesPerRow + x * 4
            let actual = (0..<3).map { Int(pixels[offset + $0]) }
            let wanted = [Int(expected >> 16) & 0xFF, Int(expected >> 8) & 0xFF, Int(expected) & 0xFF]
            let hex = actual.map { String(format: "%02X", $0) }.joined()
            guard zip(actual, wanted).allSatisfy({ pair in abs(pair.0 - pair.1) <= 3 }) else {
                throw ExportError("\(name) at (\(x), \(y)) is #\(hex), expected #\(String(format: "%06X", expected))")
            }
            print("ok   \(name) #\(hex)")
        }
    }

    static func write(_ text: String, to url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
        print("wrote \(url.path)")
    }
}

struct ExportError: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
}

// MARK: - SVG

enum SVG {
    /// A 1024 × 1024 SVG of the given shapes. With `tile`, the rounded navy square goes behind them.
    static func document(_ layers: [AoshingoLogoLayer], appearance: AoshingoLogoAppearance, tile: Bool = false) -> String {
        let side = Int(AoshingoLogoArtwork.grid)
        var lines = [#"<svg xmlns="http://www.w3.org/2000/svg" width="\#(side)" height="\#(side)" viewBox="0 0 \#(side) \#(side)">"#]
        if tile {
            let top = hex(AoshingoLogoPalette.navyTop), bottom = hex(AoshingoLogoPalette.navyBottom)
            lines.append(#"<defs><linearGradient id="navy" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="\#(top)"/><stop offset="1" stop-color="\#(bottom)"/></linearGradient></defs>"#)
            let square = CGRect(x: 0, y: 0, width: AoshingoLogoArtwork.grid, height: AoshingoLogoArtwork.grid)
            lines.append(#"<path fill="url(#navy)" d="\#(AoshingoLogoTileShape().path(in: square).svgData)"/>"#)
        }
        for layer in layers {
            let colour = AoshingoLogoPalette.hex(for: layer.role, in: appearance)
            let opacity = colour.opacity < 1 ? #" fill-opacity="\#(colour.opacity)""# : ""
            lines.append(#"<path fill="\#(hex(colour.hex))"\#(opacity) d="\#(layer.element.path.svgData)"/>"#)
        }
        lines.append("</svg>")
        return lines.joined(separator: "\n") + "\n"
    }

    static func hex(_ value: UInt32) -> String { String(format: "#%06X", value) }
}

extension Path {
    /// SVG path data with two decimals, which is 1/500 of a point on the 1024 grid.
    var svgData: String {
        var data = ""
        forEach { element in
            switch element {
            case let .move(to: p): data += "M\(p.svg)"
            case let .line(to: p): data += "L\(p.svg)"
            case let .quadCurve(to: p, control: c): data += "Q\(c.svg) \(p.svg)"
            case let .curve(to: p, control1: c1, control2: c2): data += "C\(c1.svg) \(c2.svg) \(p.svg)"
            case .closeSubpath: data += "Z"
            }
        }
        return data
    }
}

private extension CGPoint {
    var svg: String { "\(Self.number(x)) \(Self.number(y))" }

    static func number(_ value: CGFloat) -> String {
        var text = String(format: "%.2f", Double(value))
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text == "-0" ? "0" : text
    }
}
