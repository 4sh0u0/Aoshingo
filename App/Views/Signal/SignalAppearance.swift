// SPDX-License-Identifier: Apache-2.0

import PICSKit
import SwiftUI

/// How one pedestrian signal is drawn. Colour is never the only cue: every state also has its own
/// symbol and words, in every colour mode.
struct SignalAppearance: Equatable {
    var symbol: String
    var title: LocalizedStringKey
    /// Short instruction, for example 進める / 止まれ.
    var instruction: LocalizedStringKey
    var accessibilityTitle: String
    var fill: Color
    var foreground: Color
    var isDashed: Bool
    var blinks: Bool

    /// Colours from the Colour Universal Design recommended palette ver.4 (screen RGB).
    enum CUD {
        static let blue = Color(red: 0x00 / 255, green: 0x5A / 255, blue: 0xFF / 255)
        static let red = Color(red: 0xFF / 255, green: 0x4B / 255, blue: 0x00 / 255)
    }

    enum Standard {
        /// Japanese 青 signals are blue-green.
        static let green = Color(red: 0x00 / 255, green: 0x99 / 255, blue: 0x80 / 255)
        static let red = Color(red: 0xD7 / 255, green: 0x26 / 255, blue: 0x1E / 255)
    }

    /// - Parameters:
    ///   - state: the confirmed state, or `nil` while signal data is arriving but nothing is confirmed
    ///     yet (a 青 or 青点滅 waits for a second matching packet at least 0.5 s later, see `SignalDebouncer`).
    ///   - stale: no Type 2 for five seconds; the last colour must not be shown as current.
    static func make(
        state: SignalState?,
        stale: Bool,
        mode: SignalColorMode,
        differentiateWithoutColor: Bool
    ) -> SignalAppearance {
        let resolved: SignalColorMode = switch mode {
        case .automatic: differentiateWithoutColor ? .colorUniversal : .standard
        default: mode
        }
        let neutralFill = Color(uiColor: .systemGray4)
        if stale {
            return SignalAppearance(
                symbol: "antenna.radiowaves.left.and.right.slash",
                title: "更新なし",
                instruction: "実際の信号を確認",
                accessibilityTitle: String(localized: "更新なし。実際の信号を確認してください"),
                fill: neutralFill,
                foreground: .primary,
                isDashed: false,
                blinks: false
            )
        }
        guard let state else {
            // Data is current, but a safer state is shown only after it has been confirmed.
            return SignalAppearance(
                symbol: "hourglass",
                title: "判定中",
                instruction: "実際の信号を確認",
                accessibilityTitle: String(localized: "判定中。実際の信号を確認してください"),
                fill: neutralFill,
                foreground: .primary,
                isDashed: false,
                blinks: false
            )
        }

        switch state {
        case .green, .blinkGreen:
            let blinking = state == .blinkGreen
            let (fill, foreground): (Color, Color) = switch resolved {
            case .colorUniversal: (CUD.blue, .white)
            case .monochrome: (.white, .black)
            default: (Standard.green, .white)
            }
            return SignalAppearance(
                symbol: "figure.walk",
                title: blinking ? "青点滅" : "青",
                instruction: blinking ? "渡り始めないで" : "進める",
                accessibilityTitle: blinking
                    ? String(localized: "青点滅。渡り始めないでください")
                    : String(localized: "青。進めます"),
                fill: fill,
                foreground: foreground,
                isDashed: blinking,
                blinks: blinking
            )
        case .red:
            let (fill, foreground): (Color, Color) = switch resolved {
            case .colorUniversal: (CUD.red, .black)
            case .monochrome: (.black, .white)
            default: (Standard.red, .white)
            }
            return SignalAppearance(
                symbol: "figure.stand",
                title: "赤",
                instruction: "止まれ",
                accessibilityTitle: String(localized: "赤。止まってください"),
                fill: fill,
                foreground: foreground,
                isDashed: false,
                blinks: false
            )
        case .noSignal:
            return SignalAppearance(
                symbol: "lightswitch.off",
                title: "信号なし",
                instruction: "実際の信号を確認",
                accessibilityTitle: String(localized: "信号なし。実際の信号を確認してください"),
                fill: neutralFill,
                foreground: .primary,
                isDashed: false,
                blinks: false
            )
        case .none, .unknown:
            return SignalAppearance(
                symbol: "questionmark",
                title: "不明",
                instruction: "実際の信号を確認",
                accessibilityTitle: String(localized: "不明。実際の信号を確認してください"),
                fill: neutralFill,
                foreground: .primary,
                isDashed: false,
                blinks: false
            )
        }
    }
}

extension SignalColorMode {
    var title: LocalizedStringKey {
        switch self {
        case .automatic: "自動"
        case .standard: "標準"
        case .colorUniversal: "色覚サポート"
        case .monochrome: "モノクロ"
        }
    }

    var detail: LocalizedStringKey {
        switch self {
        case .automatic: "通常は標準。iOS の「カラー以外で区別」がオンのときは色覚サポートになります。"
        case .standard: "青緑と赤。形と文字も必ず表示します。"
        case .colorUniversal: "カラーユニバーサルデザイン推奨配色の青と朱色。色の見え方の違いがあっても区別しやすい組み合わせです。"
        case .monochrome: "白黒と形だけで表示します。青は白地、赤は黒地です。"
        }
    }
}
