# ロゴと App アイコンの書き出し

Aoshingo のロゴの原本は SwiftUI のコード [`App/Views/Brand/AoshingoLogo.swift`](../../App/Views/Brand/AoshingoLogo.swift) です。形も色もこのファイルの数値だけで決まっていて、App の画面に出すロゴもこのコードで描きます。

このディレクトリのツールは、同じ数値から次のファイルを書き出します。どれも生成物なので、手で編集しないでください。

| ファイル | 使い道 |
|---|---|
| `App/Resources/AppIcon.icon/`（`icon.json` と `Assets/*.svg`） | App アイコン（Icon Composer の書類）。iOS 26 以降は Liquid Glass で表示（デフォルト・ダーク・色付き・クリア） |
| `docs/assets/brand/aoshingo-icon.svg` | 角丸の紺タイル付きロゴ（README・サイト用） |
| `docs/assets/brand/aoshingo-mark-dark.svg` / `aoshingo-mark-light.svg` | 背景なしのロゴ。暗い背景用 / 明るい背景用 |
| `docs/assets/brand/aoshingo-icon-1024.png` | 角なしの 1024 × 1024 PNG。サイトのアイコンと OGP 画像の元 |

`AppIcon.appiconset` は置きません。iOS 18〜25 用のアイコンは、Xcode がビルド時に `AppIcon.icon` から平らな画像（ダーク・色付きの版も）を作ります。同じ名前の `AppIcon.appiconset` があっても使われません。

## 書き出す（Mac）

```sh
Tools/AppIcon/export.sh
```

Xcode のコマンドラインツールでツールをビルドして、リポジトリの中のファイルを上書きします。PNG は書き出しのときに背景・点灯段・消灯段・人の色を 1 点ずつ確かめ、ずれていれば失敗します。

`icon.json` に `color-space-for-untagged-svg-colors` は書きません。省くと Icon Composer は SVG の色を sRGB として読みます（設計どおり）。このキーは `display-p3` しか受け付けず、`srgb` と書くと Icon Composer が書類を開けません。

## ロゴを変えるとき

1. `AoshingoLogo.swift` の数値や色を変えて、Xcode のプレビュー「Logo」で確かめる。
2. `Tools/AppIcon/export.sh` を実行する。
3. Icon Composer で `App/Resources/AppIcon.icon` を開き、各外観を確かめる。ガラスや影の設定は [`ExportAppIcon.swift`](ExportAppIcon.swift) の `iconJSON()` が正本です。Icon Composer で変えたときは `iconJSON()` にも反映してください（次の書き出しで `icon.json` は上書きされます）。
   コマンドラインで確かめるときは Icon Composer に付いている `ictool` を使います。

   ```sh
   ictool="$(dirname "$(xcode-select -p)")/Applications/Icon Composer.app/Contents/Executables/ictool"
   for rendition in Default Dark TintedLight TintedDark ClearLight ClearDark; do
     "$ictool" App/Resources/AppIcon.icon --export-image --output-file "/tmp/AppIcon-$rendition.png" \
       --platform iOS --rendition "$rendition" --width 1024 --height 1024 --scale 1
   done
   ```

4. サイトの画像を作り直す（[`site/scripts/make-images.py`](../../site/scripts/make-images.py)）。

   ```sh
   python3 site/scripts/make-images.py docs/assets/brand/aoshingo-icon-1024.png site/public/assets
   ```

## デザイン

- 8 段のリングは App の「残り 8 段階」の目安で、12 時の位置から時計回りに 5 段が点灯しています。中に歩く人。
- 色だけに頼らない：点灯段と消灯段は明るさで見分けられ（3.2:1）、人は背景から 10:1 以上離れています。赤と緑の区別は使いません。
- Icon Composer のグループは前から「人」「点灯段」「消灯段」。背景のグラデーションは `icon.json` の塗りで、ダーク外観ではもう一段暗い紺になります。

| 用途 | 色 |
|---|---|
| 背景（上→下） | `#0B1F45` → `#13406B`（ダーク外観：`#050E22` → `#0B1F45`） |
| 点灯段 | 暗い背景 `#5FD4BD`、明るい背景 `#00806B`（App の標準の青） |
| 消灯段 | 暗い背景 `#41679A`、明るい背景 `#B4C1D1` |
| 人 | 暗い背景 `#FFFFFF`、明るい背景 `#0B1F45` |
