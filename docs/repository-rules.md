# リポジトリのルール

`main` ブランチとリリースのタグを、GitHub の Rulesets（ルールセット）で守っています。定義は [`.github/rulesets/`](../.github/rulesets/) の JSON で、[`Tools/github/apply-rulesets.sh`](../Tools/github/apply-rulesets.sh) で GitHub に反映します。

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
