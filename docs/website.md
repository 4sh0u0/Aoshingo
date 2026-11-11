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
| `site/public/assets/` | スタイルシート、アイコン、OGP 画像、「メールアドレスを表示」ボタンのスクリプト（`contact.js`） |
| `site/contact-worker/` | 「メールアドレスを表示」ボタンの裏側の Cloudflare Worker（`aoshingo-contact`）。GitHub Pages には含めません。 |
| `site/scripts/` | プレビュー用サーバー、チェック、画像の生成 |
| `.github/workflows/pages.yml` | チェック、Worker のテスト、GitHub Pages への公開 |

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
- **リンク**：サイト内のリンクとページ内リンク（`#…`）の行き先があること。GitHub 上のこのリポジトリのファイルへのリンク（`https://github.com/4sh0u0/Aoshingo/blob/main/…`）は、そのファイルがリポジトリにあること。ほかの Pull Request で追加されるファイルは、マージまで `PENDING_REPOSITORY_FILES` に書いておきます（ファイルが入ったら、一覧から外すよう警告で知らせます。公開は止めません）
- **読み込み**：ページが読み込む画像やスタイルシートなどが存在すること（HTTP 400 以上や読み込み失敗を検出）
- **外部への通信**：サイトの外へのリクエストは、`site/scripts/check-pages.mjs` の `ALLOWED_EXTERNAL_HOSTS` に書いたホスト宛てだけであること。ホスト名は完全一致で比べます（`github.io` や `workers.dev` は誰でも使えるため、サブドメインまでは許可しません）。それ以外のフォント、スクリプト、解析ツールなどを入れるとここで失敗します。Turnstile（`challenges.cloudflare.com`）は、ボタンを押す前に読み込むと失敗します。チェック中は外部へのリクエストをすべて止めるので、ネットワークの状態に左右されません
- **メールアドレスの表示**：Turnstile と Worker をテスト用の代わりに差し替えて、サポートページとプライバシーポリシーのボタンをキーボードで押します。エラー（回数の上限、Turnstile を読み込めない）のお知らせ、成功したときにアドレスへフォーカスが移ること、表示後の状態の axe を確かめます

`site/contact-worker/` の Worker は別に `npm test` と `npm run typecheck` で確かめます（[`site/contact-worker/README.md`](../site/contact-worker/README.md)）。GitHub Actions でも同じテストが走ります。

自動チェックで分かるのは一部です。大きな変更では、iPhone の VoiceOver と「さらに大きな文字」、macOS の VoiceOver、キーボード操作でも確かめてください。

## 公開

`main` に `site/` の変更が入ると、GitHub Actions がチェックしたうえで GitHub Pages に公開します。手動で公開し直すときは、Actions の「Website」ワークフローを `main` で実行します。

`site/contact-worker/` の Worker は GitHub Actions ではデプロイしません。Cloudflare の Workers Builds が、`main` に変更が入るたびに `cf deploy` します。

最初の 1 回だけ、リポジトリの **Settings → Pages → Build and deployment → Source** を **GitHub Actions** にしておく必要があります。

## 書くときの決まり

- 日本語を基本にします。ほかの言語は `site/public/en/` のように言語ごとのフォルダーに同じ構成で追加し、各ページの `<html lang>` と `hreflang` の相互リンクを設定します。
- 外部のサービスは、開発の基盤として使っている GitHub と Cloudflare のものだけを使います（例：お問い合わせ用の Cloudflare Workers、Turnstile、Email Routing）。それ以外のフォント、画像、スクリプト、解析ツール、広告、SNS の埋め込みは読み込みません。
- GitHub や Cloudflare のサービスを新しくページで使うときは、同じ Pull Request で次の 2 つを行います。
  - プライバシーポリシーの「11. このウェブサイト」に、サービスの名前、使う目的、そのサービスに送られる情報を書く
  - ページが読み込むホスト名を、そのまま `site/scripts/check-pages.mjs` の `ALLOWED_EXTERNAL_HOSTS` に加える（完全一致）
- スクリプトは必要な部分（「メールアドレスを表示」ボタンなど）にだけ使い、文章と表はスクリプトなしでも読めるようにします。スクリプトはサイトの中に置き（`site/public/assets/`）、外部のスクリプトは操作されたときにだけ読み込みます。
- このサイト自体は Cookie とアクセス解析を使いません。使う場合は、先にプライバシーポリシーを改定します。Turnstile のように、外部のサービスが確認のために Cookie などを使う場合も、プライバシーポリシーに書きます。
- メールアドレスは HTML やリポジトリに書きません。お問い合わせ用のアドレスは「メールアドレスを表示」ボタンで表示します。
- 信号の状態は、アプリと同じく色だけで示さず、図形と文字を必ず添えます。配色はアプリ（`App/Views/Signal/SignalAppearance.swift`）と同じ値を使います。
- 見出しは順番どおりに使い（`h1` はページに 1 つ）、表には `caption` と `th` の `scope` を付けます。
- アプリの画面名やボタン名を書くときは、アプリの表示と同じ言葉にします。

## メールアドレスの表示（Turnstile）

サポートページとプライバシーポリシーの「メールアドレスを表示」ボタンを押すと、`site/public/assets/contact.js` が Cloudflare Turnstile を読み込み、確認が済んだら `aoshingo-contact` Worker からアドレスを受け取って表示します。アドレスは Worker の secret にだけ置くので、HTML を集めるクローラーには見えません。

- `contact.js` の `CONFIG`（Turnstile の Site Key と Worker の URL）が空のあいだ、ボタンは表示されず、GitHub の Issue の案内だけが出ます。
- スクリプトを使えない閲覧者には、`<noscript>` で GitHub の Issue を案内します。
- 表示に成功するとアドレスのリンクにフォーカスが移り、エラーは `role="status"` の欄で読み上げます。

初回の設定（専用アドレス、Turnstile のウィジェット、Worker の secret、Workers Builds）は [`site/contact-worker/README.md`](../site/contact-worker/README.md) にまとめています。

## プライバシーポリシーを変えるとき

App Store に登録するのは `site/public/privacy/index.html` の公開版です。アプリの送信内容やサーバーの扱いを変えたら、同じ Pull Request でこのページも更新し、制定日・改定日を書き換えます。`docs/privacy.md` を残す場合は、公開版と同じ内容に保ちます。

## 画像を作り直す

アプリのアイコンを変えたら、アイコンと OGP 画像を作り直します。元になる 1024 × 1024 の PNG は `Tools/AppIcon/export.sh` が書き出します（[Tools/AppIcon/README.md](../Tools/AppIcon/README.md)）。Pillow と、Inter Display・IPA P ゴシックのフォントが必要です。

```bash
python3 site/scripts/make-images.py \
  docs/assets/brand/aoshingo-icon-1024.png site/public/assets
```
