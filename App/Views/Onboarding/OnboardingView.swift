// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// First launch: the safety notice, then the field-data choice.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(SettingsKey.onboardingCompleted) private var onboardingCompleted = false
    @State private var page = Page.safety

    enum Page {
        case safety
        case collection
    }

    var body: some View {
        NavigationStack {
            switch page {
            case .safety:
                SafetyNoticeView { page = .collection }
            case .collection:
                CollectionConsentView { consent in
                    model.applyConsent(consent)
                    onboardingCompleted = true
                }
            }
        }
        .interactiveDismissDisabled()
    }
}

/// What the app is and is not. Shown before anything else.
struct SafetyNoticeView: View {
    let next: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Image(systemName: "figure.walk.circle.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Text("Aoshingo へようこそ")
                    .font(.largeTitle.bold())
                    .accessibilityAddTraits(.isHeader)
                Text("Aoshingo は、高度化PICS に対応した交差点の信号機が発信する Bluetooth 信号を受信して、歩行者用信号の状態を表示する非公式アプリです。")
                NoticeRow(systemImage: "eye", text: "表示は補助情報です。必ず実際の信号と周囲の安全を自分で確認してください。")
                NoticeRow(systemImage: "lock.iphone", text: "画面を閉じたり、ほかのアプリに切り替えたりすると受信できません。")
                NoticeRow(systemImage: "gauge.with.dots.needle.33percent", text: "「残り目安」は 8 段階の目安で、秒数ではありません。")
                NoticeRow(systemImage: "arrow.triangle.branch", text: "信号の番号がどの横断歩道かは、まだ確認できていません。")
                NoticeRow(systemImage: "antenna.radiowaves.left.and.right", text: "受信専用です。信号機に何かを送信したり、操作したりすることはありません。")
                NoticeRow(systemImage: "testtube.2", text: "これは開発中の試験版（pre-alpha）です。")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .safeAreaInset(edge: .bottom) {
            Button(action: next) {
                Text("確認しました")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .prominentControlStyle()
            .padding()
        }
    }
}

/// The opt-in choice for field data. Both answers are equal in size and style, and neither is preselected.
struct CollectionConsentView: View {
    let decide: (CollectionConsent) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("実測データの提供のお願い")
                    .font(.title.bold())
                    .accessibilityAddTraits(.isHeader)
                Text("信号の周期や、どの番号がどの横断歩道かを調べるため、受信したデータの提供にご協力いただけますか。協力しなくても、すべての機能をそのまま使えます。")
                CollectionDetails()
                Link("プライバシーポリシー", destination: AppLinks.privacyPolicy)
                Text("あとから設定画面でいつでも変更できます。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .safeAreaInset(edge: .bottom) {
            ViewThatFits {
                HStack(spacing: 12) { buttons }
                VStack(spacing: 12) { buttons }
            }
            .padding()
            .background(.bar)
        }
    }

    @ViewBuilder
    private var buttons: some View {
        Button {
            decide(.declined)
        } label: {
            Text("協力しない")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        Button {
            decide(.granted)
        } label: {
            Text("協力する")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
    }
}

/// What is and is not collected. Shared by the consent page and the settings screen.
struct CollectionDetails: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("送信するもの")
                .font(.headline)
            NoticeRow(systemImage: "dot.radiowaves.left.and.right", text: "信号機の交差点 ID と、受信した信号データそのもの")
            NoticeRow(systemImage: "clock", text: "信号が変わった時刻（秒単位）")
            NoticeRow(systemImage: "cellularbars", text: "電波の強さ（5 dB 単位）")
            NoticeRow(systemImage: "location.north.line", text: "交差点から見たあなたの方向と、端末の向き（どちらも 8 方位のおおまかな区分）")
            Text("送信しないもの")
                .font(.headline)
                .padding(.top, 4)
            NoticeRow(systemImage: "location.slash", text: "緯度・経度、機種、OS のバージョン、言語、広告 ID、端末を識別する ID")
            NoticeRow(systemImage: "network.slash", text: "サーバーは IP アドレスを記録しません")
            Text("おおまかな方向を求めるために位置情報の許可をお願いすることがあります。位置そのものは端末の外に出ません。生データは 90 日後に削除し、交差点ごとの集計だけを残します。送信したデータには識別子がないため、あとから個別に削除することはできません。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

struct NoticeRow: View {
    let systemImage: String
    let text: LocalizedStringKey
    /// Fixed icon column, so the text lines up whatever the symbol's width; scales with Dynamic Type.
    @ScaledMetric(relativeTo: .body) private var iconWidth: CGFloat = 28

    var body: some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(.tint)
                .frame(width: iconWidth)
                .accessibilityHidden(true)
        }
    }
}
