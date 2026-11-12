// SPDX-License-Identifier: Apache-2.0

import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @AppStorage(SettingsKey.colorMode) private var colorMode: SignalColorMode = .automatic
    @AppStorage(SettingsKey.collectionConsent) private var consent: CollectionConsent = .undecided
    @AppStorage(SettingsKey.announceSignalWarnings)
    private var announceSignalWarnings = SettingsKey.announceSignalWarningsDefault
    @State private var confirmingSlotReset = false

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                Section {
                    Picker("色の表示", selection: $colorMode) {
                        ForEach(SignalColorMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    Text(colorMode.detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("表示")
                } footer: {
                    Text("どのモードでも、色だけでなく形と文字で信号を示します。")
                }

                Section {
                    Toggle("すべての信号の青点滅・赤を読み上げる", isOn: $announceSignalWarnings)
                } header: {
                    Text("VoiceOver")
                } footer: {
                    Text("オンにすると、表示中の交差点のどの信号でも、青点滅・赤・信号なしに変わったときと受信が途切れたときに、VoiceOver のフォーカスの位置にかかわらず読み上げます。青に変わったことは、フォーカスしている信号と、「青に変わったときも知らせる」をオンにした信号だけ読み上げます。オフにすると、フォーカスしている信号と、音や振動を選んだ信号、「青に変わったときも知らせる」をオンにした信号の変化だけを読み上げます。")
                }

                Section {
                    LabeledContent("設定した交差点", value: "\(model.slotPreferences.preferences.count)")
                    Button("信号ごとの設定をすべて消去", role: .destructive) {
                        confirmingSlotReset = true
                    }
                    .disabled(model.slotPreferences.preferences.isEmpty)
                    .confirmationDialog("信号ごとの設定をすべて消去しますか？", isPresented: $confirmingSlotReset, titleVisibility: .visible) {
                        Button("すべて消去", role: .destructive) {
                            model.slotPreferences.removeAll()
                        }
                    } message: {
                        Text("すべての交差点の信号の名前、知らせ方、音、振動が元に戻ります。")
                    }
                } header: {
                    Text("信号ごとの設定")
                } footer: {
                    Text("信号の名前、知らせ方、音、振動は、交差点の画面で各信号の設定ボタン（VoiceOver ではアクション）から変えられます。この端末にだけ保存し、送信しません。")
                }

                Section {
                    Toggle("受信中は画面を消さない", isOn: $model.keepScreenOn)
                } header: {
                    Text("受信")
                } footer: {
                    Text("画面が消えると受信が止まります。VoiceOver の画面カーテンを使うと、画面を暗くしたまま受信を続けられます。")
                }

                Section {
                    NavigationLink {
                        FieldDataSettingsView()
                    } label: {
                        LabeledContent("実測データの提供", value: consent == .granted && model.field.canContribute ? String(localized: "協力する") : String(localized: "協力しない"))
                    }
                }

                Section("開発者向け") {
                    NavigationLink("受信データの記録") {
                        RecordingsView()
                    }
                }

                Section("情報") {
                    LabeledContent("バージョン", value: Self.version)
                    NavigationLink("謝辞・ライセンス") { AcknowledgementsView() }
                    Link("ソースコード（GitHub）", destination: AppLinks.repository)
                    Link("プライバシーポリシー", destination: AppLinks.privacyPolicy)
                    Text("Aoshingo は非公式アプリです。警察庁、信号機メーカー、信GO! とは関係ありません。受信専用で、信号機に送信することはありません。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完了") { dismiss() }
                }
            }
        }
    }

    private static var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(short) (\(build))"
    }
}

/// Field-data switch, status and the full explanation.
struct FieldDataSettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(SettingsKey.collectionConsent) private var consent: CollectionConsent = .undecided

    var body: some View {
        let field = model.field
        Form {
            Section {
                Toggle("実測データを提供する", isOn: Binding(
                    get: { consent == .granted && field.canContribute },
                    set: { newValue in
                        let decision: CollectionConsent = newValue ? .granted : .declined
                        consent = decision
                        model.applyConsent(decision)
                    }
                ))
                .disabled(!field.canContribute)
            } footer: {
                if let reason = field.unavailability {
                    FieldDataUnavailableNotice(reason: reason)
                } else {
                    Text("オフにすると、まだ送信していないデータと、受け取った時刻表はすぐに削除されます。")
                }
            }

            if field.isEnabled {
                Section("状態") {
                    LabeledContent("収集中の観測", value: "\(field.status.bufferedObservations)")
                    LabeledContent("収集中の信号変化", value: "\(field.status.bufferedTransitions)")
                    LabeledContent("送信待ちの報告", value: "\(field.status.pendingReports)")
                    if let lastUpload = field.status.lastUpload {
                        LabeledContent("最終送信", value: lastUpload.formatted(date: .abbreviated, time: .shortened))
                    }
                    if let error = field.status.lastError {
                        LabeledContent("最後のエラー", value: error)
                    }
                    Button("今すぐ送信") {
                        Task { await field.flushAndUpload(force: true) }
                    }
                }
            }

            Section {
                CollectionDetails()
                Link("プライバシーポリシー", destination: AppLinks.privacyPolicy)
            }
        }
        .navigationTitle("実測データの提供")
        .task { await field.refreshStatus() }
    }
}

/// Why field data cannot be contributed from this build or device. Shown where the choice is made.
struct FieldDataUnavailableNotice: View {
    let reason: FieldDataModel.Unavailability

    var body: some View {
        switch reason {
        case .noServer:
            Text("このビルドには送信先が設定されていないため、実測データを提供できません。")
        case .attestationUnsupported:
            Text("この端末では App Attest を使えないため送信できません（シミュレーターなど）。")
        }
    }
}
