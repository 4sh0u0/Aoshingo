// SPDX-License-Identifier: Apache-2.0
//
// The Aoshingo logo: a walking figure inside a ring of eight steps, five of them lit. The ring is the
// app's eight-step remaining-time estimate (残り 8 段階).
//
// The logo is drawn only with SwiftUI shapes on a 1024 × 1024 design grid, and this file is the master
// artwork: Tools/AppIcon/export.sh writes the app icon (an Icon Composer document) and the brand files in
// docs/assets/brand from these same numbers. Run it again after any change here.
//
// Colour is never the only cue: lit and unlit steps differ in lightness (3.2:1 on the icon), the
// figure stands out from the background by more than 10:1, and nothing depends on red vs green.

import SwiftUI

// MARK: - Appearance and palette

/// Where the logo is drawn.
enum AoshingoLogoAppearance: String, CaseIterable, Sendable {
    /// The navy app-icon square.
    case tile
    /// Transparent, for dark backgrounds.
    case dark
    /// Transparent, for light backgrounds.
    case light
    /// A rough preview of the monochrome (clear / tinted) icon appearances: lightness only.
    case mono
}

/// What a shape is, not which colour it has: the appearance decides the colour.
enum AoshingoLogoRole: Sendable {
    case lit
    case unlit
    case figure
}

enum AoshingoLogoPalette {
    static let navyTop: UInt32 = 0x0B1F45
    static let navyBottom: UInt32 = 0x13406B
    /// The background of the dark app-icon appearance (iOS 26 and later).
    static let navyDarkTop: UInt32 = 0x050E22
    static let navyDarkBottom: UInt32 = 0x0B1F45
    /// The website's accent on dark backgrounds (8.98:1 on navy).
    static let litOnDark: UInt32 = 0x5FD4BD
    /// The app's standard 青 (4.88:1 on white).
    static let litOnLight: UInt32 = 0x00806B
    /// 1.8–2.8:1 on the navy gradient, 3.2:1 against the lit steps.
    static let unlitOnDark: UInt32 = 0x41679A
    /// 1.8:1 on white, 2.7:1 against the lit steps (the figure carries the light mark at 16:1).
    static let unlitOnLight: UInt32 = 0xB4C1D1
    static let ink: UInt32 = 0x0B1F45
    static let monoBackground: UInt32 = 0x1C1C1E

    static func hex(for role: AoshingoLogoRole, in appearance: AoshingoLogoAppearance) -> (hex: UInt32, opacity: Double) {
        switch (appearance, role) {
        case (.mono, .lit): (0xFFFFFF, 0.9)
        case (.mono, .unlit): (0xFFFFFF, 0.25)
        case (.mono, .figure): (0xFFFFFF, 1)
        case (.light, .lit): (litOnLight, 1)
        case (.light, .unlit): (unlitOnLight, 1)
        case (.light, .figure): (ink, 1)
        case (_, .lit): (litOnDark, 1)
        case (_, .unlit): (unlitOnDark, 1)
        case (_, .figure): (0xFFFFFF, 1)
        }
    }

    static func color(for role: AoshingoLogoRole, in appearance: AoshingoLogoAppearance) -> Color {
        let value = hex(for: role, in: appearance)
        return Color(logoHex: value.hex, opacity: value.opacity)
    }
}

extension Color {
    init(logoHex hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}

// MARK: - Geometry

/// One primitive on the 1024-point design grid. Angles are in degrees, 0° at 3 o'clock, growing
/// clockwise on screen (y points down).
enum AoshingoLogoElement: Sendable {
    case circle(center: CGPoint, radius: CGFloat)
    /// Round caps and joins.
    case polyline([CGPoint], width: CGFloat)
    /// Butt caps.
    case arc(center: CGPoint, radius: CGFloat, from: Double, to: Double, width: CGFloat)

    /// The filled outline in design coordinates.
    var path: Path {
        switch self {
        case let .circle(center, radius):
            return Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        case let .polyline(points, width):
            var path = Path()
            path.addLines(points)
            return path.strokedPath(StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
        case let .arc(center, radius, from, to, width):
            var path = Path()
            path.addRelativeArc(center: center, radius: radius, startAngle: .degrees(from), delta: .degrees(to - from))
            return path.strokedPath(StrokeStyle(lineWidth: width, lineCap: .butt))
        }
    }
}

/// The Icon Composer groups, front to back.
enum AoshingoLogoGroup: String, CaseIterable, Sendable {
    case figure
    case lit
    case unlit
}

struct AoshingoLogoLayer: Sendable {
    var element: AoshingoLogoElement
    var role: AoshingoLogoRole

    var group: AoshingoLogoGroup {
        switch role {
        case .figure: .figure
        case .lit: .lit
        case .unlit: .unlit
        }
    }
}

enum AoshingoLogoArtwork {
    static let grid: CGFloat = 1024
    static let steps = 8
    static let litSteps = 5

    static let ringCenter = CGPoint(x: 512, y: 512)
    static let ringRadius: CGFloat = 340
    static let ringWidth: CGFloat = 84
    /// Gap between two steps, in degrees.
    static let stepGap = 9.0

    /// The walking figure on a 100-unit box: a round head and five round-capped strokes.
    static let figureOrigin = CGPoint(x: 298, y: 306)
    static let figureSize: CGFloat = 420
    static let figureHead = (center: CGPoint(x: 61, y: 10), radius: CGFloat(9.5))
    static let figureStrokes: [[CGPoint]] = [
        [CGPoint(x: 57, y: 27), CGPoint(x: 48, y: 54)],                           // torso
        [CGPoint(x: 56, y: 31), CGPoint(x: 65, y: 41), CGPoint(x: 74, y: 45)],    // front arm
        [CGPoint(x: 55, y: 31), CGPoint(x: 48, y: 43), CGPoint(x: 38, y: 50)],    // back arm
        [CGPoint(x: 48, y: 54), CGPoint(x: 59, y: 70), CGPoint(x: 67, y: 92)],    // front leg
        [CGPoint(x: 48, y: 54), CGPoint(x: 40, y: 73), CGPoint(x: 27, y: 87)],    // back leg
    ]
    static let figureStrokeWidth: CGFloat = 10.5

    /// Every shape of the logo, back to front.
    static let layers: [AoshingoLogoLayer] = {
        let span = 360.0 / Double(steps)
        var layers: [AoshingoLogoLayer] = (0..<steps).map { step in
            // Step 0 starts at 12 o'clock; the lit steps run clockwise from there.
            let from = -90 + Double(step) * span + stepGap / 2
            return AoshingoLogoLayer(
                element: .arc(center: ringCenter, radius: ringRadius, from: from, to: from + span - stepGap, width: ringWidth),
                role: step < litSteps ? .lit : .unlit
            )
        }

        let k = figureSize / 100
        func onGrid(_ p: CGPoint) -> CGPoint { CGPoint(x: figureOrigin.x + p.x * k, y: figureOrigin.y + p.y * k) }
        layers.append(AoshingoLogoLayer(element: .circle(center: onGrid(figureHead.center), radius: figureHead.radius * k), role: .figure))
        for stroke in figureStrokes {
            layers.append(AoshingoLogoLayer(element: .polyline(stroke.map(onGrid), width: figureStrokeWidth * k), role: .figure))
        }
        return layers
    }()
}

// MARK: - Views

/// Scales a design-grid primitive to the frame, keeping it square and centred.
struct AoshingoLogoElementShape: Shape {
    var element: AoshingoLogoElement

    func path(in rect: CGRect) -> Path {
        let k = min(rect.width, rect.height) / AoshingoLogoArtwork.grid
        let transform = CGAffineTransform(
            translationX: rect.midX - AoshingoLogoArtwork.grid / 2 * k,
            y: rect.midY - AoshingoLogoArtwork.grid / 2 * k
        ).scaledBy(x: k, y: k)
        return element.path.applying(transform)
    }
}

/// The iOS app-icon outline. Previews only: the system applies the real mask to the app icon.
struct AoshingoLogoTileShape: Shape {
    func path(in rect: CGRect) -> Path {
        RoundedRectangle(cornerRadius: min(rect.width, rect.height) * 0.2237, style: .continuous).path(in: rect)
    }
}

struct AoshingoLogoMark: View {
    var appearance: AoshingoLogoAppearance = .tile
    /// Rounded corners on the tile. Off for the app icon export, which must be a full square.
    var roundedTile = true

    var body: some View {
        ZStack {
            switch appearance {
            case .tile:
                LinearGradient(
                    colors: [Color(logoHex: AoshingoLogoPalette.navyTop), Color(logoHex: AoshingoLogoPalette.navyBottom)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            case .mono:
                Color(logoHex: AoshingoLogoPalette.monoBackground)
            case .dark, .light:
                Color.clear
            }
            ForEach(AoshingoLogoArtwork.layers.indices, id: \.self) { index in
                let layer = AoshingoLogoArtwork.layers[index]
                AoshingoLogoElementShape(element: layer.element)
                    .fill(AoshingoLogoPalette.color(for: layer.role, in: appearance))
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(clip)
        .accessibilityElement()
        .accessibilityLabel(Text(verbatim: "Aoshingo"))
        .accessibilityAddTraits(.isImage)
    }

    private var clip: AnyShape {
        switch appearance {
        case .tile, .mono: roundedTile ? AnyShape(AoshingoLogoTileShape()) : AnyShape(Rectangle())
        case .dark, .light: AnyShape(Rectangle())
        }
    }
}

#Preview("Logo") {
    VStack(spacing: 24) {
        HStack(spacing: 16) {
            AoshingoLogoMark().frame(width: 120, height: 120)
            AoshingoLogoMark(appearance: .mono).frame(width: 120, height: 120)
        }
        HStack(spacing: 16) {
            AoshingoLogoMark(appearance: .light).frame(width: 120, height: 120)
                .padding(8)
                .background(Color.white)
            AoshingoLogoMark(appearance: .dark).frame(width: 120, height: 120)
                .padding(8)
                .background(Color.black)
        }
        HStack(spacing: 16) {
            ForEach([60, 40, 29, 20], id: \.self) { size in
                AoshingoLogoMark().frame(width: CGFloat(size), height: CGFloat(size))
            }
        }
    }
    .padding()
}
