# リリースとバージョン番号

Aoshingo は、App Store 版と TestFlight 版の 2 つを配信します。TestFlight 版は、実測データの提供に協力している人向けの機能（「推定」の画面など）を含む**拡張収集版**です。ここでは、2 つの区別、バージョン番号とタグの決まり、アップロードの手順をまとめます。

## バージョン番号とビルド番号

| | 設定 | 決まり |
| --- | --- | --- |
| バージョン | `MARKETING_VERSION`（`CFBundleShortVersionString`）、`Config/Base.xcconfig` | `X.Y.Z` の数字 3 つ。App Store での公開は 1.0.0 から。大きな作り直しで X、機能の追加で Y、不具合の修正だけなら Z を上げます。公開前の試験版は 0.Y.Z です。 |
| ビルド番号 | `CURRENT_PROJECT_VERSION`（`CFBundleVersion`） | TestFlight 版と App Store 版を通して 1 つの整数。アップロードのたびに 1 ずつ増やし、戻しません。[`Tools/release/release.sh`](../Tools/release/release.sh) がタグから決めるので、リポジトリの値は 0 のままです。 |

Apple の決まりにより、次のようになっています。

- バージョンは数字 3 つだけです。`1.1.0-tf` のような接尾辞は App Store Connect が受け付けないので、TestFlight 版の区別はビルド番号、タグ、アプリ内の表示で行います。
- TestFlight と App Store は、同じアプリの記録とバージョンの系列を共有します。
- 審査を通ったバージョンには、それ以上ビルドを追加できません。

`main` の `MARKETING_VERSION` は「次に App Store に出すバージョン」です。TestFlight 版はこのバージョンで何度もアップロードし、App Store で公開したら、次のバージョンに上げる Pull Request を出します。次の Y と Z のどちらを上げるかは、その間にマージした Pull Request の種類のラベルで決めます。ラベルと、バージョンごとのマイルストーンの決まりは [リポジトリのルール](repository-rules.md#ラベルとマイルストーン) をご覧ください。

## 配信チャネル

どの配信向けかは、ビルドするときに `AOSHINGO_CHANNEL` で決まります（`App/AppChannel.swift`）。

| チャネル | 作り方 | 「推定」の画面 | 設定の「バージョン」 | 送信する `client` |
| --- | --- | --- | --- | --- |
| `appstore` | Release ビルドの既定。`release.sh appstore` | なし | `1.1.0 (60)` | `aoshingo-ios/1.1.0` |
| `testflight` | `release.sh testflight` | あり | `1.1.0-tf.57`、配信「TestFlight 版（拡張収集）」 | `aoshingo-ios/1.1.0-tf` |
| `development` | Debug ビルドの既定 | あり | `1.1.0-dev`、配信「開発用ビルド」 | `aoshingo-ios/1.1.0-dev` |

- App Store 版に入れない機能は `AppChannel.current` で分けます。StoreKit の `AppTransaction.environment` だけでは分けません。App Review は sandbox 環境で審査するので、審査では TestFlight と同じ値になるためです。
- TestFlight 版の「推定」は、さらに StoreKit が TestFlight（`sandbox`）か Xcode（`xcode`）と答えたときだけ出します。TestFlight 版のビルドを誤って App Store で公開しても、App Store 版と同じ動きになります。
- 送信する `client` にビルド番号は含めません。TestFlight のテスターは少なく、それぞれ違う時期に更新するので、ビルド番号があると同じ人の報告を結び付ける手がかりになるためです。
- Xcode から App Store 版の動きを確かめるときは、`Config/Local.xcconfig` に `AOSHINGO_CHANNEL = appstore` と書きます（リリースの前には消してください。スクリプトが止まります）。

## タグ

| 配信 | タグ | 例 |
| --- | --- | --- |
| TestFlight | `vX.Y.Z-tf.ビルド番号` | `v1.1.0-tf.57`（App Store Connect の「1.1.0 (57)」） |
| App Store | `vX.Y.Z` と GitHub Release | `v1.1.0` |

- すべて注釈付きの署名付きタグです。メッセージには `Build:` と `Channel:` の行を書きます。
- タグはアップロードに成功してから push します。一度 push したタグは消したり付け替えたりしません。
- 導入前にアップロードしたビルドには、次のタグを付けています（チャネルの区別はまだありません）。

  | タグ | コミット |
  | --- | --- |
  | `v0.1.0-tf.1` | `ddbee49` |
  | `v0.1.0-tf.2` | `25cf40d` |

## 手順

アップロードは Mac で行います。署名の設定と送信先（`DEVELOPMENT_TEAM`、`AOSHINGO_REPORT_HOST`）を `Config/Local.xcconfig` に書き、タグに署名する GPG 鍵を用意しておきます。

### TestFlight 版

1. `main` を最新にして、作業ツリーに変更がないことを確かめます。
2. `Tools/release/release.sh testflight --dry-run` で、バージョン、ビルド番号、タグを確かめます。
3. `Tools/release/release.sh testflight` を実行します。アーカイブ、Info.plist の確認、署名付きタグ、アップロード、タグの push まで行います。
4. App Store Connect で処理が終わったら、テストグループに追加して「テスト内容」を書きます。

- TestFlight のビルドは 90 日で使えなくなります。拡張収集を続けるときは、90 日以内に次のビルドを出します。
- 内部テストだけで配るときは `--internal-only` を付けます。そのビルドは App Store の審査にも外部テストにも出せなくなります。

### App Store 版

1. TestFlight 版で確かめたコミットで、`Tools/release/release.sh appstore` を実行します。タグは `vX.Y.Z` です。
2. TestFlight（内部テスト）からこのビルドを入れて、App Store 版として動くこと（「推定」の画面がない、設定に「配信」の行がない）を確かめます。
3. App Store Connect でバージョン X.Y.Z を作り、このビルドを選んで審査に出します。`-tf` のタグのビルドは選びません。
4. 公開したら、GitHub Release を作り（`gh release create vX.Y.Z --verify-tag --generate-notes`）、`main` の `MARKETING_VERSION` を次のバージョンに上げます。ノートは前の Release からマージした Pull Request を、ラベルで「新しい機能」「不具合の修正」「その他」に分けて書かれます（`channel: testflight` の PR は載りません）。マイルストーン X.Y.Z は閉じて、次のバージョンのマイルストーンを作ります。

### 修正だけを急いで出すとき

`main` が次の機能の TestFlight 版に進んでいても、公開中のバージョンから枝分かれして修正版を出せます。

1. `git switch -c release/1.0 v1.0.0` で枝を作り、修正と `MARKETING_VERSION = 1.0.1` をコミットして push します。
2. その枝で `Tools/release/release.sh appstore` を実行します（ビルド番号は `main` と共通で増えます）。
3. 同じ修正を `main` にも入れます。
