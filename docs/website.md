# ウェブサイト

Aoshingo の紹介ページ、サポート、プライバシーポリシーを GitHub Pages で公開しています。

- 公開先：<https://4sh0u0.github.io/Aoshingo/>
- ソース：[`site/`](../site/)

App Store Connect には次の URL を登録します。アプリ内の「プライバシーポリシー」のリンクも、公開版の URL を指すようにします。

| 項目 | URL |
| --- | --- |
| プライバシーポリシー URL | <https://4sh0u0.github.io/Aoshingo/privacy/> |
| サポート URL | <https://4sh0u0.github.io/Aoshingo/support/> |
| マーケティング URL | <https://4sh0u0.github.io/Aoshingo/> |

## 構成

| パス | 内容 |
| --- | --- |
| `site/public/` | 公開するファイル。ビルドは不要で、このまま GitHub Pages に置きます。 |
| `site/public/index.html` | トップページ |
| `site/public/support/` | 使い方、表示の見かた、よくある質問、お問い合わせ |
| `site/public/privacy/` | プライバシーポリシー（公開版） |
| `site/public/404.html` | 見つからないページ。どの URL でも表示されるため、リンクはすべて絶対 URL です。 |
| `site/public/assets/` | スタイルシート、アイコン、OGP 画像 |
| `site/scripts/` | プレビュー用サーバー、チェック、画像の生成 |
| `.github/workflows/pages.yml` | チェックと GitHub Pages への公開 |

## 手元で見る

Node.js 22 以降が必要です。

```bash
cd site
npm ci
npm run serve        # http://localhost:8000/Aoshingo/
```

GitHub Pages と同じく `/Aoshingo/` の下で配信します。ページ間のリンクは相対パスなので、独自ドメインに移しても書き換えは要りません（`404.html` と `canonical`・OGP の URL を除く）。

## チェック

```bash
cd site
npx playwright install chromium   # 初回だけ
npm run check
```

Pull Request で `site/` を変更すると、GitHub Actions でも同じチェックが走ります。

- **HTML**：[html-validate](https://html-validate.org/) の推奨ルール
- **アクセシビリティ**：[axe-core](https://github.com/dequelabs/axe-core) で WCAG 2.2 A/AA とベストプラクティスを確認します。ライト、ダーク、コントラストを上げる（ライト・ダーク）、強制カラーの 5 つの表示で調べます。
- **リフロー**：幅 320 px で横スクロールが出ないこと（WCAG 1.4.10）
- **リンク**：サイト内のリンクとページ内リンク（`#…`）の行き先があること
- **外部への通信**：ページを開いたときに、サイトの外へリクエストを送らないこと（外部のフォント、スクリプト、解析ツールを入れるとここで失敗します）

自動チェックで分かるのは一部です。大きな変更では、iPhone の VoiceOver と「さらに大きな文字」、macOS の VoiceOver、キーボード操作でも確かめてください。

## 公開

`main` に `site/` の変更が入ると、GitHub Actions がチェックしたうえで GitHub Pages に公開します。手動で公開し直すときは、Actions の「Website」ワークフローを `main` で実行します。

最初の 1 回だけ、リポジトリの **Settings → Pages → Build and deployment → Source** を **GitHub Actions** にしておく必要があります。

## 書くときの決まり

- 日本語を基本にします。ほかの言語は `site/public/en/` のように言語ごとのフォルダーに同じ構成で追加し、各ページの `<html lang>` と `hreflang` の相互リンクを設定します。
- スクリプト、Cookie、外部のフォント・画像・解析ツールは使いません。プライバシーポリシーの「このウェブサイト」の節がこれを前提にしています。
- 信号の状態は、アプリと同じく色だけで示さず、図形と文字を必ず添えます。配色はアプリ（`App/Views/Signal/SignalAppearance.swift`）と同じ値を使います。
- 見出しは順番どおりに使い（`h1` はページに 1 つ）、表には `caption` と `th` の `scope` を付けます。
- アプリの画面名やボタン名を書くときは、アプリの表示と同じ言葉にします。

## プライバシーポリシーを変えるとき

App Store に登録するのは `site/public/privacy/index.html` の公開版です。アプリの送信内容やサーバーの扱いを変えたら、同じ Pull Request でこのページも更新し、制定日・改定日を書き換えます。`docs/privacy.md` を残す場合は、公開版と同じ内容に保ちます。

## 画像を作り直す

アプリのアイコンを変えたら、アイコンと OGP 画像を作り直します。Pillow と、Inter Display・IPA P ゴシックのフォントが必要です。

```bash
python3 site/scripts/make-images.py \
  App/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png site/public/assets
```
