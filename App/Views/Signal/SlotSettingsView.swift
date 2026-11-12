// SPDX-License-Identifier: Apache-2.0

import PICSKit
import SwiftUI

/// The signal whose settings are being edited.
struct SlotEditTarget: Identifiable, Hashable {
    let intersectionID: String
    /// The Type 0 name when it had been received, for the heading only.
    let intersectionName: String?
    let slot: Int

    var id: String { "\(intersectionID)#\(slot)" }
}

/// Name, notifications, sound and vibration of one signal of one intersection, like the settings
/// 信GO! has for each direction. Every change is saved at once, on this device only.
struct SlotSettingsView: View {
    let target: SlotEditTarget

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    private var preference: Binding<SlotPreference> {
        Binding(
            get: { model.slotPreferences[target.intersectionID, target.slot] },
            set: { model.slotPreferences[target.intersectionID, target.slot] = $0 }
        )
    }

    var body: some View {
        let current = preference.wrappedValue
        NavigationStack {
            Form {
                Section {
                    LabeledContent("交差点名") {
                        if let name = target.intersectionName, !name.isEmpty {
                            Text(verbatim: name)
                        } else {
                            Text("名称未受信")
                        }
                    }
                    LabeledContent("交差点 ID", value: target.intersectionID)
                    LabeledContent("信号", value: String(localized: "\(target.slot) 番"))
                } footer: {
                    Text("ここでの設定は、この交差点のこの信号だけに使います。設定はこの端末にだけ保存し、送信しません。")
                }

                Section {
                    TextField("名前", text: preference.name, prompt: Text("例：駅の方へ渡る"))
                    TextField("読み（任意）", text: preference.reading, prompt: Text("例：えきのほうへわたる"))
                } header: {
                    Text("名前")
                } footer: {
                    Text("「\(target.slot) 番」の代わりに表示し、読み上げます。渡る方向で名付けると分かりやすくなります（例：「南北に渡る」「駅の方へ」）。読みを入れると、読み上げには読みを使います。")
                }

                Section {
                    Toggle("この信号を知らせる", isOn: Binding(
                        get: { !preference.wrappedValue.isMuted },
                        set: { preference.wrappedValue.isMuted = !$0 }
                    ))
                    Toggle("青に変わったときも知らせる", isOn: preference.announcesGreen)
                        .disabled(current.isMuted)
                } header: {
                    Text("知らせ方")
                } footer: {
                    Text("「この信号を知らせる」をオフにすると、この信号は読み上げず、音も振動も鳴らさず、ほかの信号の下にたたんで表示します。「青に変わったときも知らせる」は、自分が渡る横断歩道の信号だと現地で確かめた場合だけオンにしてください。オンにすると、VoiceOver のフォーカスの位置にかかわらず、青に変わったことも読み上げます。表示も読み上げも補助情報です。必ず実際の信号と周囲の安全を確認してください。")
                }

                Section {
                    Picker("音", selection: preference.sound) {
                        ForEach(SignalCueSound.allCases, id: \.self) { sound in
                            Text(sound.title).tag(sound)
                        }
                    }
                    if SignalCuePlayer.supportsVibration {
                        Picker("振動", selection: preference.vibration) {
                            ForEach(SignalCueVibration.allCases, id: \.self) { vibration in
                                Text(vibration.title).tag(vibration)
                            }
                        }
                    }
                    Button("試しに鳴らす") {
                        model.cuePlayer.play([SignalCuePlayer.Cue(sound: current.sound, vibration: current.vibration)])
                    }
                    .disabled(!current.hasCue)
                } header: {
                    Text("音と振動")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("この信号を知らせるときに、読み上げの前に鳴らします。音か振動を選んだ信号は、設定の「すべての信号の青点滅・赤を読み上げる」がオフでも、青点滅・赤などに変わったことを知らせます。音は消音モードでも鳴ります。ほかの交差点で渡る信号にも同じ音を選んでおくと、自分が渡る信号を音で聞き分けられます。")
                        if !SignalCuePlayer.supportsVibration {
                            Text("この端末は振動に対応していません。")
                        }
                    }
                }

                Section {
                    Button("この信号の設定を元に戻す", role: .destructive) {
                        preference.wrappedValue = SlotPreference()
                    }
                    .disabled(current.isDefault)
                }
            }
            .navigationTitle(Text("\(target.slot) 番の設定"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完了") { dismiss() }
                }
            }
            // Choosing a sound or a vibration plays it, so that it can be told apart before use.
            .onChange(of: current.sound) { _, sound in
                model.cuePlayer.preview(sound)
            }
            .onChange(of: current.vibration) { _, vibration in
                model.cuePlayer.preview(vibration)
            }
        }
    }
}

extension SignalCueSound {
    var title: LocalizedStringKey {
        switch self {
        case .none: "なし"
        case .bell: "ポーン（高い音）"
        case .arpeggio: "ドミソ（上がる 3 音）"
        case .low: "ボン（低い音）"
        case .triple: "ポポポ（短く 3 回）"
        }
    }
}

extension SignalCueVibration {
    var title: LocalizedStringKey {
        switch self {
        case .none: "なし"
        case .long: "長く 1 回"
        case .double: "短く 2 回"
        case .triple: "短く 3 回"
        }
    }
}
