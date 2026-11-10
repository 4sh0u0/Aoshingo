# 第三者のライセンス（Third-party notices）

## ble-pics-viewer

- リポジトリ：<https://github.com/yumu19/ble-pics-viewer>
- 利用箇所：高度化PICS アドバタイズの解析オフセットと信号の符号化（`process_pics()` / `web/pics.mjs`）、交差点ごとの状態と履歴の扱い（`updateIntersection()` / `recentHistory()`）、デモ用パケット生成（`demoPackets()`）、およびテストケース（`web/tests/pics.test.mjs`）を Swift に移植しました。
  - `Packages/AoshingoKit/Sources/PICSKit/PICSPacket.swift`
  - `Packages/AoshingoKit/Sources/PICSKit/IntersectionState.swift`
  - `Packages/AoshingoKit/Sources/PICSKit/DemoAdvertiser.swift`
  - `Packages/AoshingoKit/Tests/PICSKitTests/PICSParserTests.swift`
  - `Packages/AoshingoKit/Tests/PICSKitTests/IntersectionStateTests.swift`

```
MIT License

Copyright (c) 2025 Tsubasa Yumura

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Apple App Attestation Root CA

`server/` の Worker は、App Attest の証明書チェーンを検証するために Apple の公開ルート証明書（<https://www.apple.com/certificateauthority/Apple_App_Attestation_Root_CA.pem>）をソースに埋め込んでいます。

## 今後同梱する予定のデータ

次のデータはまだ同梱していません。同梱する時点で、ここと App 内の「謝辞・ライセンス」に出典を追記します。

- 警察庁「高度化PICS整備交差点」（e-Gov データポータル、CC BY）：「出典：警察庁「高度化PICS整備交差点」（e-Govデータポータル）を加工して作成」
- OpenStreetMap 由来の横断歩道データ（ODbL）：「© OpenStreetMap contributors」
