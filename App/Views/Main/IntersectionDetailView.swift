// SPDX-License-Identifier: Apache-2.0

import FieldDataKit
import PICSKit
import SwiftUI

/// Signals and raw data of one intersection.
struct IntersectionDetailView: View {
    let state: IntersectionState
    let confirmed: [PedestrianSignal?]
    let source: AppModel.Source
    let isFollowingNearest: Bool
    let colorMode: SignalColorMode

    @ScaledMetric(relativeTo: .body) private var tileWidth: CGFloat = 260
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// The widest minimum tile width that still fits the narrowest layout: iPad Slide Over is 320 pt
    /// wide, 288 pt inside the padding.
    private static let maximumTileMinimum: CGFloat = 280

    /// Side by side where there is room. At accessibility text sizes the scaled minimum would reach
    /// about 810 pt, and an adaptive grid does not shrink tiles below it, so one flexible column is used.
    private var columns: [GridItem] {
        if dynamicTypeSize.isAccessibilitySize {
            return [GridItem(.flexible(), spacing: 12)]
        }
        return [GridItem(.adaptive(minimum: min(tileWidth, Self.maximumTileMinimum)), spacing: 12)]
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let now = context.date
            let stale = source == .idle || state.isSignalStale(at: now)
            VStack(alignment: .leading, spacing: 16) {
                header(now: now, stale: stale)
                signals(stale: stale)
                Text("番号は信号データ内の並び順です。どの横断歩道の信号かはまだ確認できていません。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                IntersectionInfoSection(state: state, now: now)
                FieldTestSection(state: state, source: source)
                RawDataSection(state: state)
            }
        }
    }

    @ViewBuilder
    private func header(now: Date, stale: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Group {
                if let name = state.identifier, !name.isEmpty {
                    Text(verbatim: name)
                } else {
                    Text("名称未受信")
                }
            }
            .font(.title2.bold())
            .accessibilityAddTraits(.isHeader)
            Text("交差点 ID \(state.id)")
                .font(.subheadline.monospaced())
                .foregroundStyle(.secondary)
            Text(isFollowingNearest ? "最も近い交差点を自動で表示中" : "選択した交差点を表示中")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            freshness(now: now, stale: stale)
                .font(.subheadline.weight(.semibold))
                .padding(.top, 4)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func freshness(now: Date, stale: Bool) -> some View {
        if let age = state.signalAge(at: now) {
            let seconds = Int(age.rounded(.down))
            if source == .idle {
                Text("停止中 · 最終受信値（\(seconds) 秒前）")
            } else if stale {
                Label("更新なし · 最終信号受信 \(seconds) 秒前", systemImage: "exclamationmark.triangle.fill")
            } else {
                Text("信号データ受信中 · \(seconds) 秒前")
            }
        } else {
            Text("信号情報をまだ受信していません")
        }
    }

    @ViewBuilder
    private func signals(stale: Bool) -> some View {
        let slots = state.activeSlots
        if slots.isEmpty {
            if state.signals != nil {
                Text("この交差点の信号データには使用中の信号がありません。")
                    .foregroundStyle(.secondary)
            }
        } else {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(slots, id: \.slot) { slot in
                    let index = slot.slot - 1
                    let shown = index < confirmed.count ? confirmed[index] : nil
                    SignalSlotView(
                        intersectionName: state.spokenName,
                        slot: slot.slot,
                        signal: shown,
                        stale: stale,
                        mode: colorMode
                    )
                }
            }
        }
    }
}

/// Position, RSSI and packet counts.
private struct IntersectionInfoSection: View {
    let state: IntersectionState
    let now: Date

    var body: some View {
        GroupBox("交差点の情報") {
            VStack(alignment: .leading, spacing: 6) {
                if let coordinate = state.coordinate {
                    LabeledContent("位置", value: String(format: "%.6f, %.6f", coordinate.latitude, coordinate.longitude))
                } else {
                    LabeledContent("位置", value: String(localized: "未受信"))
                }
                if let rssi = state.rssi {
                    LabeledContent("電波強度", value: "\(rssi) dBm")
                }
                LabeledContent("受信パケット数", value: "\(state.count)")
                LabeledContent("最終受信", value: String(localized: "\(Int(max(0, now.timeIntervalSince(state.timestamp)))) 秒前"))
            }
            .font(.callout)
        }
    }
}

/// The open questions of the field test: Service UUID, transmitters, advertising intervals, and
/// tester labels for which slot belongs to which crosswalk.
private struct FieldTestSection: View {
    let state: IntersectionState
    let source: AppModel.Source
    @Environment(AppModel.self) private var model

    var body: some View {
        GroupBox("現地確認") {
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Service UUID") {
                    if state.serviceUUIDs.isEmpty {
                        Text("なし")
                    } else {
                        Text(state.serviceUUIDs.sorted().joined(separator: ", ")).monospaced()
                    }
                }
                LabeledContent("送信機の数", value: "\(state.emitters.count)")
                if !state.localNames.isEmpty {
                    LabeledContent("ローカル名", value: state.localNames.sorted().joined(separator: ", "))
                }
                ForEach(state.messageTypes.keys.sorted(), id: \.self) { type in
                    if let stats = state.messageTypes[type] {
                        LabeledContent("Type \(Int(type))") {
                            Text(Self.describe(stats))
                        }
                    }
                }
                Text("Service UUID が「なし」の場合、iOS のバックグラウンドでは受信できません。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if source == .live {
                    if model.field.isEnabled {
                        Divider()
                        FieldLabelControls(state: state)
                    } else if model.field.canContribute {
                        Text("実測データの提供をオンにすると、どの番号がどの横断歩道の信号かを記録できます（テスター向け）。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .font(.callout)
        }
    }

    private static func describe(_ stats: MessageTypeStatistics) -> String {
        guard let mean = stats.meanInterval, let shortest = stats.shortestInterval else {
            return String(localized: "\(stats.count) 件")
        }
        let meanText = mean.formatted(.number.precision(.fractionLength(2)))
        let shortestText = shortest.formatted(.number.precision(.fractionLength(2)))
        return String(localized: "\(stats.count) 件 · 平均間隔 \(meanText) 秒 · 最短 \(shortestText) 秒")
    }
}

/// Buttons for tester labels, uploaded with the field data (docs/field-test.md).
private struct FieldLabelControls: View {
    let state: IntersectionState
    @Environment(AppModel.self) private var model
    @State private var feedback: String?
    @ScaledMetric(relativeTo: .body) private var buttonWidth: CGFloat = 80

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("横断歩道の対応を記録（テスター向け）")
                .font(.subheadline.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Text("横断歩道の手前で、渡る方向に iPhone を向けてから、その横断歩道の信号の番号を押してください。端末の向きと、交差点から見たおおまかな位置を記録して、実測データと一緒に送ります。")
                .font(.footnote)
                .foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: buttonWidth), spacing: 8)], alignment: .leading, spacing: 8) {
                ForEach(state.activeSlots, id: \.slot) { slot in
                    Button("\(slot.slot) 番") {
                        record(.crosswalk, slot: slot.slot)
                    }
                    .accessibilityHint("いま向いている方向の横断歩道を、この番号の信号として記録します")
                }
            }
            .buttonStyle(.bordered)
            Button("押しボタンを押した") {
                record(.button, slot: nil)
            }
            .buttonStyle(.bordered)
            .accessibilityHint("押しボタンを押した時刻を記録します")
            if let feedback {
                Text(feedback)
                    .font(.footnote)
            }
        }
    }

    private func record(_ kind: FieldReport.Label.Kind, slot: Int?) {
        let id = state.id
        Task {
            let result = await model.field.label(kind, slot: slot, intersectionID: id)
            let message = Self.message(for: result, kind: kind, slot: slot)
            feedback = message
            AccessibilityAnnouncer.announce(message)
        }
    }

    private static func message(for result: FieldDataModel.LabelResult, kind: FieldReport.Label.Kind, slot: Int?) -> String {
        switch result {
        case .recorded(let heading):
            switch kind {
            case .crosswalk:
                if let slot, let heading {
                    return String(localized: "\(slot) 番を記録しました（\(directionName(heading))向き）")
                }
                return String(localized: "記録しました")
            case .button:
                return String(localized: "押しボタンを押したことを記録しました")
            }
        case .noHeading:
            return String(localized: "端末の向きが分からないため記録しませんでした。iPhone を水平に持って少し待ち、もう一度押してください。")
        case .notRecorded:
            return String(localized: "記録できませんでした")
        }
    }

    /// Names of the eight 45° sectors, 0 = north, clockwise (Bucketing.sector).
    private static func directionName(_ sector: Int) -> String {
        switch sector {
        case 0: String(localized: "北")
        case 1: String(localized: "北東")
        case 2: String(localized: "東")
        case 3: String(localized: "南東")
        case 4: String(localized: "南")
        case 5: String(localized: "南西")
        case 6: String(localized: "西")
        default: String(localized: "北西")
        }
    }
}

/// Hex dumps and parsed JSON, like ble-pics-viewer's monitor.
private struct RawDataSection: View {
    let state: IntersectionState
    @State private var expanded = false

    var body: some View {
        GroupBox {
            DisclosureGroup("受信データ（開発者向け）", isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(state.messageTypes.keys.sorted(), id: \.self) { type in
                        if let stats = state.messageTypes[type] {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Type \(Int(type)) の最新パケット")
                                    .font(.caption.weight(.semibold))
                                Text(Hex.string(stats.lastRaw))
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("解析結果（最新）")
                            .font(.caption.weight(.semibold))
                        Text(state.latest.prettyJSON())
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                    if !state.history.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("直近 30 秒の信号履歴（最大 5 件）")
                                .font(.caption.weight(.semibold))
                            ForEach(state.history, id: \.timestamp) { entry in
                                Text(Self.describe(entry))
                                    .font(.caption.monospaced())
                            }
                        }
                    }
                }
                .padding(.top, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private static func describe(_ entry: SignalHistoryEntry) -> String {
        let time = entry.timestamp.formatted(.dateTime.hour().minute().second())
        let signals = entry.signals.enumerated()
            .filter { $0.element.state.isInUse }
            .map { "\($0.offset + 1):\($0.element.state.viewerLabel)(\($0.element.remaining.map(String.init) ?? "—"))" }
            .joined(separator: " ")
        return "\(time)  \(signals)"
    }
}
