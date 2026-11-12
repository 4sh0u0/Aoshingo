// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// First launch: the safety notice, then the field-data choice.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(SettingsKey.onboardingCompleted) private var onboardingCompleted = false
    @AppStorage(SettingsKey.collectionConsentReview) private var reviewingConsent = false
    @State private var page = Page.safety

    enum Page {
        case safety
        case collection
    }

    var body: some View {
        NavigationStack {
            // Someone asked again after the collected data changed has already seen the safety notice.
            switch reviewingConsent ? .collection : page {
            case .safety:
                SafetyNoticeView { page = .collection }
            case .collection:
                CollectionConsentView(unavailability: model.field.unavailability, isReview: reviewingConsent) { consent in
                    // applyConsent clears the review flag; keep this page while the cover goes away.
                    page = .collection
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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

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
                if dynamicTypeSize.isAccessibilitySize {
                    confirmButton
                        .padding(.top, 8)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        // At accessibility text sizes the button would take up much of a small screen, so it comes
        // after the notices instead of staying at the bottom.
        .modifier(PinnedBottomBar(isPinned: !dynamicTypeSize.isAccessibilitySize) {
            confirmButton
                .padding()
        })
    }

    private var confirmButton: some View {
        Button(action: next) {
            Text("確認しました")
                .frame(maxWidth: .infinity)
        }
        // Large text, like the receive control, so white on the accent color meets WCAG 3:1 in dark mode.
        .font(.title3.weight(.semibold))
        .controlSize(.large)
        .prominentControlStyle()
    }
}

/// Keeps `bar` at the bottom of the screen while `isPinned`; otherwise leaves it out, and the view
/// shows it at the end of its scrolling content instead. The inset itself is left out, not given
/// conditional content: with an `if` inside the inset, the consent buttons were stacked and cut off
/// at the default text size, and the notice above them was truncated.
private struct PinnedBottomBar<Bar: View>: ViewModifier {
    let isPinned: Bool
    @ViewBuilder let bar: () -> Bar

    func body(content: Content) -> some View {
        if isPinned {
            content.safeAreaInset(edge: .bottom, content: bar)
        } else {
            content
        }
    }
}

/// The opt-in choice for field data. Both answers are equal in size and style, and neither is preselected.
/// When this build or device cannot send field data, "協力する" is unavailable and the reason is shown.
struct CollectionConsentView: View {
    let unavailability: FieldDataModel.Unavailability?
    /// The user had agreed to an older list of collected data.
    var isReview = false
    let decide: (CollectionConsent) -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("実測データの提供のお願い")
                    .font(.title.bold())
                    .accessibilityAddTraits(.isHeader)
                if isReview {
                    NoticeRow(systemImage: "exclamationmark.circle", text: "送信する内容が増えました。新しい内容を確かめて、協力するかどうかをもう一度選んでください。選ぶまでは何も送信しません。")
                }
                Text("信号の周期や、どの番号がどの横断歩道かを調べるため、受信したデータの提供にご協力いただけますか。集まったデータから求めた信号の周期は、協力している人の試験版（TestFlight）のアプリに「次の青の始まり」の推定として示します。")
                Text("協力しなくても、信号の受信と表示はすべてそのまま使えます。「推定」の画面は、試験版（TestFlight）で協力している人にだけ表示します。")
                CollectionDetails()
                Link("プライバシーポリシー", destination: AppLinks.privacyPolicy)
                Text("あとから設定画面でいつでも変更できます。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if dynamicTypeSize.isAccessibilitySize {
                    decision
                        .padding(.top, 8)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        // At accessibility text sizes the buttons, stacked, would cover most of a small screen and
        // leave little room to read what is collected, so they come after the text instead.
        .modifier(PinnedBottomBar(isPinned: !dynamicTypeSize.isAccessibilitySize) {
            decision
                .padding()
                .background(.bar)
        })
    }

    private var decision: some View {
        VStack(spacing: 12) {
            if let unavailability {
                FieldDataUnavailableNotice(reason: unavailability)
                    .font(.footnote)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ViewThatFits {
                HStack(spacing: 12) { buttons }
                VStack(spacing: 12) { buttons }
            }
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
        .disabled(unavailability != nil)
    }
}

/// What is and is not collected. Shared by the consent page and the settings screen.
struct CollectionDetails: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("送信するもの")
                .font(.headline)
            NoticeRow(systemImage: "dot.radiowaves.left.and.right", text: "信号機の交差点 ID と、受信した信号データそのもの")
            NoticeRow(systemImage: "clock", text: "信号や「残り目安」が変わった時刻と、それぞれが続いた時間（どちらも 0.1 秒単位）")
            NoticeRow(systemImage: "cellularbars", text: "電波の強さ（5 dB 単位）、受信の間隔、送信機の数と送信出力")
            NoticeRow(systemImage: "location.north.line", text: "交差点から見たあなたの方向と距離、端末の向き、歩く向きと速さ（どれもおおまかな区分）")
            NoticeRow(systemImage: "figure.walk", text: "歩いているか、走っているか、自転車や車に乗っているか、止まっているか（iPhone のモーション判定による区分。歩行者と車を見分けるため）")
            NoticeRow(systemImage: "person.2.wave.2", text: "周りにある Bluetooth 機器のおおよその数（混み具合の目安。機器の識別子は送りません）")
            NoticeRow(systemImage: "hand.tap", text: "「現地確認」欄で印を付けたときは、その印（信号の番号と端末の向き）")
            NoticeRow(systemImage: "clock.badge.checkmark", text: "送信した時刻（端末の時計が合っているかを確かめるためだけに使い、サーバーは保存しません）")
            NoticeRow(systemImage: "key", text: "不正防止のための鍵の ID（インストールごとに 1 つ）。鍵の登録と送信用トークンの取得のときだけ送り、実測データとは結び付けません")
            Text("送信しないもの")
                .font(.headline)
                .padding(.top, 4)
            NoticeRow(systemImage: "location.slash", text: "あなたの現在地（緯度・経度）、機種、OS のバージョン、言語、広告 ID")
            NoticeRow(systemImage: "network.slash", text: "サーバーは IP アドレスを記録しません")
            Text("おおまかな方向と距離を求めるために位置情報の許可を、歩いているか車などに乗っているかを見分けるために「モーションとフィットネス」の許可をお願いすることがあります。位置そのものは端末の外に出ませんが、方向と距離を合わせると、交差点のまわり数十 m のどのあたりにいたかは分かります。同じ送信用トークン（最長 6 時間有効）で送ったデータは、サーバーが受け取るときに同じ端末からのものと分かります。サーバーはトークンを実測データと一緒には保存しません。生データは 90 日後に削除し、交差点ごとの集計だけを残します。送信したデータには識別子がないため、あとから個別に削除することはできません。")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text("受け取ったデータからは、交差点の信号ごとの周期と青になる時刻をまとめた時刻表も作り、実測データの提供に協力している人の試験版（TestFlight）のアプリに「推定」として示します。時刻表に個々の利用者の情報は含まれません。協力をやめると、端末に保存した時刻表は削除します。")
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
