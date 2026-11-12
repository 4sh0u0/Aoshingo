#!/usr/bin/env bash
# Creates or updates the repository rulesets described in .github/rulesets/*.json.
# A ruleset on GitHub is matched to a file by its "name"; one that exists is replaced with the
# file's contents (PUT), one that does not is created (POST). Rulesets on GitHub that have no
# file are left alone and listed at the end.
#
# Usage: Tools/github/apply-rulesets.sh [--dry-run] [FILE ...]
#   --dry-run  show what would change (a diff against GitHub) without changing anything
#   FILE       ruleset files to apply; default: every .github/rulesets/*.json
#
# Needs gh (signed in as a repository admin) and jq. AOSHINGO_REPO overrides the repository.
set -euo pipefail

repo="${AOSHINGO_REPO:-4sh0u0/Aoshingo}"
dry_run=false
if [[ "${1:-}" == "--dry-run" ]]; then
  dry_run=true
  shift
fi

root="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
if [[ $# -gt 0 ]]; then
  files=("$@")
else
  files=("$root"/.github/rulesets/*.json)
fi

# The fields a ruleset file sets; everything else in the API response is ignored when comparing.
normalize='{name, target, enforcement, conditions, bypass_actors: (.bypass_actors // []), rules}'

existing="$(gh api "repos/$repo/rulesets" --paginate --jq '.[] | "\(.id)\t\(.name)"')"
names=()

for file in "${files[@]}"; do
  name="$(jq -er .name "$file")"
  names+=("$name")
  id="$(awk -F'\t' -v n="$name" '$2 == n { print $1; exit }' <<<"$existing")"

  if [[ -z "$id" ]]; then
    echo "create: $name ($file)"
    if ! $dry_run; then
      gh api -X POST "repos/$repo/rulesets" --input "$file" --jq '"  created id \(.id)"'
    fi
    continue
  fi

  current="$(gh api "repos/$repo/rulesets/$id" | jq -S "$normalize")"
  desired="$(jq -S "$normalize" "$file")"
  if [[ "$current" == "$desired" ]]; then
    echo "unchanged: $name (id $id)"
    continue
  fi

  echo "update: $name (id $id)"
  diff -u <(echo "$current") <(echo "$desired") --label "GitHub" --label "$file" || true
  if ! $dry_run; then
    gh api -X PUT "repos/$repo/rulesets/$id" --input "$file" --jq '"  updated id \(.id)"'
  fi
done

# Rulesets on GitHub without a file in .github/rulesets/.
while IFS=$'\t' read -r id name; do
  [[ -z "$id" ]] && continue
  if [[ ! " ${names[*]} " == *" $name "* ]]; then
    echo "not in .github/rulesets: $name (id $id) - left as it is"
  fi
done <<<"$existing"
