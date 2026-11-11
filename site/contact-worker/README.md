# aoshingo-contact（メールアドレス表示用 Worker）

ウェブサイトのサポートページとプライバシーポリシーにある「メールアドレスを表示」ボタンの裏側で動く、小さな Cloudflare Worker です。
迷惑メールを防ぐため、お問い合わせ用のメールアドレスはリポジトリにも HTML にも書かず、この Worker の秘密情報（secret）にだけ置きます。

## 流れ

1. 閲覧者がボタンを押すと、ページ（[`site/public/assets/contact.js`](../public/assets/contact.js)）が Cloudflare Turnstile を読み込み、ロボットによる操作でないかを確かめます。ボタンを押すまで Turnstile は読み込みません。
2. 確認が済むと、ページは Turnstile のトークンを `POST /v1/email`（`application/x-www-form-urlencoded` の `token`）で送ります。
3. Worker は Siteverify でトークンを検証し、`success`、`action`（`show-email`）、`hostname`（`ALLOWED_HOSTNAMES`）がすべて合うときだけ `{"email": "…"}` を返します。

| 応答 | 意味 |
| --- | --- |
| `200 {"email": "…"}` | 表示してよいアドレス |
| `400 invalid_request` | トークンがない、または長すぎる |
| `403 forbidden_origin` | `ALLOWED_ORIGINS` 以外のページからのリクエスト（CORS ヘッダーも付けません） |
| `403 verification_failed` | Turnstile の検証に失敗（期限切れ・使用済みのトークン、別の action や hostname） |
| `413` / `415` | 本文が大きすぎる / フォーム形式でない |
| `429 rate_limited` | 表示の回数が上限（1 分あたり 10 回、Cloudflare の拠点ごと）に達した |
| `500 server_misconfigured` | secret が設定されていない |
| `502 verification_unavailable` | Siteverify に接続できない |

## プライバシー

- IP アドレスや国を示すヘッダー（`CF-Connecting-IP`、`X-Forwarded-For`、`request.cf` など）を読みません。Siteverify にも `remoteip` を送りません（テストでソースを検査しています）。
- 何も保存せず、ログも残しません。`cloudflare.config.ts` で Workers Logs・呼び出しログ・トレースを無効にしており、コードに `console.*` はありません。
- レート制限は IP アドレスではなく固定のキーで数えます。検証に成功したリクエストだけを数えるので、でたらめなトークンを送り続けても上限は減りません。ただし、Turnstile を人手（いわゆる CAPTCHA 代行）で通し続けられると、同じ拠点のほかの閲覧者が「上限に達しました」になることがあります。影響はアドレスの表示だけで、GitHub の Issue は使えるため、IP を読まない設計を優先しています。

閲覧者に関わる Cloudflare の処理（Turnstile）は、プライバシーポリシーの「11. このウェブサイト」に書いています。

## 開発

Node.js 22 以降が必要です。デプロイには Cloudflare CLI（`cf`、開発用依存として固定）を使います。`cf build` と `cf deploy` は内部で Wrangler を使うため、`wrangler` も開発用依存に入れています。

```sh
cd site/contact-worker
npm ci
npm test                  # vitest（Siteverify とレート制限はテストの中で差し替え）
npm run typecheck         # 型チェック
npx cf deploy --dry-run   # デプロイされるバインディングの確認（アップロードはしない）
```

`package-lock.json` を作り直すときは npm 11 以降を使ってください（`npx npm@11 install`）。

## 初回の設定（リポジトリ所有者が 1 回だけ）

### 1. お問い合わせ用のメールアドレスを用意する

個人のアドレスをそのまま使わず、お問い合わせ専用のアドレス（例：`support@<あなたのドメイン>`）を作り、ふだんの受信箱に転送します。迷惑メールが増えたら、このアドレスだけを変えたり止めたりできます。

- Cloudflare で管理しているドメインなら **Email Routing**（無料）で、専用アドレスから受信箱へ転送できます。
- iCloud+ の「カスタムメールドメイン」で作ったアドレスでもかまいません。

### 2. Turnstile のウィジェットを作る

Cloudflare ダッシュボードの **Turnstile → Add widget** で作ります。

| 項目 | 値 |
| --- | --- |
| Widget name | `Aoshingo contact`（任意） |
| Hostname | `4sh0u0.github.io`（独自ドメインに移したら、そのホスト名も追加） |
| Widget Mode | Managed（推奨） |
| Pre-clearance | 使わない（No） |

作成後に表示される **Site Key**（公開してよい値）と **Secret Key**（秘密）を控えます。

### 3. 初回のデプロイ（秘密情報と一緒に）

`TURNSTILE_SECRET_KEY` と `CONTACT_EMAIL` は `cloudflare.config.ts` で `bindings.secret()` として宣言してあり、値は最初のデプロイで `cf deploy --secrets-file` を使って送ります。
2 回目以降のデプロイ（Workers Builds を含む）は、`--secrets-file` なしでも同じ値を引き継ぎます。
秘密情報のファイルは他人が読めない一時ディレクトリに作り、デプロイが終わったらすぐ消します。値をコマンドの履歴に残さないよう、`read -s` で入力します。

```sh
cd site/contact-worker
npm ci
npx cf auth login
d=$(mktemp -d) && chmod 700 "$d"
read -rs -p "Turnstile Secret Key: " TS_SECRET; echo
read -r -p "お問い合わせ用アドレス: " CONTACT
node -e 'process.stdout.write(JSON.stringify({TURNSTILE_SECRET_KEY: process.argv[1], CONTACT_EMAIL: process.argv[2]}))' \
  "$TS_SECRET" "$CONTACT" > "$d/secrets.json"
npx cf deploy --secrets-file "$d/secrets.json"
rm -rf "$d"; unset TS_SECRET CONTACT
```

アドレスを変えるときも、同じ手順で `--secrets-file` を付けてデプロイします。
秘密情報はリポジトリにも、Workers Builds の Build variables にも書かないでください。

### 4. Worker を GitHub リポジトリにつなぐ

**Workers & Pages** で `aoshingo-contact` を開き、**Settings → Build → Connect** で GitHub を選びます。
Cloudflare の GitHub App には `4sh0u0/Aoshingo` だけへのアクセスを許可し、次のように設定します。

| 項目 | 値 |
| --- | --- |
| Project name（Worker 名） | `aoshingo-contact`（`cloudflare.config.ts` の `name` と同じ） |
| Production branch | `main` |
| Build command | 空欄 |
| Deploy command | `npm run deploy` |
| Root directory（Advanced settings の Path） | `site/contact-worker` |
| API token | Create new token（新しく作成） |
| Build watch paths（Include） | `site/contact-worker/*` |

`main` 以外のブランチのビルド（Builds for non-production branches）はオフのままにします。

### 5. 動作確認

```sh
curl -i -X POST https://aoshingo-contact.<あなたのサブドメイン>.workers.dev/v1/email \
  -H 'Origin: https://4sh0u0.github.io' -d 'token=test'
# => 403 {"error":"verification_failed"}（secret が設定済みで、でたらめなトークンを拒否している）
# 500 server_misconfigured なら手順 3 の secret が届いていません
```

### 6. ページ側にサイトキーを書く

[`site/public/assets/contact.js`](../public/assets/contact.js) の `CONFIG` に、手順 2 の Site Key と Worker の URL を書いて、Pull Request でマージします。
どちらかが空のあいだ、ボタンは表示されません（ページには GitHub の Issue の案内だけが出ます）。

```js
const CONFIG = {
  sitekey: "0x4AAAAAAA…",
  endpoint: "https://aoshingo-contact.<あなたのサブドメイン>.workers.dev/v1/email",
};
```

## 独自ドメインに移すとき

- `cloudflare.config.ts` の `ALLOWED_ORIGINS` と `ALLOWED_HOSTNAMES` に新しいドメインを加える
- Turnstile のウィジェットの Hostname に新しいドメインを加える
- Worker の URL を変える場合（独自ドメインなど）は、`site/scripts/check-pages.mjs` の `ALLOWED_EXTERNAL_HOSTS` のホスト名も書き換える
