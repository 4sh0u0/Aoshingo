# 開発ガイド

Aoshingo をビルドして動かすための手順と、リポジトリの構成をまとめています。概要は [README](../README.md) をご覧ください。

## ビルド方法

必要なもの：Xcode 27.1 以降（iOS 26 SDK 以降であればビルドできます）。

```bash
git clone https://github.com/4sh0u0/Aoshingo.git
cd Aoshingo
open Aoshingo.xcodeproj
```

- 署名用の Team ID などは `Config/Local.xcconfig`（Git 管理外）に書くと、プロジェクトファイルを変更せずに済みます。

  ```
  DEVELOPMENT_TEAM = XXXXXXXXXX
  AOSHINGO_REPORT_HOST = aoshingo-reports.example.workers.dev
  ```

- `AOSHINGO_REPORT_HOST` が空のビルドは、実測データを端末内にためるだけで送信しません。
- Debug ビルドは開発用、Release ビルドは App Store 版として動きます。`Config/Local.xcconfig` に `AOSHINGO_CHANNEL = appstore` などと書くと切り替えられます。TestFlight 版の作り方とバージョン番号の決め方は [リリースとバージョン番号](release.md) をご覧ください。
- 解析ロジックは Swift Package（`Packages/AoshingoKit`）に分かれていて、macOS・Linux でテストできます。

  ```bash
  swift test --package-path Packages/AoshingoKit
  ```

## 構成

| パス | 内容 |
| --- | --- |
| `App/` | iOS アプリ（SwiftUI） |
| `Packages/AoshingoKit/Sources/PICSKit` | 高度化PICS の解析、交差点ごとの状態、安全側デバウンス、読み上げる変化の判定、信号ごとの設定（名前・知らせ方・音・振動）、デモ、記録形式 |
| `Packages/AoshingoKit/Sources/FieldDataKit` | 実測データの間引き・丸め、送信キュー、App Attest を使う送信クライアント |
| `server/` | 実測データを受け取る Cloudflare Worker（`main` へのマージで Cloudflare が自動デプロイ）。[`server/README.md`](../server/README.md) |
| `site/` | 公式サイト（GitHub Pages）。[ウェブサイト](website.md) |
| `Tools/AppIcon/` | ロゴ（原本は `App/Views/Brand/AoshingoLogo.swift`）から App アイコンと `docs/assets/brand/` のロゴ素材を書き出すツール（Mac）。[`Tools/AppIcon/README.md`](../Tools/AppIcon/README.md) |
| `Tools/release/` | TestFlight 版と App Store 版をアーカイブしてアップロードし、署名付きタグを付けるスクリプト（Mac）。[リリースとバージョン番号](release.md) |
| `Tools/timing/` | 実測データから信号の周期と位相を求め、推定が成り立つ交差点かを確かめるスクリプト（Python）。[`Tools/timing/README.md`](../Tools/timing/README.md)、取り決めは [信号の周期の推定](timing-estimation.md) |
| `docs/` | 使い方、プライバシーポリシー、送信 API、現地確認の手順、リリースの手順など |

## 記録ファイルの共有

現地で受信した記録ファイル（設定 → 受信データの記録）は、解析やテストにとても役立ちます。記録にあなたの現在地（緯度・経度）は含まれませんが、交差点 ID と交差点の位置、受信した時刻は含まれるため、いつどの交差点にいたかは分かります。共有する前に、このことを踏まえて判断してください。手順は [現地確認の手順](field-test.md) をご覧ください。

## README の画像

- `docs/assets/readme/banner.png` は `docs/assets/readme/banner.html` を 1000×400 で表示し、デバイスピクセル比 2 で撮影したものです。配色は公式サイトと同じで、左上のアイコンは `docs/assets/brand/aoshingo-icon.svg` です。文字を変えるときは HTML を直して撮り直し、256 色に減色してください（フォントは Noto Sans JP）。
- `docs/assets/readme/screen-*.png` は iOS シミュレーターのデモ表示を撮影し、幅 600 px に縮小したものです。
