# aoshingo-reports（フィールドデータ受信 Worker）

Aoshingo iOS アプリから、ユーザーが明示的に同意（オプトイン）した場合だけ送られてくる
匿名化済みのフィールドデータを受け取る Cloudflare Worker です。
API の仕様（エンドポイント、検証ルール、エラーコード、プライバシー規則）は
[`docs/field-data-api.md`](../docs/field-data-api.md) が正であり、この Worker はそれを実装しています。

## 何をするか

| エンドポイント | 内容 |
| --- | --- |
| `GET /v1/health` | 死活確認。`{"ok": true}` を返します。 |
| `POST /v1/challenge` | 有効期限 300 秒のチャレンジ（16 バイト乱数と期限に `TOKEN_SECRET` で HMAC 署名したもの）を発行します。保存しないので D1 には書き込みません。 |
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
  集計テーブルに畳み込んでから削除し、1 週間より前の書き込み量の記録も削除します。
- D1 に書き込む `/v1/attest`・`/v1/token`・`/v1/reports` は、書き込む前に 1 日の書き込み上限を確かめます
  （下の「1 日の書き込み上限」）。

### データベース（D1）

| テーブル | 内容 |
| --- | --- |
| `challenges` | 使っていません（以前はチャレンジを保存していた）。旧版がデプロイ中も動けるように残しており、後のマイグレーションで削除します。 |
| `daily_usage` | 日（UTC）ごとの書き込み行数とレポート本文のバイト数だけ。1 週間で cron が削除します。 |
| `attest_keys` | App Attest の鍵 ID・公開鍵・署名カウンタ・環境・登録日。レポートとは一切結び付けません。 |
| `reports` | 1 レポート × 1 交差点 = 1 行。受信日（UTC、日単位）、schema、client、件数、payload（serviceUUIDs / emitters / observations / transitions の JSON）。主キーはランダムで、到着順を残しません。 |
| `transition_counts` | 保持期間後も残る集計：交差点 × スロット × 遷移元 × 遷移先 × 時刻（JST の時）ごとの件数。 |
| `observation_counts` | 保持期間後も残る集計：交差点 × メッセージ種別（raw から取得）× RSSI × 方位 × 端末の向きごとの件数。不明値は RSSI = 1、方位・向き = -1 で表します。 |

スキーマは [`migrations/`](migrations/) にあります。

## プライバシー保証

- **IP アドレスなどを読みません。** `CF-Connecting-IP`、`X-Forwarded-For`、`CF-IPCountry`、`request.cf` などは
  コード中で一度も参照していません（読むヘッダーは `Content-Type`、`Content-Length`、`Authorization` だけで、
  テストでソースを静的に検査しています）。レート制限も IP ではなく、トークンのランダム ID、鍵 ID のハッシュ、固定のキーのどれかで行います。
- **ログを残しません。** デプロイ設定（`cloudflare.config.ts`）で Workers Logs・呼び出しログ・トレースを無効にしており、
  コードには `console.*` が一切ありません。リクエスト本文やトークンを記録する経路はありません。
- **端末を特定できる情報を保存しません。** トークンには App Attest の `keyId` を含めず、レポート行にはトークンも
  トークン ID も `keyId` も保存しません（テストで確認しています）。`keyId` は `attest_keys` テーブルにだけ存在し、
  レポートとは紐付きません。受信日時は日単位までしか保存しません。
- **想定外のデータを受け取りません。** レポートは仕様の検証表どおりに厳密に検証し、未知のフィールド（緯度経度など）が
  含まれていれば全体を `400 invalid_report` で拒否します。保存するのは検証済みの値から組み立て直した JSON だけです。
- **保持期間を守ります。** 生データは `RETENTION_DAYS` 日で集計に畳み込まれて削除されます。

## 開発

Node.js 22.18 以降が必要です。デプロイには Cloudflare CLI（`cf`、開発用依存として固定）を使います。

```sh
cd server
npm ci                 # package-lock.json どおりにインストール
npm test               # vitest（workerd + ローカル D1 上で実行）
npx tsc --noEmit       # 型チェック
npx cf build           # バンドルの確認（アップロードはしない）
npx cf deploy --dry-run   # デプロイされるバインディングの確認（アップロードはしない）
```

設定ファイルは 2 つあります。デプロイに使うのは `cloudflare.config.ts`（`cf` が読む）で、
`wrangler.jsonc` はテスト専用です（`@cloudflare/vitest-plugin` が読むため残しています）。
バインディング・変数・cron を変えるときは、両方を同じ内容にしてください。

`vite` は vitest の依存として入るので、`package.json` に直接書かないでください。
書くと `cf` がこのプロジェクトを Vite のアプリと判定し、Wrangler ではなく `vite build` を実行して `cf build` が失敗します。

依存関係はすべて開発用で、バージョンは固定しています。Worker 本体は外部ライブラリを使わず、
CBOR・DER（X.509）の最小限のパーサーと WebCrypto だけで動きます。
`package-lock.json` を作り直す場合は npm 11 以降を使ってください（npm 10 は依存解決中にエラーになることがあります。
既存の lock ファイルからの `npm ci` は npm 10 でも動きます）。

## デプロイ（Cloudflare の Git 連携で自動）

Cloudflare の **Workers Builds**（GitHub 連携）で、`main` ブランチに `server/` の変更が入るたびに自動でデプロイします。
GitHub Actions からはデプロイしません（CI はテストだけ）。つまり **PR を `main` にマージすることが本番へのデプロイ**です。

デプロイ時には `npm run deploy` が実行され、`cf d1 migrations apply` で未適用の D1 マイグレーションを適用してから `cf deploy` します。

### 初回の設定（リポジトリ所有者が 1 回だけ）

1. **D1 データベースを作る**

   `server/` で Cloudflare CLI にログインし（`npx cf auth login`）、データベースを作ります。

   ```sh
   npx cf d1 create --name aoshingo-reports --primary-location-hint apac
   ```

   表示された `uuid` が Database ID です（ダッシュボードの **Storage & databases → D1** で作っても同じです）。

2. **ID をリポジトリに書いて `main` に入れる**

   次の値を書き換え、PR でマージします。どちらも秘密情報ではありません。

   - D1 の Database ID：`cloudflare.config.ts` の `DB` の `id`、`package.json` の `deploy` スクリプト、
     テスト用の `wrangler.jsonc` の `d1_databases[0].database_id`
   - Apple Developer の Membership ページにある 10 文字のチーム ID：`cloudflare.config.ts` と
     `wrangler.jsonc` の `APPLE_TEAM_ID`

   書き換える前にデプロイが走っても、マイグレーションの段階で失敗するだけで、何も公開されません。

3. **初回のデプロイ（トークン用の秘密鍵と一緒に）**

   `TOKEN_SECRET`（アップロード用トークンの HMAC 鍵、32 文字以上）は `cloudflare.config.ts` で
   `bindings.secret()` として宣言してあり、値は最初のデプロイで `cf deploy --secrets-file` を使って一緒に送ります。
   2 回目以降のデプロイ（Workers Builds を含む）は `--secrets-file` なしでも同じ値を引き継ぎます。
   秘密鍵のファイルは他人が読めない一時ディレクトリに作り、デプロイが終わったらすぐ消します。

   ```sh
   cd server
   npm ci
   npx cf d1 migrations apply <Database ID> --dir migrations
   d=$(mktemp -d) && chmod 700 "$d"
   printf '{"TOKEN_SECRET":"%s"}\n' "$(openssl rand -base64 48 | tr -d '\n')" > "$d/secrets.json"
   npx cf deploy --secrets-file "$d/secrets.json"
   rm -rf "$d"
   ```

   秘密鍵はリポジトリにも、Build variables にも書かないでください。
   値を変えると発行済みトークンはすべて無効になり、アプリは `/v1/token` で取り直します。
   `TOKEN_SECRET` とチーム ID がそろうまで、`/v1/attest` と `/v1/token` は `500 server_misconfigured` を返します。

4. **Worker を GitHub リポジトリにつなぐ**

   手順 3 で Worker `aoshingo-reports` ができているので、**Workers & Pages** でその Worker を開き、
   **Settings → Build → Connect** で GitHub を選びます。Cloudflare の GitHub App には
   `4sh0u0/Aoshingo` だけへのアクセスを許可し、次のように設定します（まだ Worker がない場合は
   **Create application → Import a repository** から同じ値で設定します）。

   | 項目 | 値 |
   | --- | --- |
   | Project name（Worker 名） | `aoshingo-reports`（`cloudflare.config.ts` の `name` と同じにする。違うとビルドが失敗します） |
   | Production branch | `main` |
   | Build command | 空欄 |
   | Deploy command | `npm run deploy` |
   | Root directory（Advanced settings の Path） | `server` |
   | API token | Create new token（新しく作成） |

   依存関係は `package-lock.json` から自動でインストールされます。Node.js のバージョンは `server/.node-version`（22）で指定しています。
   接続後の最初のビルドのログで、`cf d1 migrations apply` と `cf deploy` が成功したことを確認してください。

5. **ビルド用トークンに D1 の権限を足す**

   自動で作られるトークンには D1 の権限がないため、そのままではマイグレーションの適用で失敗します。
   **My Profile → API Tokens** で Workers Builds が作ったトークンを開き、**Account → D1 → Edit** を追加して保存します。
   そのあと Worker の **Deployments**（ビルド履歴）で失敗したビルドを **Retry** します。

6. **ビルドの対象を `server/` に絞る**

   Worker の **Settings → Build → Build watch paths** で、Include paths を `server/*` にします。
   iOS アプリやドキュメントだけの変更では、ビルドが走らなくなります。
   同じ画面で、`main` 以外のブランチのビルド（Builds for non-production / Preview branches）はオフのままにします
   （この Worker は `preview_urls` を無効にしています）。

7. **動作確認**

   ```sh
   curl https://aoshingo-reports.<あなたのサブドメイン>.workers.dev/v1/health
   # => {"ok":true}
   curl -X POST https://aoshingo-reports.<あなたのサブドメイン>.workers.dev/v1/challenge
   # => 201 と {"challenge":"…"}（TOKEN_SECRET が設定されていることを確認。D1 には書き込みません）
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
その端末で試すときだけ `cloudflare.config.ts`（とテスト用の `wrangler.jsonc`）の `ALLOW_DEVELOPMENT_ATTESTATION` を `"true"` にしてマージし、
リリース前に `"false"` に戻してください。`"false"` に戻すと development 環境の鍵とトークンはすべて使えなくなります。

### 手元から手動でデプロイする場合

Git 連携が使えないときは、`server/` で次を実行します（`npm run deploy` は自動デプロイと同じ処理です）。

```sh
npm ci
npx cf auth login
npm run deploy
```

初回だけは、秘密鍵を送るために手順 3 のとおり `--secrets-file` を付けてデプロイします。

スキーマを変えるときは `migrations/` に新しい番号のファイルを追加します。適用済みのファイルは書き換えないでください。

### データの確認

`<Database ID>` は `cloudflare.config.ts` の `DB` の `id` です。

```sh
npx cf d1 query <Database ID> \
  --sql "SELECT intersection_id, received_day, observation_count, transition_count FROM reports LIMIT 20"
npx cf d1 query <Database ID> \
  --sql "SELECT * FROM transition_counts ORDER BY count DESC LIMIT 20"
```

## 料金プランと制限

Workers Free プランの主な制限（2026 年時点の公表値。最新の値は Cloudflare のドキュメントで確認してください）:

- リクエスト数: **1 日 100,000 件**
- CPU 時間: **1 リクエストあたり 10 ms**
- D1: **書き込み 1 日 100,000 行**（読み取り 1 日 500 万行、データベース 1 つあたり 500 MB、アカウント全体で 5 GB）

目安:

- 最も重い処理は `/v1/attest` の証明書チェーン検証（ECDSA P-384 と P-256 の署名検証）です。
  手元の計測（Node.js、同じコード）では 1 回あたり約 2 ms の CPU 時間で、10 ms には収まる見込みですが、
  Cloudflare 上の実測ではありません。起動直後のアイソレートなどで 10 ms を超えて
  `/v1/attest` が失敗する（Exceeded CPU time limit）ようなら、**Workers Paid プラン（月額 5 ドル〜）** が必要です。
  `/v1/token`（P-256 の検証 1 回）とレポートの検証はこれより軽い処理です。
- リクエスト数の上限（1 日 100,000 件）は、どのエンドポイントへのリクエストでも数えられます。
  これはこの Worker のコードでは防げません。

### 1 日の書き込み上限

D1 の無料枠（書き込み 1 日 100,000 行、データベース 500 MB）はアカウント全体で共有です。
1 台の端末や 1 つのスクリプトがこれを使い切ると、同じアカウントのほかの D1 も止まるため、
Worker は自分の書き込みに上限を設けています（`src/budget.ts`、`src/storage.ts`）。

| 対象 | 上限 | 既定値 |
| --- | --- | --- |
| API による書き込み行数（UTC の 1 日） | `DAILY_WRITE_LIMIT` | 30,000 行 |
| レポート本文のバイト数（UTC の 1 日） | `DAILY_PAYLOAD_LIMIT_BYTES` | 3,000,000 バイト |
| データベースの大きさ | `MAX_DATABASE_BYTES` | 450,000,000 バイト |
| cron の 1 回の書き込み行数 | `DEFAULT_FOLD_LIMITS`（コード内） | 45,000 行で新しいチャンクを始めない（最大で約 51,000 行） |
| cron の 1 回の D1 クエリ数 | 同上 | 最大 41 回（無料枠は 1 回の呼び出しで 50 回） |

- 行数はインデックスへの書き込みも含めて数えます。レポートは「交差点数 × 2 + 1」行、
  `/v1/attest` と `/v1/token` は 2 行です。
- 上限に達すると、その日は `503 over_capacity` を返して何も保存しません。アプリは時間をおいて送り直し、
  端末内のレポートは 6 日まで残ります。
- データベースの大きさは D1 がクエリごとに返す値（`size_after`）で確かめます。
- 1 日の合計は最大でも 30,000 + 約 51,000 行で、100,000 行を下回ります。
- 3 MB × 90 日 = 270 MB で、保持期間の生データは 500 MB に収まります。
- 1 台の端末が正規のトークンで上限まで送ると、その日はほかの利用者のレポートも受け付けなくなります。
  端末を区別しない設計のため、これは防げません。D1 全体が止まるのを防ぐことを優先しています。
- cron は 1 回に最大 20 チャンク（1 チャンクは 1,000 行まで、かつ observation と transition が合わせて
  4,000 件まで）を畳み込みます。終わらなかった分は翌日に回します。
- Workers Paid プランでは、上の値を `cloudflare.config.ts` と `wrangler.jsonc` で上げられます。

### レート制限

Workers Rate Limiting を使っています（期間は 10 秒か 60 秒のみ指定可能、カウンタは Cloudflare の拠点ごと）。

| バインディング | キー | 既定値 |
| --- | --- | --- |
| `REPORTS_RATE_LIMITER` | トークンのランダム ID | 60 秒あたり 6 回 |
| `AUTH_RATE_LIMITER` | `/v1/attest` は固定キー `attest`、`/v1/token` は鍵 ID の SHA-256 の先頭 16 バイト | 60 秒あたり各 30 回 |

`AUTH_RATE_LIMITER` は、attestation や assertion の検証に通ったリクエストだけを数えます。
そのため、不正なリクエストを大量に送っても、正規の利用者が `429 rate_limited` になることはありません。
`/v1/challenge` は何も書き込まないので、レート制限をかけていません（IP を使わない以上、キーが共通になり、
1 つのクライアントがほかの全員を締め出せてしまうため）。
値は `cloudflare.config.ts` の `bindings.rateLimit()`（とテスト用の `wrangler.jsonc` の `ratelimits`）で変更できます。namespace は Cloudflare アカウント内で一意である必要があります。

## ファイル構成

```
server/
├── cloudflare.config.ts    デプロイ設定（D1、レート制限、変数、秘密鍵の宣言、cron、ログ無効化）
├── wrangler.jsonc          テスト用の設定（vitest が読む。デプロイ設定と同じ内容に保つ）
├── migrations/             D1 スキーマ
├── src/
│   ├── index.ts            エントリポイント
│   ├── app.ts              ルーティングと各エンドポイント
│   ├── appattest.ts        attestation / assertion の検証
│   ├── apple-root.ts       ピン留めした Apple App Attestation Root CA
│   ├── x509.ts, der.ts     証明書チェーン検証用の最小限の X.509 / DER パーサー
│   ├── cbor.ts             最小限の CBOR デコーダー
│   ├── token.ts            HMAC 署名付きのステートレストークン
│   ├── challenge.ts        HMAC 署名付きのステートレスなチャレンジ
│   ├── budget.ts           1 日の書き込み上限
│   ├── report.ts           レポートの検証
│   ├── storage.ts          レポートの保存と cron による集計・削除
│   ├── env.ts, http.ts, encoding.ts
└── test/                   vitest のテスト（偽のルート CA → 中間 CA → 端末証明書を生成して検証）
```
