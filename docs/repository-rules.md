# リポジトリのルール

`main` ブランチとリリースのタグを、GitHub の Rulesets（ルールセット）で守っています。定義は [`.github/rulesets/`](../.github/rulesets/) の JSON で、[`Tools/github/apply-rulesets.sh`](../Tools/github/apply-rulesets.sh) で GitHub に反映します。Pull Request に付けるラベルとマイルストーンの決まりは、[後半](#ラベルとマイルストーン) にまとめています。

## ルールの一覧

| ルールセット | 対象 | 内容 | 迂回できる人 |
| --- | --- | --- | --- |
| `main` | `main` | 削除と強制プッシュを禁止。変更は PR からだけ（承認は 0 件でよい）。マージ方法は merge commit と squash。必須チェックは「CI gate」と「Website gate」 | 管理者が PR をマージするときだけ |
| `signed-commits` | すべてのブランチ | 検証済みの署名がないコミットのプッシュを拒否 | なし |
| `release-tags` | `v*` タグ | タグの移動と削除を禁止 | なし |

## 考え方

### main

- 開発者は一人で、PR は Claude が作り、マージは Haru が行います。自分の PR は自分で承認できないので、承認の数は 0 にしています。
- 管理者の迂回は「PR のときだけ」（bypass mode `pull_request`）です。CI が GitHub 側の不具合で止まったときなどは、PR 画面の「Merge without waiting for requirements to be met (bypass rules)」でマージできます。`main` への直接プッシュ、強制プッシュ、削除は管理者でもできません。
- rebase merge は使えません。rebase ではコミットが作り直され、Mac mini で付けた署名が残らないためです（これまでのマージも merge commit と squash だけです）。
- 「マージ前にブランチを最新にする」は求めていません。GitHub の「Update branch」で作られたコミットが Mac mini のブランチとずれて、続きのプッシュが失敗しやすいためです。

### 必須チェック

- パスのフィルタで飛ばされたワークフローは結果を報告しないので、必須にするとマージが「Waiting for status to be reported」のまま止まります。
- そこで `ci.yml` と `pages.yml` は PR では毎回動き、最初の `changes` ジョブが変わったファイルを見て、関係のないジョブを飛ばします（`if:` で飛ばされたジョブは成功として扱われます）。最後の「CI gate」「Website gate」がすべての結果をまとめ、失敗か中止があれば失敗します。
- 必須チェックは GitHub Actions（`integration_id` 15368）が報告したものだけを受け付けます。
- ゲートのジョブ名を変えるときは、`main.json` も同じ PR で直します。その PR 自体は古い名前のチェックを報告しないので、管理者の迂回でマージし、すぐに適用してください。

### 署名

- GitHub が確かめられるのは「検証済みの署名があるか」までで、OpenPGP か SSH か、どの鍵かまでは指定できません。GitHub が署名するコミット（画面からのマージと squash、Update branch、Dependabot、API 経由のコミット）も通ります。YubiKey の鍵で署名するという取り決めは、これまでどおり手元のフックで確かめます。
- `@claude` で動く Claude Code のワークフローは、`use_commit_signing: true` で GitHub API からコミットするので、GitHub の署名が付きます。

### リリースのタグ

- `v*` のタグは、一度プッシュしたら動かすことも消すこともできません。TestFlight にアップロードしたビルドとタグを一対一に保つためです。
- GitHub はタグそのものの署名を必須にできません。タグは `git tag -s` で署名して作り、`git tag -v` で確かめてからプッシュします。
- タグを作ることは誰にでも（書き込み権限のある人なら）できます。

### デプロイ

GitHub Pages（Actions の `deploy-pages`）と Cloudflare Workers Builds（`main` へのプッシュを読んでデプロイ）は、どちらもリポジトリにプッシュしないので、ルールの影響を受けません。

## 反映のしかた

`gh` に管理者（4sh0u0）でログインした Mac で実行します。`jq` も使います。

```bash
Tools/github/apply-rulesets.sh --dry-run   # GitHub との差分を見るだけ
Tools/github/apply-rulesets.sh             # 作成または更新
gh api repos/4sh0u0/Aoshingo/rules/branches/main   # main に効いているルールを確かめる
```

JSON を変えるときは、先に PR で `main` に入れてから反映します。名前（`name`）で GitHub 上のルールセットと対応づけるので、名前は変えないでください。

## 緊急のとき：タグを直す

`release-tags` は誰も迂回できません。どうしても直すときは、いったん止めてから直し、最後に元へ戻します。

```bash
id=$(gh api repos/4sh0u0/Aoshingo/rulesets --jq '.[] | select(.name == "release-tags") | .id')
gh api -X PUT "repos/4sh0u0/Aoshingo/rulesets/$id" -f enforcement=disabled
# ここでタグを直す
Tools/github/apply-rulesets.sh .github/rulesets/release-tags.json   # 有効に戻す
```

TestFlight にアップロード済みのビルドのタグは直さず、次の build 番号で新しいタグを打ってください。

## ラベルとマイルストーン

Pull Request には、種類と領域のラベルと、その変更が出るバージョンのマイルストーンを付けます。ラベルの定義は [`.github/labels.json`](../.github/labels.json) で、[`Tools/github/apply-labels.sh`](../Tools/github/apply-labels.sh) で GitHub に反映します。

### ラベル

| 分け方 | ラベル | 付け方 |
| --- | --- | --- |
| 種類 | `type: feature`、`type: fix`、`type: docs`、`type: chore` | 1 つだけ |
| 領域 | `area: app`、`area: server`、`area: website`、`area: ci` | 変えたところすべて。文書だけのときは付けない |
| 話題 | `privacy`、`accessibility`、`channel: testflight`、`dependencies` | 当てはまるときだけ |

- 種類は、バージョン番号の決まり（[リリースとバージョン番号](release.md)）に合わせています。前のリリースのあとアプリ（`area: app`）に入った PR に `type: feature` があれば Y を、`type: fix` だけなら Z を上げます。`type: docs` と `type: chore` だけなら、アプリを出し直す必要はありません。大きな作り直しで X を上げるかは、ラベルでは決めず、そのつど決めます。
- `privacy` は、集めるデータ、送る内容、プライバシーポリシー、プライバシーマニフェストのどれかが変わる PR に付けます。App Store Connect のプライバシーの回答を見直す目印です。
- `channel: testflight` は、TestFlight 版（拡張収集）でしか動かない機能の PR に付けます。App Store 版の GitHub Release のノートには載りません（[`.github/release.yml`](../.github/release.yml)）。
- Dependabot の PR には `type: chore`、`area: ci`、`dependencies` が自動で付きます（[`.github/dependabot.yml`](../.github/dependabot.yml)）。
- issue の整理に使う `duplicate`、`good first issue`、`help wanted`、`invalid`、`question`、`wontfix` は、GitHub の既定のままです。

### マイルストーン

- マイルストーンの名前は、アプリのバージョン（`0.2.0`、`1.0.0` など）です。PR には、マージしたときの `main` の `MARKETING_VERSION`、つまりその変更が最初に出るバージョンを付けます。`release/X.Y` の枝への PR には、その枝のバージョンを付けます。
- `MARKETING_VERSION` を上げる PR を出すときに、次のバージョンのマイルストーンを作ります。App Store で公開したら（0.y.z の間は、次のバージョンに上げたら）、そのマイルストーンを閉じます。

```bash
gh api repos/4sh0u0/Aoshingo/milestones -f title=1.1.0 -f description="…"   # 作る
gh api -X PATCH repos/4sh0u0/Aoshingo/milestones/<番号> -f state=closed       # 閉じる
```

- 導入した 2026-11-12 には、`v0.1.0-tf.2`（`25cf40d`）までにマージした #1–#12 を `0.1.0` に、それより後の PR を `0.2.0` にしました。

### ラベルの反映のしかた

```bash
Tools/github/apply-labels.sh --dry-run   # GitHub との差分を見るだけ
Tools/github/apply-labels.sh             # 作成、更新、名前の変更
```

- ルールセットと同じく、JSON を変えるときは先に PR で `main` に入れてから反映します。
- ラベルは `name` で対応づけます。名前を変えるときは、古い名前を `aliases` に残してから反映してください。GitHub のラベルの名前が変わるだけなので、付いている issue と PR からは外れません。
- ファイルにないラベルは消さずに、最後に一覧で知らせます。消すときは GitHub の画面で消してください。
