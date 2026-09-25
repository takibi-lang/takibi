#!/usr/bin/env bash
# Applies the `protocol` label to every issue closed by a commit whose message
# carries `Protocol: yes -- ...`. The trailer, enforced by
# scripts/hooks/found-by-policy.sh, is the source of truth; the label is its
# index on GitHub. Idempotent, so rerun it over any range.
#
# Usage: scripts/label_protocol_issues.sh [<revision-range>]   (default: HEAD~50..HEAD)
set -euo pipefail

range="${1:-HEAD~50..HEAD}"
issues="$(
  git log --format='%H' --grep='^Protocol:[[:space:]]*yes' -E "$range" |
    while read -r rev; do
      git log -1 --format='%B' "$rev" |
        grep -oiE '(fix|fixes|fixed|close|closes|closed|resolve|resolves|resolved)[[:space:]]+#[0-9]+' |
        grep -oE '[0-9]+$'
    done | sort -un
)"

for issue in $issues; do
  gh issue edit "$issue" --add-label protocol >/dev/null
  printf 'labeled #%s\n' "$issue"
done
