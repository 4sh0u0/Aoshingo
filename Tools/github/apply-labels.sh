#!/usr/bin/env bash
# Creates, updates or renames the repository labels described in .github/labels.json.
# A label is matched by its "name". When no label has that name but one has a name listed in
# "aliases", that label is renamed, so the issues and pull requests that carry it keep it.
# Labels on GitHub that are in neither list are left alone and listed at the end.
#
# Usage: Tools/github/apply-labels.sh [--dry-run]
#   --dry-run  show what would change without changing anything
#
# Needs gh (signed in with write access to the repository) and jq. AOSHINGO_REPO overrides the
# repository.
set -euo pipefail

repo="${AOSHINGO_REPO:-4sh0u0/Aoshingo}"
dry_run=false
if [[ "${1:-}" == "--dry-run" ]]; then
  dry_run=true
  shift
fi

root="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
file="$root/.github/labels.json"

# name<TAB>color<TAB>description, one label per line.
existing="$(gh api "repos/$repo/labels" --paginate \
  --jq '.[] | [.name, (.color | ascii_downcase), (.description // "")] | @tsv')"

lookup() { # prints "color<TAB>description" of the label named $1, or nothing
  awk -F'\t' -v n="$1" '$1 == n { print $2 "\t" $3; exit }' <<<"$existing"
}
uri() { jq -rn --arg s "$1" '$s | @uri'; }

known=()
count="$(jq length "$file")"
for ((i = 0; i < count; i++)); do
  name="$(jq -r ".[$i].name" "$file")"
  color="$(jq -r ".[$i].color | ascii_downcase" "$file")"
  description="$(jq -r ".[$i].description // \"\"" "$file")"
  known+=("$name")

  current="$(lookup "$name")"
  from=""
  while IFS= read -r alias; do
    [[ -z "$alias" ]] && continue
    known+=("$alias")
    if [[ -z "$current" && -z "$from" && -n "$(lookup "$alias")" ]]; then
      from="$alias"
    fi
  done < <(jq -r ".[$i].aliases // [] | .[]" "$file")

  if [[ -n "$from" ]]; then
    echo "rename: $from -> $name"
    if ! $dry_run; then
      gh api -X PATCH "repos/$repo/labels/$(uri "$from")" \
        -f new_name="$name" -f color="$color" -f description="$description" --silent
    fi
  elif [[ -z "$current" ]]; then
    echo "create: $name"
    if ! $dry_run; then
      gh api -X POST "repos/$repo/labels" \
        -f name="$name" -f color="$color" -f description="$description" --silent
    fi
  elif [[ "$current" != "$color"$'\t'"$description" ]]; then
    echo "update: $name"
    echo "  GitHub: $current" | tr '\t' ' '
    echo "  file:   $color $description"
    if ! $dry_run; then
      gh api -X PATCH "repos/$repo/labels/$(uri "$name")" \
        -f color="$color" -f description="$description" --silent
    fi
  else
    echo "unchanged: $name"
  fi
done

# Labels on GitHub without an entry (or alias) in .github/labels.json.
while IFS=$'\t' read -r name _; do
  [[ -z "$name" ]] && continue
  found=false
  for k in "${known[@]}"; do
    if [[ "$k" == "$name" ]]; then
      found=true
      break
    fi
  done
  if ! $found; then
    echo "not in .github/labels.json: $name - left as it is"
  fi
done <<<"$existing"
