// SPDX-License-Identifier: Apache-2.0

import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @AppStorage(SettingsKey.colorMode) private var colorMode: SignalColorMode = .automatic
    @AppStorage(SettingsKey.collectionConsent) private var consent: CollectionConsent = .undecided

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
                        LabeledContent("実測データの提供", value: consent == .granted ? String(localized: "協力する") : String(localized: "協力しない"))
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
                    get: { consent == .granted },
                    set: { newValue in
                        let decision: CollectionConsent = newValue ? .granted : .declined
                        consent = decision
                        model.applyConsent(decision)
                    }
                ))
            } footer: {
                Text("オフにすると、まだ送信していないデータはすぐに削除されます。")
            }

            if field.isEnabled {
                Section("状態") {
                    if field.serverURL == nil {
                        Label("このビルドには送信先が設定されていないため、データは端末内にだけ保存されます。", systemImage: "exclamationmark.triangle")
                    }
                    if !field.isAttestationSupported {
                        Label("この端末では App Attest を使えないため送信できません（シミュレーターなど）。", systemImage: "exclamationmark.triangle")
                    }
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
                    .disabled(field.serverURL == nil || !field.isAttestationSupported)
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
