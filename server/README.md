# aoshingo-reports（フィールドデータ受信 Worker）

Aoshingo iOS アプリから、ユーザーが明示的に同意（オプトイン）した場合だけ送られてくる
匿名化済みのフィールドデータを受け取る Cloudflare Worker です。
API の仕様（エンドポイント、検証ルール、エラーコード、プライバシー規則）は
[`docs/field-data-api.md`](../docs/field-data-api.md) が正であり、この Worker はそれを実装しています。

## 何をするか

| エンドポイント | 内容 |
| --- | --- |
| `GET /v1/health` | 死活確認。`{"ok": true}` を返します。 |
| `POST /v1/challenge` | 使い捨てのチャレンジ（32 バイト乱数、有効期限 300 秒）を発行し、D1 に保存します。 |
| `POST /v1/attest` | App Attest の attestation を Apple の手順どおりに検証し、公開鍵を登録してアップロード用トークンを返します。 |
| `POST /v1/token` | 登録済みの鍵による assertion を検証し（署名・rpIdHash・カウンタの単調増加）、トークンを再発行します。 |
| `POST /v1/reports` | `Authorization: Bearer <token>` 付きのレポート（最大 256 KiB）を検証し、交差点ごとに 1 行として D1 に保存します。 |

- App Attest の証明書チェーンは、ソースに埋め込んだ **Apple App Attestation Root CA**
  （SHA-256 フィンガープリント `1C:B9:82:3B:A2:8B:A6:AD:2D:33:A0:06:94:1D:E2:AE:4F:51:3E:F1:D4:E8:31:B9:F7:E0:FA:7B:62:42:C9:32`）
  に固定（ピン留め）して検証します。本番コードで別のルートを信頼させる設定（環境変数など）はありません。
  テストだけが `createApp({ attestationRootForTesting })` という関数引数で偽のルートを渡します。
- トークンはステートレスです。中身は「ランダムな 16 バイトの ID」「有効期限」「App Attest の環境
  （production / development）」だけで、`TOKEN_SECRET` による HMAC-SHA256 で改ざんを防ぎ、定数時間で比較します。
- 毎日 03:00 JST（`0 18 * * *` UTC）の cron で、`RETENTION_DAYS`（既定 90 日）を過ぎたレポート行を
  集計テーブルに畳み込んでから削除し、期限切れのチャレンジも削除します。

### データベース（D1）

| テーブル | 内容 |
| --- | --- |
| `challenges` | 未使用のチャレンジ。使われた時点で削除、期限切れは cron で削除。 |
| `attest_keys` | App Attest の鍵 ID・公開鍵・署名カウンタ・環境・登録日。レポートとは一切結び付けません。 |
| `reports` | 1 レポート × 1 交差点 = 1 行。受信日（UTC、日単位）、schema、client、件数、payload（serviceUUIDs / emitters / observations / transitions の JSON）。主キーはランダムで、到着順を残しません。 |
| `transition_counts` | 保持期間後も残る集計：交差点 × スロット × 遷移元 × 遷移先 × 時刻（JST の時）ごとの件数。 |
| `observation_counts` | 保持期間後も残る集計：交差点 × メッセージ種別（raw から取得）× RSSI × 方位 × 端末の向きごとの件数。不明値は RSSI = 1、方位・向き = -1 で表します。 |

スキーマは [`migrations/0001_initial.sql`](migrations/0001_initial.sql) にあります。

## プライバシー保証

- **IP アドレスなどを読みません。** `CF-Connecting-IP`、`X-Forwarded-For`、`CF-IPCountry`、`request.cf` などは
  コード中で一度も参照していません（読むヘッダーは `Content-Type`、`Content-Length`、`Authorization` だけで、
  テストでソースを静的に検査しています）。レート制限も IP ではなく、トークンのランダム ID か固定のキーで行います。
- **ログを残しません。** `wrangler.jsonc` で Workers Logs・呼び出しログ・トレースを無効にしており、
  コードには `console.*` が一切ありません。リクエスト本文やトークンを記録する経路はありません。
- **端末を特定できる情報を保存しません。** トークンには App Attest の `keyId` を含めず、レポート行にはトークンも
  トークン ID も `keyId` も保存しません（テストで確認しています）。`keyId` は `attest_keys` テーブルにだけ存在し、
  レポートとは紐付きません。受信日時は日単位までしか保存しません。
- **想定外のデータを受け取りません。** レポートは仕様の検証表どおりに厳密に検証し、未知のフィールド（緯度経度など）が
  含まれていれば全体を `400 invalid_report` で拒否します。保存するのは検証済みの値から組み立て直した JSON だけです。
- **保持期間を守ります。** 生データは `RETENTION_DAYS` 日で集計に畳み込まれて削除されます。

## 開発

Node.js 22 以降が必要です。

```sh
cd server
npm ci                 # package-lock.json どおりにインストール
npm test               # vitest（workerd + ローカル D1 上で実行）
npx tsc --noEmit       # 型チェック
npx wrangler deploy --dry-run --outdir dist   # バンドルの確認（アップロードはしない）
```

依存関係はすべて開発用で、バージョンは固定しています。Worker 本体は外部ライブラリを使わず、
CBOR・DER（X.509）の最小限のパーサーと WebCrypto だけで動きます。
`package-lock.json` を作り直す場合は npm 11 以降を使ってください（npm 10 は依存解決中にエラーになることがあります。
既存の lock ファイルからの `npm ci` は npm 10 でも動きます）。

## デプロイ（Cloudflare の Git 連携で自動）

Cloudflare の **Workers Builds**（GitHub 連携）で、`main` ブランチに `server/` の変更が入るたびに自動でデプロイします。
GitHub Actions からはデプロイしません（CI はテストだけ）。つまり **PR を `main` にマージすることが本番へのデプロイ**です。

デプロイ時には `npm run deploy` が実行され、未適用の D1 マイグレーションを適用してから `wrangler deploy` します。

### 初回の設定（リポジトリ所有者が 1 回だけ）

1. **D1 データベースを作る**

   Cloudflare ダッシュボードの **Storage & databases → D1** で、`aoshingo-reports` という名前のデータベースを作り、
   表示された **Database ID** を控えます（`npx wrangler d1 create aoshingo-reports` でも同じです）。

2. **ID をリポジトリに書いて `main` に入れる**

   `wrangler.jsonc` の次の 2 か所を書き換え、PR でマージします。どちらも秘密情報ではありません。

   - `d1_databases[0].database_id`：手順 1 の Database ID（`00000000-…` の箇所）
   - `vars.APPLE_TEAM_ID`：Apple Developer の Membership ページにある 10 文字のチーム ID（`REPLACE_WITH_TEAM_ID` の箇所）

   書き換える前にデプロイが走っても、マイグレーションの段階で失敗するだけで、何も公開されません。

3. **Worker を GitHub リポジトリにつなぐ**

   **Workers & Pages → Create application → Import a repository** で GitHub を選び、
   Cloudflare の GitHub App に `4sh0u0/Aoshingo` だけへのアクセスを許可してから、次のように設定します。

   | 項目 | 値 |
   | --- | --- |
   | Project name（Worker 名） | `aoshingo-reports`（`wrangler.jsonc` の `name` と同じにする。違うとビルドが失敗します） |
   | Production branch | `main` |
   | Build command | 空欄 |
   | Deploy command | `npm run deploy` |
   | Root directory（Advanced settings の Path） | `server` |
   | API token | Create new token（新しく作成） |

   すでに `wrangler deploy` で Worker `aoshingo-reports` を作ってある場合は、Import ではなく、その Worker の **Settings → Build → Connect** から同じ値で接続します。

   依存関係は `package-lock.json` から自動でインストールされます。Node.js のバージョンは `server/.node-version`（22）で指定しています。

4. **ビルド用トークンに D1 の権限を足す**

   自動で作られるトークンには D1 の権限がないため、そのままではマイグレーションの適用で失敗します。
   **My Profile → API Tokens** で Workers Builds が作ったトークンを開き、**Account → D1 → Edit** を追加して保存します。
   そのあと Worker の **Deployments**（ビルド履歴）で失敗したビルドを **Retry** します。

5. **ビルドの対象を `server/` に絞る**

   Worker の **Settings → Build → Build watch paths** で、Include paths を `server/*` にします。
   iOS アプリやドキュメントだけの変更では、ビルドが走らなくなります。
   同じ画面で、`main` 以外のブランチのビルド（Builds for non-production / Preview branches）はオフのままにします
   （この Worker は `preview_urls` を無効にしています）。

6. **トークン用の秘密鍵を設定**

   Worker の **Settings → Variables and Secrets → Add** で、種類 **Secret**、名前 `TOKEN_SECRET`、
   値に 32 文字以上のランダムな文字列（例：`openssl rand -base64 48` の出力）を入れて保存します。
   秘密鍵はリポジトリにも、Build variables にも書かないでください。デプロイし直しても消えません。
   この値を変更すると発行済みトークンはすべて無効になり、アプリは `/v1/token` で取り直します。

   `TOKEN_SECRET` とチーム ID がそろうまで、`/v1/attest` と `/v1/token` は `500 server_misconfigured` を返します。

7. **動作確認**

   ```sh
   curl https://aoshingo-reports.<あなたのサブドメイン>.workers.dev/v1/health
   # => {"ok":true}
   ```

8. **iOS アプリの送信先を設定**

   アプリは送信先のホスト名をビルド設定 `AOSHINGO_REPORT_HOST` から読みます。
   `Config/Local.xcconfig`（Git 管理外。ルートの README を参照）にホスト名だけ（`https://` やパスは付けない）を書きます。
   ホスト名は秘密情報ではないため、配布用ビルドで固定したい場合は `Config/Base.xcconfig` に書いてもかまいません。

   ```
   AOSHINGO_REPORT_HOST = aoshingo-reports.<あなたのサブドメイン>.workers.dev
   ```

   （xcconfig では `//` 以降がコメント扱いになるため、URL ではなくホスト名で指定します。）

### App Attest の development 環境

Xcode から直接実行するデバッグビルドは App Attest の development 環境を使います。
その端末で試すときだけ `wrangler.jsonc` の `ALLOW_DEVELOPMENT_ATTESTATION` を `"true"` にしてマージし、
リリース前に `"false"` に戻してください。`"false"` に戻すと development 環境の鍵とトークンはすべて使えなくなります。

### 手元から手動でデプロイする場合

Git 連携が使えないときは、`server/` で次を実行します（`npm run deploy` は自動デプロイと同じ処理です）。

```sh
npm ci
npx wrangler login
npm run deploy
npx wrangler secret put TOKEN_SECRET   # 初回だけ
```

スキーマを変えるときは `migrations/` に新しい番号のファイルを追加します。適用済みのファイルは書き換えないでください。

### データの確認

```sh
npx wrangler d1 execute aoshingo-reports --remote \
  --command "SELECT intersection_id, received_day, observation_count, transition_count FROM reports LIMIT 20"
npx wrangler d1 execute aoshingo-reports --remote \
  --command "SELECT * FROM transition_counts ORDER BY count DESC LIMIT 20"
```

## 料金プランと制限

Workers Free プランの主な制限（2026 年時点の公表値。最新の値は Cloudflare のドキュメントで確認してください）:

- リクエスト数: **1 日 100,000 件**
- CPU 時間: **1 リクエストあたり 10 ms**
- D1: **書き込み 1 日 100,000 行**（読み取り 1 日 500 万行、保存 5 GB）

目安:

- レポート 1 件は「交差点数」ぶんの行を書き込みます（最大 50 行）。cron による集計の更新と削除も書き込みに数えられます。
- 最も重い処理は `/v1/attest` の証明書チェーン検証（ECDSA P-384 と P-256 の署名検証）です。
  手元の計測（Node.js、同じコード）では 1 回あたり約 2 ms の CPU 時間で、10 ms には収まる見込みですが、
  Cloudflare 上の実測ではありません。起動直後のアイソレートなどで 10 ms を超えて
  `/v1/attest` が失敗する（Exceeded CPU time limit）ようなら、**Workers Paid プラン（月額 5 ドル〜）** が必要です。
  `/v1/token`（P-256 の検証 1 回）とレポートの検証はこれより軽い処理です。

### レート制限

Workers Rate Limiting を使っています（期間は 10 秒か 60 秒のみ指定可能、カウンタは Cloudflare の拠点ごと）。

| バインディング | キー | 既定値 |
| --- | --- | --- |
| `REPORTS_RATE_LIMITER` | トークンのランダム ID | 60 秒あたり 6 回 |
| `AUTH_RATE_LIMITER` | 固定キー `challenge` / `attest` / `token`（エンドポイントごと） | 60 秒あたり各 30 回 |

IP アドレスを使わないため、`/v1/challenge` などに大量のリクエストが来ると正規の利用者も一時的に
`429 rate_limited` になります。これは無料枠（特に D1 の書き込み数）を守るための意図的なトレードオフです。
値は `wrangler.jsonc` の `ratelimits` で変更できます。`namespace_id` は Cloudflare アカウント内で一意である必要があります。

## ファイル構成

```
server/
├── wrangler.jsonc          Worker の設定（D1、レート制限、変数、cron、ログ無効化）
├── migrations/             D1 スキーマ
├── src/
│   ├── index.ts            エントリポイント
│   ├── app.ts              ルーティングと各エンドポイント
│   ├── appattest.ts        attestation / assertion の検証
│   ├── apple-root.ts       ピン留めした Apple App Attestation Root CA
│   ├── x509.ts, der.ts     証明書チェーン検証用の最小限の X.509 / DER パーサー
│   ├── cbor.ts             最小限の CBOR デコーダー
│   ├── token.ts            HMAC 署名付きのステートレストークン
│   ├── challenge.ts        使い捨てチャレンジ
│   ├── report.ts           レポートの検証
│   ├── storage.ts          レポートの保存と cron による集計・削除
│   ├── env.ts, http.ts, encoding.ts
└── test/                   vitest のテスト（偽のルート CA → 中間 CA → 端末証明書を生成して検証）
```
