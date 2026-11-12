// SPDX-License-Identifier: Apache-2.0

import PICSKit
import SwiftUI
import UniformTypeIdentifiers

/// Main screen. On compact widths (iPhone, iPhone Duo outer screen) the signal view comes first;
/// on regular widths (iPhone Duo inner screen, iPad) the intersection list and signals sit side by side.
/// Only standard containers and size classes are used, so the system adapts the layout and applies
/// Liquid Glass to bars and controls on iOS 26 and later.
struct ContentView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(SettingsKey.colorMode) private var colorMode: SignalColorMode = .automatic
    @State private var preferredColumn: NavigationSplitViewColumn = .detail
    @State private var showingSettings = false
    @State private var showingEstimates = false
    @State private var showingImporter = false

    private static let autoSelection = "auto"

    var body: some View {
        NavigationSplitView(preferredCompactColumn: $preferredColumn) {
            IntersectionListView(selection: selection)
                .navigationTitle("交差点")
        } detail: {
            NavigationStack {
                DetailContainer(colorMode: colorMode)
                    .navigationTitle("Aoshingo")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { toolbar }
            }
        }
        .safeAreaInset(edge: .bottom) { ReceiveControl() }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
        .sheet(isPresented: $showingEstimates) {
            TimingEstimateView()
        }
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.json, .plainText, .data]) { result in
            if case .success(let url) = result {
                model.startReplay(url)
            }
        }
    }

    private var selection: Binding<String?> {
        Binding(
            get: { model.selectedID ?? Self.autoSelection },
            set: { newValue in
                model.selectedID = newValue == Self.autoSelection ? nil : newValue
                preferredColumn = .detail
            }
        )
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button("デモを表示", systemImage: "play.rectangle") { model.startDemo() }
                Button("記録ファイルを再生", systemImage: "doc.badge.clock") { showingImporter = true }
            } label: {
                Label("その他", systemImage: "ellipsis")
            }
        }
        // The signal timing estimates are only for users who contribute field data, and only in
        // TestFlight and development builds (TimingModel.isFeatureAvailable).
        if model.timing.showsEstimates {
            ToolbarItem(placement: .topBarTrailing) {
                Button("推定", systemImage: "clock") { showingEstimates = true }
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button("設定", systemImage: "gearshape") { showingSettings = true }
        }
    }
}

/// Start/stop control at the bottom: a control, so it may use Liquid Glass.
private struct ReceiveControl: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.isActive {
                Button {
                    model.stop()
                } label: {
                    Label("停止", systemImage: "stop.fill")
                        .frame(maxWidth: .infinity)
                }
            } else {
                Button {
                    model.startLive()
                } label: {
                    Label("受信開始", systemImage: "antenna.radiowaves.left.and.right")
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .font(.title3.weight(.semibold))
        .controlSize(.large)
        .prominentControlStyle()
        .padding(.horizontal)
        .padding(.bottom, 8)
    }
}

extension View {
    /// Liquid Glass on iOS 26 and later, a bordered prominent button before that.
    @ViewBuilder
    func prominentControlStyle() -> some View {
        if #available(iOS 26.0, *) {
            buttonStyle(.glassProminent)
        } else {
            buttonStyle(.borderedProminent)
        }
    }
}

/// Banners, empty states and the selected intersection.
private struct DetailContainer: View {
    @Environment(AppModel.self) private var model
    let colorMode: SignalColorMode
    @State private var editedSlot: SlotEditTarget?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                banners
                if let state = model.displayedIntersection {
                    IntersectionDetailView(
                        state: state,
                        confirmed: model.confirmedSignals(for: state.id),
                        source: model.source,
                        isFollowingNearest: model.selectedID == nil,
                        colorMode: colorMode,
                        onEditSlot: { editedSlot = $0 }
                    )
                    // A different intersection is a different view: VoiceOver focus and view state
                    // must not carry over from the previous intersection's signals.
                    .id(state.id)
                } else {
                    EmptyStateView()
                }
            }
            .padding()
        }
        // Presented here, not in the detail view, so that a switch to another nearest
        // intersection does not close the settings while the user is typing a name.
        .sheet(item: $editedSlot) { target in
            SlotSettingsView(target: target)
        }
    }

    @ViewBuilder
    private var banners: some View {
        Text("補助情報です。必ず実際の信号と周囲の安全を確認してください。")
            .font(.footnote)
            .foregroundStyle(.secondary)
        switch model.source {
        case .demo:
            Banner(systemImage: "play.rectangle.fill", text: "デモ表示中：実際の信号ではありません")
        case .replay(let name):
            Banner(systemImage: "doc.badge.clock.fill", text: "記録を再生中：\(name)。実際の信号ではありません")
        case .idle, .live:
            EmptyView()
        }
        if model.replayLoadFailed {
            Banner(systemImage: "exclamationmark.triangle.fill", text: "記録ファイルを読み込めませんでした。") {
                model.dismissReplayError()
            }
        }
        if model.missedWhileInBackground {
            Banner(systemImage: "lock.fill", text: "画面を閉じている間は受信できません。表示を続けてください。") {
                model.dismissBackgroundNotice()
            }
        }
    }
}

private struct Banner: View {
    let systemImage: String
    let text: LocalizedStringKey
    var dismiss: (() -> Void)?

    var body: some View {
        HStack(alignment: .top) {
            Label(text, systemImage: systemImage)
                .font(.callout.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
            if let dismiss {
                Button(action: dismiss) {
                    Label("閉じる", systemImage: "xmark")
                        .labelStyle(.iconOnly)
                        // A tap target of at least 44 × 44 pt around the small icon.
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                // The extra area reaches into the banner's own 12 pt padding, so the banner keeps
                // its height and the icon stays where it was.
                .padding(.vertical, -12)
                .padding(.trailing, -12)
            }
        }
        .padding(12)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// What to show when no intersection has been heard.
private struct EmptyStateView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.source {
        case .idle:
            ContentUnavailableView {
                Label("受信していません", systemImage: "antenna.radiowaves.left.and.right")
            } description: {
                Text("高度化PICS に対応した交差点の近くで「受信開始」を押してください。対応交差点は全国で約 600 か所です。")
            } actions: {
                Button("デモを表示") { model.startDemo() }
            }
        case .live:
            bluetoothState
        case .demo, .replay:
            ProgressView()
                .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private var bluetoothState: some View {
        switch model.bluetooth {
        case .poweredOff:
            ContentUnavailableView(
                "Bluetooth がオフです",
                systemImage: "antenna.radiowaves.left.and.right.slash",
                description: Text("コントロールセンターまたは設定で Bluetooth をオンにしてください。")
            )
        case .unauthorized:
            ContentUnavailableView {
                Label("Bluetooth の使用が許可されていません", systemImage: "hand.raised")
            } description: {
                Text("設定アプリで Aoshingo に Bluetooth の使用を許可してください。")
            } actions: {
                Button("設定を開く") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
            }
        case .unsupported:
            ContentUnavailableView(
                "この端末では受信できません",
                systemImage: "exclamationmark.triangle",
                description: Text("Bluetooth Low Energy に対応した端末が必要です。")
            )
        case .unknown, .resetting, .poweredOn:
            ContentUnavailableView {
                Label("信号を探しています", systemImage: "dot.radiowaves.left.and.right")
            } description: {
                VStack(spacing: 8) {
                    Text("対応交差点の近くでは数秒で表示されます。画面を表示したままにしてください。")
                    Text("周囲の Bluetooth 広告：\(model.otherAdvertisementCount) 件")
                        .font(.footnote)
                    if model.rejectedPacketCount > 0 {
                        Text("破棄したパケット：\(model.rejectedPacketCount) 件")
                            .font(.footnote)
                        if let reason = model.lastRejection {
                            Text("最後に破棄した理由：\(reason)")
                                .font(.footnote)
                        }
                    }
                }
            }
        }
    }
}
