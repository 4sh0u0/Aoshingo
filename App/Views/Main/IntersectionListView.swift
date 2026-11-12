// SPDX-License-Identifier: Apache-2.0

import PICSKit
import SwiftUI

/// Every intersection heard in this session, plus the "follow the nearest" choice.
struct IntersectionListView: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: String?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let now = context.date
            // The intersection "follow the nearest" shows, so the badge and the signal view agree.
            let nearestID = model.followedID
            List(selection: $selection) {
                Section {
                    Label("最も近い交差点を自動表示", systemImage: "location.north.circle")
                        .tag("auto")
                }
                Section("受信した交差点") {
                    if model.store.isEmpty {
                        Text("まだありません")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.store.all.reversed()) { state in
                        IntersectionRow(state: state, isNearest: state.id == nearestID, now: now)
                            .tag(state.id)
                    }
                }
            }
        }
    }
}

private struct IntersectionRow: View {
    let state: IntersectionState
    let isNearest: Bool
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // The badge goes under the name when both do not fit on one line, as with large text in
            // the narrow list column, so that neither is broken up letter by letter.
            ViewThatFits(in: .horizontal) {
                HStack {
                    name
                    badge
                }
                VStack(alignment: .leading, spacing: 2) {
                    name
                    badge
                }
            }
            Text(verbatim: state.id)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                if let rssi = state.rssi {
                    Text("\(rssi) dBm")
                }
                Text(state.isSignalStale(at: now) ? "更新なし" : "受信中")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var name: some View {
        Group {
            if let name = state.identifier, !name.isEmpty {
                Text(verbatim: name)
            } else {
                Text("名称未受信")
            }
        }
        .font(.headline)
    }

    @ViewBuilder
    private var badge: some View {
        if isNearest {
            Text("最寄り")
                .font(.caption.weight(.bold))
                .fixedSize()
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.tint.opacity(0.15), in: Capsule())
        }
    }
}
