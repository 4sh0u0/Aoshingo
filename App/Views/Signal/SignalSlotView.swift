// SPDX-License-Identifier: Apache-2.0

import PICSKit
import SwiftUI

/// One pedestrian signal slot: symbol, words and the remaining-time indication.
///
/// The signal area is content, so it uses an opaque background and never Liquid Glass.
/// Slot numbers carry no direction: which crossing a slot belongs to is not known, unless the user
/// has checked it and named the slot (`SlotPreference`).
struct SignalSlotView: View {
    /// Spoken first by VoiceOver, so a signal is never heard without the intersection it belongs to.
    let intersectionName: String
    let slot: Int
    let signal: PedestrianSignal?
    let stale: Bool
    let mode: SignalColorMode
    var preference = SlotPreference()
    /// Opens this signal's settings (name, notifications, sound and vibration).
    var onEdit: (() -> Void)?

    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AccessibilityFocusState private var isAccessibilityFocused: Bool
    @AppStorage(SettingsKey.announceSignalWarnings)
    private var warningsAnnouncedForEverySignal = SettingsKey.announceSignalWarningsDefault

    private var appearance: SignalAppearance {
        SignalAppearance.make(
            state: signal?.state,
            stale: stale,
            mode: mode,
            differentiateWithoutColor: differentiateWithoutColor
        )
    }

    /// 「n 番」, or the name the user gave the signal.
    private var spokenSlotName: String {
        preference.spokenName ?? String(localized: "\(slot) 番")
    }

    /// The same condition that AppModel gives `SignalChangeMonitor` for this slot.
    private var condition: SignalCondition {
        if stale { return .stale }
        guard let signal else { return .pending }
        return .state(signal.state)
    }

    var body: some View {
        let appearance = appearance
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        VStack(spacing: 12) {
            header
            Image(systemName: appearance.symbol)
                .font(.system(size: dynamicTypeSize.isAccessibilitySize ? 96 : 72, weight: .bold))
                .modifier(BlinkModifier(active: appearance.blinks && !reduceMotion))
                .accessibilityHidden(true)
            VStack(spacing: 2) {
                Text(appearance.title)
                    .font(.largeTitle.bold())
                Text(appearance.instruction)
                    .font(.title3.weight(.semibold))
            }
            .multilineTextAlignment(.center)
            if !stale, let signal, signal.state != .none {
                RemainingGauge(remaining: signal.remaining, foreground: appearance.foreground)
            }
        }
        .foregroundStyle(appearance.foreground)
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(appearance.fill, in: shape)
        .overlay {
            shape.strokeBorder(
                appearance.foreground.opacity(appearance.isDashed ? 1 : 0.35),
                style: StrokeStyle(lineWidth: appearance.isDashed ? 6 : 1.5, dash: appearance.isDashed ? [14, 10] : [])
            )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel(appearance))
        // The remaining time is the value, so its steps never make VoiceOver re-read the label.
        .accessibilityValue(remainingDescription)
        .accessibilityFocused($isAccessibilityFocused)
        .accessibilityActions {
            if let onEdit {
                Button("この信号の設定", action: onEdit)
            }
        }
        .onChange(of: appearance.accessibilityTitle) { _, title in
            // Only a real change of what the signal means is announced here, and only for the slot
            // that VoiceOver is on (which is what `.updatesFrequently` used to re-read). The changes
            // that AppModel announces wherever the focus is (warnings for every signal unless that
            // is switched off in Settings, and 青 for a signal the user chose) are left to it.
            guard isAccessibilityFocused else { return }
            let watch = preference.watch(warningsForEverySignal: warningsAnnouncedForEverySignal)
            if watch.reports(condition) { return }
            AccessibilityAnnouncer.announce([spokenSlotName, title].joined(separator: "、"))
        }
    }

    /// The name the user gave the signal above its number, and the button for its settings.
    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                if let name = preference.displayName {
                    Text(verbatim: name)
                        .font(.headline)
                    Text("\(slot) 番")
                        .font(.subheadline)
                } else {
                    Text("\(slot) 番")
                        .font(.headline)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let onEdit {
                Button(action: onEdit) {
                    Label("この信号の設定", systemImage: "slider.horizontal.3")
                        .labelStyle(.iconOnly)
                        .font(.title3)
                        // A tap target of at least 44 × 44 pt around the small icon.
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // The extra area reaches into the tile's padding, so the header keeps its height.
                .padding(.vertical, -12)
                .padding(.trailing, -12)
            }
        }
    }

    private func accessibilityLabel(_ appearance: SignalAppearance) -> String {
        [intersectionName, spokenSlotName, appearance.accessibilityTitle].joined(separator: "、")
    }

    /// Spoken as the accessibility value; empty when there is nothing current to say.
    private var remainingDescription: String {
        guard !stale, let remaining = signal?.remaining else { return "" }
        return String(localized: "残り目安 \(remaining) / 8")
    }
}

/// Blinks the walking figure for 青点滅, on and off every half second, like the real signal head.
/// Only the symbol blinks: the words and the remaining-time text keep their full contrast in both
/// phases. With Reduce Motion the dashed border alone marks it.
private struct BlinkModifier: ViewModifier {
    /// Opacity of the symbol in the off phase; it stays faintly visible so the shape is not lost.
    static let offOpacity = 0.2

    let active: Bool

    func body(content: Content) -> some View {
        if active {
            TimelineView(.periodic(from: .now, by: 0.5)) { context in
                let on = Int(context.date.timeIntervalSinceReferenceDate * 2).isMultiple(of: 2)
                content.opacity(on ? 1 : Self.offOpacity)
            }
        } else {
            content
        }
    }
}

/// Eight segments for the remaining-time indication. It is a rough guide, not seconds.
struct RemainingGauge: View {
    let remaining: Int?
    let foreground: Color

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                ForEach(1...8, id: \.self) { index in
                    let filled = remaining.map { index <= $0 } ?? false
                    Capsule()
                        .fill(filled ? foreground : foreground.opacity(0.2))
                        .frame(height: 10)
                }
            }
            Group {
                if let remaining {
                    Text("残り目安 \(remaining)/8")
                } else {
                    Text("残り目安 —")
                }
            }
            .font(.footnote.weight(.medium))
        }
        .accessibilityHidden(true)
    }
}

#Preview("Signals") {
    ScrollView {
        VStack {
            SignalSlotView(
                intersectionName: DemoAdvertiser.name, slot: 1, signal: .init(remaining: 5, state: .green), stale: false, mode: .standard,
                preference: SlotPreference(name: "駅の方へ"), onEdit: {}
            )
            SignalSlotView(intersectionName: DemoAdvertiser.name, slot: 2, signal: .init(remaining: 2, state: .blinkGreen), stale: false, mode: .colorUniversal)
            SignalSlotView(intersectionName: DemoAdvertiser.name, slot: 3, signal: .init(remaining: nil, state: .red), stale: false, mode: .monochrome)
            SignalSlotView(intersectionName: DemoAdvertiser.name, slot: 4, signal: .init(remaining: 3, state: .red), stale: true, mode: .standard)
            SignalSlotView(intersectionName: DemoAdvertiser.name, slot: 5, signal: nil, stale: false, mode: .standard)
        }
        .padding()
    }
}
