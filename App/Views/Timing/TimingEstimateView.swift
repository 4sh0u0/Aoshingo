// SPDX-License-Identifier: Apache-2.0

import FieldDataKit
import PICSKit
import SwiftUI

/// The 「推定」 sheet: for the nearest intersections with timing plans, a range of seconds to the
/// next start of green (docs/timing-estimation.md, 「表示の規則」).
///
/// An estimate is never a signal state, so this screen deliberately has no signal colours (the
/// accent colour is replaced by the primary colour), names no colour except in 「青の始まり」, and
/// makes no announcement, haptic or notification. It refreshes once a second while open.
struct TimingEstimateView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                content(at: context.date)
            }
            .navigationTitle("推定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完了") { dismiss() }
                }
            }
        }
        // Neutral: nothing on this screen may look like a signal colour.
        .tint(Color.primary)
        .onAppear {
            model.timing.startLocationUpdates()
            model.timing.refreshIfNeeded()
        }
        .onDisappear {
            model.timing.stopLocationUpdates()
        }
        .onChange(of: model.field.isEnabled) { _, enabled in
            // The estimates are for contributors only.
            if !enabled { dismiss() }
        }
    }

    private func content(at now: Date) -> some View {
        let timing = model.timing
        let receiving = timing.isReceiving(at: now)
        let user = timing.userPosition(at: now)
        let rows = timing.rows(at: now, user: user)
        return List {
            Section {
                Label {
                    Text("推定は横断の判断に使えません。実際の信号と音響信号を必ず確かめてください。")
                        .font(.body.weight(.semibold))
                } icon: {
                    Image(systemName: "exclamationmark.circle")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
            }

            if timing.plans == nil {
                Section {
                    Text("時刻表をまだ受け取っていません。")
                        .foregroundStyle(.secondary)
                }
            } else if receiving {
                // A live packet of any intersection within the last 10 s: no estimate anywhere.
                Section {
                    Text("信号を受信しているあいだは推定を表示しません。受信中の信号をご覧ください。")
                        .foregroundStyle(.secondary)
                }
            } else if timing.plansAreOutdated(at: now) {
                Section {
                    Text("時刻表が古いため推定を表示しません。")
                        .foregroundStyle(.secondary)
                }
            } else if user == nil {
                Section {
                    Text("現在地が分からないため推定を表示しません")
                        .foregroundStyle(.secondary)
                    if timing.isLocationDenied {
                        Text("位置情報の利用が許可されていません。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            } else if rows.isEmpty {
                Section {
                    Text("近くに時刻表のある交差点はありません。")
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(rows) { row in
                    IntersectionEstimateSection(row: row)
                }
            }

            Section {
                Text("推定は、集まった実測データから求めた信号の周期と青の始まりの時刻（時刻表）からの計算です。周期が決まっていない信号や、祝日・年末年始には出ません。受信した信号と 5 秒より大きくずれた時間帯は、その日のうちは出しません。")
                if let fetchedAt = timing.fetchedAt {
                    Text("時刻表の取得：\(fetchedAt.formatted(date: .abbreviated, time: .shortened))")
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }
}

/// One intersection: its name and distance, then a line per signal slot or the reason no estimate
/// is shown.
private struct IntersectionEstimateSection: View {
    @Environment(AppModel.self) private var model
    let row: TimingModel.Row

    var body: some View {
        Section {
            switch row.availability {
            case .available:
                ForEach(row.slots) { slot in
                    slotRow(slot)
                }
            case .tooClose:
                message("交差点の近くでは推定を表示しません。信号を受信してください。")
            case .receiving:
                message("受信中の信号をご覧ください。")
            case .unknownLocation:
                message("現在地が分からないため推定を表示しません")
            }
        } header: {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: name)
                Spacer()
                if let distance = distanceText {
                    Text(distance)
                }
            }
            .textCase(nil)
            .accessibilityElement(children: .combine)
        }
    }

    private var name: String { row.name ?? row.id }

    private var distanceText: String? {
        guard let distance = row.distance, distance.isFinite, distance >= 0 else { return nil }
        if distance < 1000 {
            let meters = Int((distance / 10).rounded()) * 10
            return String(localized: "約 \(meters) m")
        }
        let kilometers = (distance / 1000).formatted(.number.precision(.fractionLength(1)))
        return String(localized: "約 \(kilometers) km")
    }

    private func slotRow(_ slot: TimingModel.SlotEstimate) -> some View {
        let preference = model.slotPreferences[row.id, slot.slot]
        let slotName = preference.displayName ?? String(localized: "\(slot.slot) 番")
        let spokenSlot = preference.spokenName ?? String(localized: "\(slot.slot) 番")
        return HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: "clock")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: slotName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let estimate = slot.estimate {
                    Text("次の青の始まり　およそ \(estimate.lowerSeconds)〜\(estimate.upperSeconds) 秒後（推定）")
                } else {
                    Text("この時間帯の推定はありません")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenLabel(slot: spokenSlot, estimate: slot.estimate))
    }

    private func spokenLabel(slot: String, estimate: TimingEstimate?) -> String {
        if let estimate {
            return String(localized: "推定、\(name)、\(slot)、次の青の始まり、およそ \(estimate.lowerSeconds)〜\(estimate.upperSeconds) 秒後")
        }
        return String(localized: "推定、\(name)、\(slot)、この時間帯の推定はありません")
    }

    private func message(_ text: LocalizedStringResource) -> some View {
        let localized = String(localized: text)
        return Text(verbatim: localized)
            .foregroundStyle(.secondary)
            .accessibilityLabel(String(localized: "推定、\(name)、\(localized)"))
    }
}
