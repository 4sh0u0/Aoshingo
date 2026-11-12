# aoshingo-reports（フィールドデータ受信 Worker）

Aoshingo iOS アプリから、ユーザーが明示的に同意（オプトイン）した場合だけ送られてくる
匿名化済みのフィールドデータを受け取る Cloudflare Worker です。
API の仕様（エンドポイント、検証ルール、エラーコード、プライバシー規則）は
[`docs/field-data-api.md`](../docs/field-data-api.md) が正であり、この Worker はそれを実装しています。

## 何をするか

| エンドポイント | 内容 |
| --- | --- |
| `GET /v1/health` | 死活確認。`{"ok": true}` を返します。 |
| `POST /v1/challenge` | 有効期限 300 秒のチャレンジ（16 バイト乱数と期限に `TOKEN_SECRET` で HMAC 署名したもの）を発行します。保存しないので D1 には書き込みません。その日の書き込み上限で鍵をもう 1 つ登録できないとき（またはデータベースが上限の大きさを超えているとき）は、`503 over_capacity` を返します（D1 の読み取り 1 回だけで確かめます）。 |
| `POST /v1/attest` | App Attest の attestation を Apple の手順どおりに検証し、公開鍵を登録してアップロード用トークンを返します。 |
| `POST /v1/token` | 登録済みの鍵による assertion を検証し（署名・rpIdHash・カウンタの単調増加）、トークンを再発行します。 |
| `POST /v1/reports` | `Authorization: Bearer <token>` 付きのレポート（最大 256 KiB、`schema` 1〜4）を検証し、交差点ごとに 1 行として D1 に保存します。schema 4 では、端末の時計の確認の結果（`clock_ok`）だけを行に保存します。 |
| `GET /v1/plans` | `Authorization: Bearer <token>`（`/v1/reports` と同じ送信用トークン）付きの要求に、信号の時刻表（[`docs/timing-estimation.md`](../docs/timing-estimation.md)）を返します。読み取りだけで、D1 には書き込みません。 |

- App Attest の証明書チェーンは、ソースに埋め込んだ **Apple App Attestation Root CA**
  （SHA-256 フィンガープリント `1C:B9:82:3B:A2:8B:A6:AD:2D:33:A0:06:94:1D:E2:AE:4F:51:3E:F1:D4:E8:31:B9:F7:E0:FA:7B:62:42:C9:32`）
  に固定（ピン留め）して検証します。本番コードで別のルートを信頼させる設定（環境変数など）はありません。
  テストだけが `createApp({ attestationRootForTesting })` という関数引数で偽のルートを渡します。
- トークンはステートレスです。中身は「ランダムな 16 バイトの ID」「有効期限」「App Attest の環境
  （production / development）」だけで、`TOKEN_SECRET` による HMAC-SHA256 で改ざんを防ぎ、定数時間で比較します。
- cron は 2 つあり、`scheduled()` は `controller.cron` で処理を分けます（知らない cron では何もせずにエラーで終わります）。
- 毎日 03:00 JST（`0 18 * * *` UTC）の cron（`src/cron.ts`）で、次のことをします。
  - `RETENTION_DAYS`（既定 90 日）を過ぎたレポート行を、集計テーブルに畳み込んでから削除する
  - 30 日使われていない App Attest の鍵を削除する
  - 1 週間より前の書き込み量の記録を削除する
  - 実行結果を `service_state` に 1 行だけ記録する（下の「cron の実行結果の確認」）
  - どれかの処理が失敗しても、残りの処理は実行します（たとえば畳み込みが D1 の上限で失敗しても、鍵は削除します）。
    その回は `service_state` を更新せず、最後に失敗した処理のエラーで終わります。
- 毎日 03:30 JST（`30 18 * * *` UTC）の cron（`src/timing.ts`）で、信号の時刻表を当てはめます
  （計算は [`docs/timing-estimation.md`](../docs/timing-estimation.md) の「暦」と「当てはめ」のとおり）。
  - 使うのは `clock_ok = 1` で、受信日（UTC）がその日より前の行だけです。
  - まだ当てはめていない交差点、次に前回の当てはめが古い交差点から順に、1 回に最大 12 交差点を処理します
    （その日にもう当てはめた交差点は除きます）。交差点ごとに、時刻表の行をすべて置き換え、名称と位置を更新します（1 回のバッチ）。
  - 時刻表の行の書き込み（削除と追加）が 4,000 行を超えたら、新しい交差点を始めず、残りを翌日に回します。
  - 1 つの交差点で失敗しても、ほかの交差点は処理します。その回は `service_state` を更新せず、エラーで終わります。
  - 重い計算（payload からの transition の取り出し、暦、周期の中央値、位相の単位ベクトルの合計）は D1 の SQL で行い、
    Worker は交差点ごとに、周期が条件を満たしたセルの合計だけを受け取ります。payload を Worker で JSON として読むことはしません。
- D1 に書き込む `/v1/attest`・`/v1/token`・`/v1/reports` は、書き込む前に 1 日の書き込み上限を確かめます
  （下の「1 日の書き込み上限」）。`/v1/challenge` も、鍵を登録できる余裕があるかを読み取りだけで確かめます。

### データベース（D1）

| テーブル | 内容 |
| --- | --- |
| `daily_usage` | 日（UTC）ごとの書き込み行数と、保存したバイト数の見積もりだけ。1 週間で cron が削除します。 |
| `attest_keys` | App Attest の鍵 ID・公開鍵・署名カウンタ・環境・登録日・最後に使われた日（どちらも UTC の日単位）。レポートとは一切結び付けません。最後に使われてから 30 日たつと cron が削除します。 |
| `reports` | 1 レポート × 1 交差点 = 1 行。受信日（UTC、日単位）、schema、client、件数（observation、transition、`aggregate_items`）、payload（serviceUUIDs / emitters / observations / transitions の JSON。schema 2〜4 では emitterInfo / steps / packets / coverage / labels も、項目ごとのフィールドをすべて書き出し、不明な値は null。schema 3 と 4 では observation に `activity`、schema 4 では transition と step に `ms` も入ります）、`clock_ok`（schema 4 の端末の時計の確認：差が 2000 ミリ秒以内なら 1、超えれば 0。schema 1〜3 は NULL）。`sentAt` も時計の差そのものも保存しません。`aggregate_items` は、この行を畳み込むときに集計テーブルに足す行数の上限です（schema 1 は observation + transition、schema 2〜4 は observation × 2 + transition × 3 + step + label）。主キーはランダムな整数（0 以上 2^53 未満）で、到着順を残しません。`clock_ok = 1` の行だけが部分インデックス `reports_for_timing`（交差点 ID × 受信日）に入り、時刻表の cron はそれを読みます。 |
| `transition_counts` | 保持期間後も残る集計：交差点 × スロット × 遷移元 × 遷移先 × 時刻（JST の時）ごとの件数。 |
| `observation_counts` | 保持期間後も残る集計：交差点 × メッセージ種別（raw から取得）× RSSI × 方位 × 端末の向きごとの件数。不明値は RSSI = 1、方位・向き = -1 で表します。 |
| `duration_counts` | 保持期間後も残る集計（schema 2）：交差点 × 種類（`held`・`cycle`・`step`）× スロット × 状態 × 残り目安 × 曜日（JST、0 = 日曜）× 時刻（JST の時）× 続いた秒数（ミリ秒を秒に四捨五入）ごとの件数。`held` は transition の `held`（状態は `from`）、`cycle` は `cycle`（状態は `to`）、`step` は `steps[].held`（残り目安は `from`、不明なら 0）から数えます。`held` と `cycle` の残り目安は 0 です。 |
| `range_counts` | 保持期間後も残る集計（schema 2）：交差点 × RSSI × 距離 × 方位ごとの、距離のある observation の件数。不明値は `observation_counts` と同じです。 |
| `crosswalk_labels` | 保持期間後も残る集計（schema 2）：交差点 × スロット × 方位 × 端末の向き × 距離ごとの `crosswalk` の印の件数。不明値は -1 です。`packets`、`coverage`、`button` の印、observation の `activity`（schema 3）は集計せずに削除します。 |
| `timing_plans` | 信号の時刻表：交差点 × 信号の番号（slot）× 日の種類 × 時間帯（bin）ごとに、公開の条件を満たしたセルだけ 1 行。周期・基準（`epoch` か `midnight`）・位相・ばらつき・青と青点滅の長さ（すべてミリ秒）、日数、報告の行数、最後の日（JST）、更新した日（UTC）。信号機のふるまいだけで、個人に関わる情報は含みません。保存期間は定めず、当てはめのたびに交差点ごとに置き換えます。 |
| `timing_places` | 当てはめた交差点ごとに 1 行：当てはめに使った行の observation のうち、時刻 `t` が最も新しい名称（メッセージ種別 0）と位置（種別 1）の `raw`（信号機が発信している公開の情報）、最後に当てはめた日（UTC）。使った行にどちらかがなければ、前回の値を残します（時刻表も行より長く残るため）。 |
| `service_state` | 最後に成功した cron の実行結果（時刻、畳み込んだ行数、削除した鍵の数、書き込んだ行数、データベースの大きさ、時刻表の cron の結果）。1 行だけで、個人に関わる情報は含みません。 |

スキーマは [`migrations/`](migrations/) にあります（`0003` で `challenges` テーブルを削除し、`reports` を作り直しました。
`0004` で schema 2 の集計テーブル 3 つと `reports.aggregate_items` を追加しました。`0005` で `reports.clock_ok` と
部分インデックス `reports_for_timing`、`timing_plans`、`timing_places`、`service_state` の時刻表の cron の列を追加しました）。

## プライバシー保証

- **IP アドレスなどを読みません。** `CF-Connecting-IP`、`X-Forwarded-For`、`CF-IPCountry`、`request.cf` などは
  コード中で一度も参照していません（読むヘッダーは `Content-Type`、`Content-Length`、`Authorization` だけで、
  テストでソースを静的に検査しています）。レート制限も IP ではなく、トークンのランダム ID、鍵 ID のハッシュ、固定のキーのどれかで行います。
- **ログを残しません。** デプロイ設定（`cloudflare.config.ts`）で Workers Logs・呼び出しログ・トレースを無効にしており、
  コードには `console.*` が一切ありません。リクエスト本文やトークンを記録する経路はありません。
- **端末を特定できる情報をレポートと一緒に保存しません。** トークンには App Attest の `keyId` を含めず、レポート行には
  トークンもトークン ID も `keyId` も保存しません（テストで確認しています）。`keyId` は `attest_keys` テーブルにだけ存在し、
  レポートとは紐付きません。受信日は日単位でしか保存しません。
- **結び付けられる可能性も正直に書きます。** 1 つのトークン（最長 6 時間有効）で送ったレポートは、受信して処理している間は
  同じトークンで届いたことが分かります（サーバーはそれを保存しません）。また、レポートの中の時刻 `t` は秒単位なので、
  保存された行でも、時刻の続く行を並べれば同じ人が続けて通った交差点を推測できる可能性があります。
- **端末の時計のずれを残しません。** schema 4 の `sentAt` は、要求を受け付け始めた時刻（本文を読む前）との差が 2 秒以内かどうか
  （`clock_ok` の 1 か 0）を決めるためだけに使い、`sentAt` も差そのものも保存しません。端末ごとに決まった時計のずれは、
  報告どうしを結び付ける手がかりになるためです（テストで確認しています）。
- **時刻表から協力者の通った時刻が分からないようにします。** 時刻表の cron は、受信日（UTC）がその日より前の行だけを使います。
  時刻表と `timing_places` には、信号機のふるまいと信号機が発信している名称・位置だけが入り、日付より細かい時刻
  （更新した日、最後の日）は残しません。
- **想定外のデータを受け取りません。** レポートは仕様の検証表どおりに厳密に検証し、未知のフィールド（緯度経度など）が
  含まれていれば全体を `400 invalid_report` で拒否します。`raw` は、アプリの解析器（`PICSPacket.swift`）が受け付ける
  形だけを受け付けます。保存するのは検証済みの値から組み立て直した JSON だけです。
- **保持期間を守ります。** 次のとおりです（cron が予定どおり動いた場合）。
  - レポート行（秒単位の時刻を含む）：受信日（UTC）の 91 日後の 18:00 UTC の cron で集計に畳み込んで削除します。
    受信から最長 91 日 18 時間です。cron が 1 回で終わらなかった分は翌日に回ります。
  - App Attest の鍵：最後に使われた日（UTC）の 31 日後の 18:00 UTC の cron で削除します。最後に使われてから最長 31 日 18 時間です。
  - 集計テーブルには、時刻を JST の時と曜日までしか残しません。
  - 削除したデータも、D1 の Time Travel で、削除から 7 日間（Free プランの場合。Workers Paid は 30 日）はデータベースごと
    削除前の状態に戻せます。Time Travel を使えるのは、Cloudflare アカウントで D1 を操作できる運用者だけです。

## 開発

Node.js は 22.23 以降（22 系）、24.22 以降（24 系）、または 26.12 以降が必要です（`cf` の `engines` が
`^22.23.0 || ^24.22.0 || ^26.12.0` のため）。デプロイには Cloudflare CLI（`cf`、開発用依存として固定）を使います。

```sh
cd server
npm ci                 # package-lock.json どおりにインストール
npm test               # vitest（workerd + ローカル D1 上で実行。2 つの設定ファイルの一致も確かめる）
npx tsc --noEmit       # 型チェック（cloudflare.config.ts を含む）
npx cf build           # バンドルの確認（アップロードはしない）
npx cf deploy --dry-run   # デプロイされるバインディングの確認（アップロードはしない）
```

設定ファイルは 2 つあります。デプロイに使うのは `cloudflare.config.ts`（`cf` が読む）で、
`wrangler.jsonc` はテスト専用です（`@cloudflare/vitest-plugin` が読むため残しています）。
バインディング・変数・cron を変えるときは、両方を同じ内容にしてください。
食い違うと `test/config.test.ts` が失敗します（名前、互換性の日付とフラグ、ログの無効化、変数、秘密鍵の宣言、
D1 とマイグレーションのディレクトリ、レート制限、cron を比べます）。

`vite` は vitest の依存として入るので、`package.json` に直接書かないでください。
書くと `cf` がこのプロジェクトを Vite のアプリと判定し、Wrangler ではなく `vite build` を実行して `cf build` が失敗します。

依存関係はすべて開発用で、バージョンは固定しています。Worker 本体は外部ライブラリを使わず、
CBOR・DER（X.509）の最小限のパーサーと WebCrypto だけで動きます。
`package-lock.json` を作り直す場合は npm 11 以降を使ってください（npm 10 は依存解決中にエラーになることがあります。
既存の lock ファイルからの `npm ci` は npm 10 でも動きます）。

## デプロイ（Cloudflare の Git 連携で自動）

Cloudflare の **Workers Builds**（GitHub 連携）で、`main` ブランチに `server/` の変更が入るたびに自動でデプロイします。
GitHub Actions からはデプロイしません。CI（`.github/workflows/ci.yml`）は型チェック・テスト・`npx cf build` だけを行います。
つまり **PR を `main` にマージすることが本番へのデプロイ**です。

Workers Builds は CI の結果を見ません。CI が通らない変更を `main` に入れないように、リポジトリ所有者が GitHub の
**Settings → Branches**（または Rules）で `main` のブランチ保護を設定し、「Cloudflare Worker」のチェックを必須にしてください。

デプロイ時には `npm run deploy` が実行され、`cf d1 migrations apply` で未適用の D1 マイグレーションを適用してから `cf deploy` します。
マイグレーションを適用してから新しいコードが動き出すまで（通常 1 分以内）は、古いコードが新しいスキーマで動きます。
`0003` では、その間に古い版の `/v1/challenge`（`challenges` テーブルに書く版）、`/v1/attest`、`/v1/token`、`/v1/reports` が
`500` を返すことがあります。アプリは後で自動で送り直すので、この短い停止は許容しています。
また、`0003` は今ある鍵の「最後に使われた日」を登録日にするので、登録から 30 日を過ぎた鍵は最初の cron で削除されます。
その端末のアプリは次のトークン更新で `404 unknown_key` を受け取り、鍵を 1 回だけ登録し直します。
以後のマイグレーションは、できるだけ古いコードでも動く形（列の追加など）にしてください。
`0004` はテーブルと既定値付きの列を足すだけなので、古いコードもそのまま動きます。それまでに保存した行と古いコードが
保存した行は `aggregate_items` が 0 になりますが、cron は少なくとも observation + transition の件数（schema 1 の行では正確な値）で数えます。
既存の行は書き換えないので、`reports` が大きくても書き込み行数を使いません。
古いコードは知らない schema（schema 2 を受け付ける前のコードなら schema 2、その次のコードなら schema 3、
その次なら schema 4）を `400 invalid_report` で断り、アプリはそのレポートを捨てるので、新しい schema を送るアプリは
それを受け付けるサーバーをデプロイしてから公開してください。schema 3 にはマイグレーションがありません。
`0005`（schema 4 と時刻表）も、NULL を許す列、部分インデックス、テーブルを足すだけなので、古いコードもそのまま動きます。
古いコードが保存する行は `clock_ok` が NULL なので部分インデックスに入らず、書き込み行数の数え方も変わりません。
古いコードの日次の cron は `service_state` の自分の列だけを書きます。2 つ目の cron（`30 18 * * *`）は、
新しいコードと同じデプロイで追加されます。

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

   依存関係は `package-lock.json` から自動でインストールされます。Node.js のバージョンは `server/.node-version`（22）で指定しています
   （ビルド環境には 22.23.4 が入っており、`cf` の条件を満たします）。
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
   `Config/Local.xcconfig`（Git 管理外。[開発ガイド](../docs/development.md) を参照）にホスト名だけ（`https://` やパスは付けない）を書きます。
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

`<Database ID>` は `cloudflare.config.ts` の `DB` の `id` です。`cf` で SQL を実行するコマンドは `cf d1 query` です
（`cf d1 execute` はありません）。読み取りも D1 の読み取り行数に数えられます。

```sh
npx cf d1 query <Database ID> \
  --sql "SELECT intersection_id, received_day, observation_count, transition_count FROM reports LIMIT 20"
npx cf d1 query <Database ID> \
  --sql "SELECT * FROM transition_counts ORDER BY count DESC LIMIT 20"
```

### cron の実行結果の確認

Worker はログを残さないので、cron は成功するたびに結果を `service_state` の 1 行に上書きします。
どれかの処理が失敗した回は、残りの処理は実行しますが記録しないので、`cron_last_success` が古いままになります。

```sh
npx cf d1 query <Database ID> --sql "SELECT * FROM service_state"
npx cf d1 query <Database ID> --sql "SELECT * FROM daily_usage ORDER BY day DESC LIMIT 7"
```

| 列 | 内容 |
| --- | --- |
| `cron_last_success` | 最後に成功した実行の開始時刻（UTC）。1 日以上前なら、cron が失敗しているか動いていません。 |
| `folded_reports` | 集計に畳み込んで削除したレポート行の数 |
| `backlog` | `1` なら上限で止まり、期限切れの行が翌日に回りました。続くときは cron の上限を見直します。 |
| `deleted_keys` | 30 日使われずに削除した鍵の数 |
| `rows_written` | その実行で書き込んだ行数（インデックスを含む） |
| `database_bytes` | 実行後のデータベースの大きさ（D1 の `size_after`、バイト） |
| `timing_last_success` | 時刻表の cron が最後に成功した実行の開始時刻（UTC）。まだ成功していなければ NULL。1 日以上前なら、時刻表の cron が失敗しているか動いていません。 |
| `timing_fitted` | その実行で当てはめた交差点の数 |
| `timing_plan_rows` | その実行で保存した時刻表の行の数 |
| `timing_backlog` | `1` なら、時刻表の行の書き込みが 4,000 行を超えて止まり、残りの交差点が翌日に回りました。 |
| `timing_waiting` | 当てはめる行があるのに、その実行で当てはめなかった（上限を超えた、または失敗した）交差点の数。12 を超える交差点にデータがあれば、毎日順に回ります。 |
| `timing_rows_written` | 時刻表の cron がその実行で書き込んだ行数 |

日次の cron がまだ一度も記録していないときに時刻表の cron が成功すると、日次の cron の列を空（`cron_last_success` は空文字、件数は 0）にした行を作ります。
日次の cron は、次に成功したときに自分の列を上書きします。

`daily_usage` には、その日の API による書き込み行数（`rows_written`）と保存量の見積もり（`stored_bytes`）が入っています。

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
Worker は自分の書き込みに上限を設けています（`src/budget.ts`、`src/storage.ts`、`src/keys.ts`、`src/cron.ts`）。

| 対象 | 上限 | 既定値 |
| --- | --- | --- |
| API による書き込み行数（UTC の 1 日） | `DAILY_WRITE_LIMIT` | 30,000 行 |
| API による保存量の見積もり（UTC の 1 日） | `DAILY_STORAGE_LIMIT_BYTES` | 3,000,000 バイト |
| データベースの大きさ | `MAX_DATABASE_BYTES` | 450,000,000 バイト |
| cron の 1 回の書き込み行数 | `DEFAULT_FOLD_LIMITS`、`KEY_DELETE_LIMIT`（コード内） | 畳み込みは 45,000 行で新しいチャンクを始めない（最大で約 52,000 行）、鍵の削除は 10,000 行まで |
| cron の 1 回の D1 クエリ数 | 同上 | 最大 43 回（無料枠は 1 回の呼び出しで 50 回） |
| 時刻表の cron の 1 回の書き込み行数 | `DEFAULT_TIMING_LIMITS`（`src/timing.ts`） | 最大 12 交差点。時刻表の行の書き込みが 4,000 行を超えたら新しい交差点を始めない（最大で 5,741 行） |
| 時刻表の cron の 1 回の D1 クエリ数 | 同上 | 最大 26 回 |

- 行数はインデックスへの書き込みも含めて数えます。レポートは「交差点数 × 2 + 1」行（`clock_ok = 1` の schema 4 では
  部分インデックスの分も足して「交差点数 × 3 + 1」行）、
  `/v1/attest` と `/v1/token` は 2 行です（`/v1/token` は「最後に使われた日」も同じ行の更新で記録するので増えません）。
  テストで D1 自身が返す書き込み行数と一致することを確かめています。
- 保存量は、レポート 1 行ごとに本文の長さから見積もった大きさ（ほかの列、インデックス、ページの空きを含む。
  `rowStorageBytes()`）と、鍵 1 つあたり 300 バイトを数えます。SQLite は 4 KiB のページに行を詰めるため、
  本文が 2〜4 KB の行は 1 行で 1 ページ（約 4.1 KB）を使います。見積もりは、ローカルの D1 で 150 B〜60 KB の本文を
  実測した大きさ以上になるようにしてあります（`test/storage.test.ts`）。`clock_ok = 1` の行は、部分インデックスの分として
  さらに 64 バイトを数えます（ローカルの実測は 1 行あたり 30〜40 バイト程度）。
- 上限に達すると、その日は `503 over_capacity` を返して何も保存しません。`/v1/challenge` も、鍵をもう 1 つ登録できないときは
  `503` を返すので、アプリは Apple に鍵の証明を頼む前に止まります。アプリは時間をおいて送り直し、
  端末内のレポートは 6 日まで残ります。
- データベースの大きさは、D1 がクエリごとに返す `size_after` で確かめます（読み取りでも返ります）。
  D1 は `PRAGMA page_count` や `PRAGMA freelist_count` を Worker に許していないので、ページ数は直接は読めません。
  ただし `size_after` は使用中のページだけを数えます。ローカルの workerd は `(page_count − freelist_count) × page_size`
  で計算しており、本番の D1 も auto-vacuum で動いていると Cloudflare が説明しています
  （[workerd#1618](https://github.com/cloudflare/workerd/issues/1618)）。そのため、上限を超えても cron が古い行を
  削除すれば値が下がり、書き込みは自動で再開します（テストで確かめています）。
- 1 日の書き込み行数の合計は、最大でも API の 30,000 + 日次の cron の約 62,000 行（畳み込みの 1 チャンクは、集計 4,000 行と、
  削除する行の表・受信日のインデックス・部分インデックスの 3 × 1,000 行まで）+ 時刻表の cron の 5,741 行 ≈ 98,000 行で、100,000 行を下回ります。
- データベースの大きさの見積もり（最悪の場合）:
  - レポート行と鍵：1 日に増えるのは最大 3 MB です。レポート行は最長 91 日 18 時間、鍵は最長 31 日 18 時間で削除されるので、
    合わせて最大で約 3 MB × 92 日 ≈ 275 MB です。実際の行は見積もりより小さいことが多く（本文 150 B の行は約 280 バイト）、
    これより少なくなります。
  - `daily_usage`（8 行程度）と `service_state`（1 行）はごくわずかです。
  - 時刻表（`timing_plans`、1 行 100 バイト程度）は削除しませんが、交差点ごとに置き換えるので、ふつうは時刻表のある交差点の数 ×
    セルの数で頭打ちになります。正規の端末が存在しない交差点 ID の、条件を満たすデータを送り続けると、最悪で 1 日 4,864 行
    （4,000 + 1 交差点の最大 864 行、約 0.5 MB）ずつ増えます。集計テーブルと同じく、`database_bytes` が増え続けるときは不要な行を手で削除してください。
  - 集計テーブルは削除しません。1 行は 50〜70 バイト程度で、ふつうは交差点・信号・時間帯の組み合わせの数で頭打ちになります。
    ただし、正規の端末から存在しない交差点 ID のデータを上限いっぱいに送り続けると、最悪で 1 日 3 MB ほど増え続け、
    約 2 か月で `MAX_DATABASE_BYTES` に達します。こうして超えた分は cron では減らないので、`service_state` の
    `database_bytes` を時々確かめ、増え続けているときは集計テーブルの不要な行を手で削除してください。
- 1 台の端末が正規のトークンで上限まで送ると、その日はほかの利用者のレポートも受け付けなくなります。
  端末を区別しない設計のため、これは防げません。D1 全体が止まるのを防ぐことを優先しています。
- cron は 1 回に最大 20 チャンク（1 チャンクは 1,000 行まで、かつ `aggregate_items` の合計が 4,000 まで）を畳み込みます。
  `aggregate_items` は 1 行が集計テーブル 5 つに足す行数の上限なので、1 チャンクの書き込みは集計 4,000 行と削除 2,000 行
  （表とインデックス）までに収まります。1 行の `aggregate_items` は最大 2,720 なので、どの行も 1 チャンクに入ります。
  終わらなかった分は翌日に回します（`service_state.backlog` が `1` になります）。
  1 日の保存量の上限から、1 日に届く行は最大でも約 4,900 行（いちばん小さい行でも 617 バイトと数えるため）なので、ふだんは 1 回で終わります。
  ただし、信号の変化ばかりの重い行（`aggregate_items` が 2,000 を超える行は 1 チャンクに 1 行）を正規の端末が毎日上限まで送り続けると、
  1 日に届く分が 1 回で畳み込める分（約 20 行）を上回り、積み残しが日ごとに増えます。そのときはレポート行が 91 日 18 時間より長く残るので、
  プライバシーポリシーにも「通常は」と、長くなる場合があることを書いています。`backlog` が続くときは上限を見直してください。
- 時刻表の cron は、`clock_ok = 1` の行だけを部分インデックスで読みます（全件は読みません）。交差点ごとの計算は D1 の中で行うので、
  Worker の CPU 時間は交差点ごとに受け取るセルの数（多くても数十）にしか比例せず、無料枠の 10 ms に収まる見込みです
  （Cloudflare 上の実測ではありません）。`GET /v1/plans` も、応答の JSON を D1 の SQL で組み立てて、Worker は文字列のまま返します。
- 鍵の削除は、`attest_keys` を 1 日 1 回全件読みます（`last_used_day` に索引を付けると、トークンの更新ごとに書き込み行が
  増えるため）。鍵は最大でも 1 日 10,000 個（保存量の上限から）しか増えないので、読み取りの無料枠（1 日 500 万行）に収まります。
- Workers Paid プランでは、上の値を `cloudflare.config.ts` と `wrangler.jsonc` で上げられます。

### レート制限

Workers Rate Limiting を使っています（期間は 10 秒か 60 秒のみ指定可能、カウンタは Cloudflare の拠点ごと）。

| バインディング | キー | 既定値 |
| --- | --- | --- |
| `REPORTS_RATE_LIMITER` | `/v1/reports` はトークンのランダム ID、`/v1/plans` は `plans:` + トークンのランダム ID | 60 秒あたり各 6 回 |
| `AUTH_RATE_LIMITER` | `/v1/attest` は固定キー `attest`、`/v1/token` は鍵 ID の SHA-256 の先頭 16 バイト | 60 秒あたり各 30 回 |

`AUTH_RATE_LIMITER` は、attestation や assertion の検証に通ったリクエストだけを数えます。
そのため、不正なリクエストを大量に送っても、正規の利用者が `429 rate_limited` になることはありません。
`/v1/challenge` は読み取りだけで何も書き込まないので、レート制限をかけていません（IP を使わない以上、キーが共通になり、
1 つのクライアントがほかの全員を締め出せてしまうため）。

`/v1/attest` の固定キー `attest` は、1 台の正規の端末でも、提供のオン・オフを繰り返せば埋められます。
その間（その拠点で 1 分ごと）は新しく提供を始める端末が `429` になりますが、繰り返すには毎回 Apple の証明が必要で、
やめれば 1 分で戻ります。これ以上の対策（全体の上限を下げる、1 日の鍵の数に上限を設ける）はしていません。
上限を下げると締め出しやすくなり、1 日の上限にすると締め出しが UTC の翌日まで続くためです。
鍵が増え続ける心配は、30 日使われない鍵の削除と、1 日の保存量の上限（鍵 1 つを 300 バイトと数える）で抑えています。
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
│   ├── keys.ts             App Attest の鍵の保存と、使われなくなった鍵の削除
│   ├── report.ts           レポートの検証（raw は PICS のメッセージ種別ごとの長さも確かめる）
│   ├── storage.ts          レポートの保存（端末の時計の確認を含む）、保存量の見積もり、集計への畳み込み
│   ├── cron.ts             毎日の cron（畳み込み、鍵と古い記録の削除、service_state への記録）
│   ├── timing.ts           暦、時刻表の当てはめの cron、GET /v1/plans の応答
│   ├── env.ts, http.ts, encoding.ts
└── test/                   vitest のテスト（偽のルート CA → 中間 CA → 端末証明書を生成して検証。
                            config.test.ts は 2 つの設定ファイルを比べる）
```
