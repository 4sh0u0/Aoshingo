# 実測データ送信 API（v1）

この文書は、Aoshingo iOS アプリ（`Packages/AoshingoKit/Sources/FieldDataKit`）と `server/` の Cloudflare Worker との間の取り決めです。アプリとサーバーの両方がこれに従います。変更するときは、コードと同じ Pull Request でこの文書も更新してください。

実測データの提供は**利用者が選んだ場合だけ**行います（オプトイン）。初回起動時に選び、設定画面でいつでもオフにできます。オフのとき、アプリは何も送信しません。

## プライバシーの決まり（アプリとサーバーの両方が守ること）

- アプリは緯度・経度、機種、OS のバージョン、言語・地域、広告 ID、インストールごとの永続 ID を送信しません。インストールごとの識別子は App Attest の `keyId` だけで、これは `/v1/attest` と `/v1/token` にだけ送り、サーバーでは実測データとは別に保存します。
- HTTP ヘッダーの `User-Agent` は `Aoshingo`、`Accept-Language` は `en` に固定します。iOS の標準の値には OS のバージョンや端末の言語が入るためです。
- Worker は `CF-Connecting-IP`、`X-Forwarded-For`、`CF-IPCountry` などのヘッダーを読みません。リクエスト本文をログに出さず、Workers のオブザーバビリティ（ログ・トレース収集）を無効にして動かします。
- 送信用トークンに含めるのはランダムなトークン ID と有効期限だけで、`keyId` は含めません。実測データの行には、トークンもトークン ID も `keyId` も保存しません。受信日は日単位でだけ保存します。
- ただし、次の点で送信同士を結び付けられる可能性があります。
  - 1 つのトークンは最長 6 時間有効で、その間に送るレポートはすべて同じトークンを使います。サーバーはトークンを保存しませんが、受け取って処理している間は、同じトークンで届いたレポートだと分かります。
  - レポートの中の時刻 `t` は秒単位で、保存した行にも残ります。時刻の続く行を並べれば、同じ人が続けて通った交差点を推測できる可能性があります。
- 実測データの行（秒単位の時刻を含む）は `RETENTION_DAYS`（初期値 90 日）を過ぎるまで保存します。毎日 18:00 UTC（03:00 JST）の cron が、受信日（UTC）から 91 日目の行を交差点ごとの集計に畳み込んでから削除します。受信から削除までは最長 91 日と 18 時間です（cron が予定どおり動いた場合。1 回で終わらなかった分は翌日に回ります）。
- App Attest の鍵（`keyId` と公開鍵）は、最後に使われた日（UTC）から 30 日を過ぎると、同じ cron が削除します。最後に使われてから最長 31 日と 18 時間です。
- 削除したデータも、Cloudflare D1 の Time Travel により、削除から 7 日間（Workers Free プランの場合）はデータベースごと削除前の状態に戻せます。戻せるのはサーバーの運用者だけです。

## 通信の共通事項

- HTTPS のみ。本文は JSON（`Content-Type: application/json`）、UTF-8。
- エラーは 2xx 以外のステータスと `{"error": "<コード>"}` の本文で返します。コードはエンドポイントごとに示します。
- `503 over_capacity` は、サーバーがその日（UTC）に書き込める量の上限に達したか、データベースが上限の大きさを超えていることを表します。データは保存されていません。時間をおいて同じ内容を送り直してください。上限は Cloudflare の無料枠を守るためのものです（`server/README.md`）。
- バイナリ値は base64 で表します。`keyId`、`attestation`、`assertion` はパディング付きの標準 base64（`DCAppAttestService` と `Data.base64EncodedString()` が出力する形式）、チャレンジとトークンはパディングなしの base64url です。
- 時刻は Unix 秒（整数）です。

## エンドポイント

### `GET /v1/health`

`200 {"ok": true}`

### `POST /v1/challenge`

有効期間 300 秒のチャレンジを発行します。リクエスト本文は不要です（`{}` でも可）。

`201 {"challenge": "<base64url、不透明な文字列>", "expiresAt": 1794290300}`

チャレンジはサーバーの秘密鍵で署名したもので、サーバーは保存しません（発行してもデータベースに書き込まないため、レート制限もありません）。クライアントは中身を解釈せず、文字列のまま扱ってください。

その日の書き込みの上限で鍵をもう 1 つ登録できないとき、またはデータベースが上限の大きさを超えているときは、チャレンジを発行せずに `503 over_capacity` を返します（サーバーは読み取りだけで確かめます）。クライアントはこのとき Apple に鍵の証明（`attestKey`）を頼まず、時間をおいてやり直してください。チャレンジを受け取れても、続く `/v1/attest` や `/v1/token` が `503` になることはあります。

エラー：`503 over_capacity`

クライアントは `clientDataHash = SHA-256（受け取ったチャレンジ文字列そのままの UTF-8 バイト列）` を計算します。

同じチャレンジを有効期間内に 2 回使っても、チャレンジとしては拒否しません。再送攻撃は次の 2 点で防ぎます。

- `/v1/attest`：同じ `keyId` は 1 回しか登録できません（2 回目は `409 key_exists`）。
- `/v1/token`：assertion のサインカウンタが保存済みの値より大きくなければ `401 assertion_invalid` です。

どちらもチャレンジは `clientDataHash` を通じて署名に含まれるので、チャレンジは「最近作られたリクエストであること」を保証します。クライアントはリクエストごとに新しいチャレンジを取ってください。

### `POST /v1/attest`

App Attest の鍵を登録し、送信用トークンを返します。鍵ごとに 1 回だけ使います（利用者が提供をオンにしたとき、または鍵を作り直したとき）。

リクエスト：

```json
{ "keyId": "<base64>", "attestation": "<base64 CBOR>", "challenge": "<base64url>" }
```

Worker はチャレンジの署名と有効期限を確かめ（このサーバーが発行したものでない、または期限切れなら `400 bad_challenge`）、Apple の「Validating apps that connect to your server」に従って attestation（構成証明）を検証します。

1. CBOR をデコードします。`fmt` は `apple-appattest`、`attStmt.x5c` は `[credCert, intermediate]` であること。
2. credCert → intermediate → 埋め込んだ Apple App Attestation Root CA の証明書チェーンを、現在時刻での有効期間も含めて検証します。
3. `nonce = SHA-256(authData ‖ clientDataHash)` が、credCert の拡張 `1.2.840.113635.100.8.2`（`SEQUENCE { [1] EXPLICIT OCTET STRING }`）の中のオクテット列と一致すること。
4. `SHA-256（credCert の公開鍵、非圧縮 X9.62 形式）` が、デコードした `keyId` と一致すること。
5. `authData[0..<32]`（rpIdHash）が `SHA-256("<APPLE_TEAM_ID>.<APP_BUNDLE_ID>")` と一致すること。
6. `authData` のサインカウント（ビッグエンディアン、33..<37 バイト目）が 0 であること。
7. AAGUID（37..<53 バイト目）が `appattest` の後に `0x00` が 7 個続くもの（本番環境）であること。`appattestdevelop` は `ALLOW_DEVELOPMENT_ATTESTATION` が `"true"` のときだけ受け付けます。
8. AAGUID の後に長さ付きで続く Credential ID が、デコードした `keyId` と一致すること。

検証に通ったら、Worker はレート制限と 1 日の書き込み上限を確かめてから、鍵の公開鍵をサインカウント 0 で保存し、トークンを返します。検証に通らないリクエストはレート制限に数えません。保存するのは公開鍵、サインカウント、環境、登録日と最後に使われた日（どちらも UTC の日単位）だけです。最後に使われてから 30 日を過ぎた鍵は削除します（「プライバシーの決まり」）。

`200 {"token": "<不透明な文字列>", "expiresAt": 1794311900}`

エラー：`400 bad_request`、`400 bad_challenge`、`401 attestation_invalid`、`409 key_exists`、`429 rate_limited`、`503 over_capacity`

### `POST /v1/token`

登録済みの鍵で作った assertion（署名付きの証明）を使って、送信用トークンを取り直します。

リクエスト：

```json
{ "keyId": "<base64>", "assertion": "<base64 CBOR>", "challenge": "<base64url>" }
```

検証内容：CBOR `{signature, authenticatorData}` をデコードし、`nonce = SHA-256(authenticatorData ‖ clientDataHash)` を計算します。保存済みの公開鍵で、`nonce` に対する ECDSA P-256 / SHA-256 の署名（DER 形式）を検証します。rpIdHash は上と同じ条件です。サインカウントは保存済みの値より大きくなければなりません。検証に通ったら、鍵ごとのレート制限と 1 日の書き込み上限を確かめてから、サインカウントと「最後に使われた日」を更新します。`429` や `503` のときは何も更新しないので、同じカウンタから再試行できます。

`404 unknown_key` は、その `keyId` が登録されていないことを表します。30 日使われずに削除された鍵もこれになります。クライアントは鍵を作り直し、`/v1/attest` で登録し直してください。

`200 {"token": "<不透明な文字列>", "expiresAt": 1794311900}`

エラー：`400 bad_request`、`400 bad_challenge`、`401 assertion_invalid`、`404 unknown_key`、`429 rate_limited`、`503 over_capacity`

### `POST /v1/reports`

`Authorization: Bearer <token>` が必要です。本文は 256 KiB まで。

```json
{
  "schema": 1,
  "client": "aoshingo-ios/0.1.0",
  "intersections": [
    {
      "id": "1234ABCD",
      "serviceUUIDs": [],
      "emitters": 1,
      "observations": [
        { "t": 1794290000, "raw": "CE010000022A00001234ABCD311384848484", "rssi": -70, "bearing": 3, "heading": null }
      ],
      "transitions": [
        { "t": 1794290005, "slot": 1, "from": "Red", "to": "Green" }
      ]
    }
  ]
}
```

検証（1 つでも違反があれば `400 invalid_report` を返し、何も保存しません）：

| フィールド | 条件 |
| --- | --- |
| `schema` | `1` であること |
| `client` | 任意。40 文字以内の文字列で `^aoshingo-[a-z]+/[0-9A-Za-z.+-]+$` |
| `intersections` | 1〜50 件。`id` はレポート内で重複しないこと |
| `id` | `^[0-9A-F]{8}$` |
| `serviceUUIDs` | 0〜8 件。`^[0-9A-F]{4}$`、`^[0-9A-F]{8}$`、または大文字 36 文字の UUID |
| `emitters` | 0〜32 の整数（このレポートを集める間に、この交差点について見えた送信機の数） |
| `observations` | 0〜600 件 |
| `observations[].t` | 整数。`現在 − 7 日 ≤ t ≤ 現在 + 300 秒` |
| `observations[].raw` | 大文字の 16 進。偶数長で 24〜128 文字、`CE01`（会社 ID 0x01CE のリトルエンディアン）で始まること。会社 ID の後ろの 6..<10 バイト目が `id` と一致すること。会社 ID の後ろのバイト数が、メッセージ種別（2 バイト目）ごとの最小の長さ以上であること（下の「`raw` の検証」） |
| `observations[].rssi` | −130〜0 の 5 の倍数の整数、または `null` |
| `observations[].bearing` | 0〜7 の整数または `null`。交差点から見た利用者の方向で、0 = 北、45° ごとに時計回り |
| `observations[].heading` | 0〜7 の整数または `null`。端末の向き（真北基準）、区分は上と同じ |
| `transitions` | 0〜300 件 |
| `transitions[].t` | `observations[].t` と同じ |
| `transitions[].slot` | 1〜6 の整数 |
| `transitions[].from`、`.to` | `NoSignal`、`Red`、`BlinkGreen`、`Green`、`None`、`Unknown` のいずれかで、互いに異なること |
| 各交差点 | observation か transition が少なくとも 1 件あること |

#### `raw` の検証

`raw` は、アプリの解析器（`Packages/AoshingoKit/Sources/PICSKit/PICSPacket.swift` の `PICSParser`）が受け付け、中身を読めるメッセージ種別（0〜2）のものだけを受け付けます。アプリもこの条件に合うパケットだけを送るので（`FieldDataKit` の `ReportContract.isUploadable`）、正しいアプリのデータが拒否されることはありません。解析器を変えるときは、`server/src/report.ts` の `picsMinimumLength` も同じ Pull Request で変えてください。

会社 ID（`CE01`）の後ろの部分（PICS のペイロード）について：

| メッセージ種別（2 バイト目） | 最小の長さ | 内容 |
| --- | --- | --- |
| 0（名称） | 24 バイト | 共通ヘッダー 10 バイト + 名称 14 バイト |
| 1（位置） | 18 バイト | 共通ヘッダー 10 バイト + 交差点の緯度・経度 8 バイト |
| 2（信号） | 11 バイト | 共通ヘッダー 10 バイト + 信号 1〜6 バイト |

ほかのメッセージ種別と、最小の長さより短いものは `400 invalid_report` です。上限は `raw` 全体の 128 文字（ペイロード 62 バイト）です。

解析器は、読む部分より後ろのバイトも受け付けて、アプリはそれも送ります。そのため、サーバーもそれらを受け付けます。この部分は信号機が発信したとおりのバイト列で、サーバーはその中身が何であるかを確かめられません。アプリは利用者の緯度・経度を `raw` に入れません。

`202 {"accepted": {"intersections": 1, "observations": 1, "transitions": 1}}`

エラー：`400 invalid_report`、`401 invalid_token`、`413 too_large`、`415 unsupported_media_type`、`429 rate_limited`、`503 over_capacity`

## アプリ側で行う丸めと間引き

- 電波強度（RSSI）：`floor(rssi / 5) * 5` で 5 dB 単位に切り下げ、−130〜0 に収めます。例：−67 → −70。iOS が「取得できない」を表す 127 は `null` にします。
- 方向（bearing）と端末の向き（heading）：`Int(((度 mod 360) + 22.5) / 45) mod 8` の 8 方位に丸めます。bearing は、受信した Type 1（位置）メッセージの交差点座標と、端末内でだけ使う現在地から計算します。現在地そのものは送信しません。現在地の精度が 30 m より悪い、または 10 秒より古いときは `null` です。
- observation の間引き：交差点とメッセージ種別ごとに、前回残したパケットと比べて次のどちらかを満たすときだけ残します。比較ではメッセージ ID（会社 ID の後ろの 3 バイト目）を無視します。連番として毎回変わる可能性があるためです。
  - 内容が変わっていて、前回から 1 秒以上たっている。
  - 内容にかかわらず、再サンプル間隔がたっている。間隔は信号（Type 2 など）で 5 秒、名称（Type 0）と位置（Type 1）で 60 秒です。
- transition：収集中に見えた、信号ごとの状態の変化を秒単位の時刻で記録します。
- 1 つのレポートに含めるのは最大 10 分間のデータです。レポートには、端末やインストールを表す ID を入れません。ただし、同じトークンで送ったレポートや、時刻の続くレポートは結び付けられる可能性があります（「プライバシーの決まり」）。
