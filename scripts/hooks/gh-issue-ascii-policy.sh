#!/usr/bin/env bash
# Shared policy check for generated GitHub issue text.
# Exit codes:
#   0: command is allowed or is outside this policy's scope
#   10: `gh issue create/comment` command contains non-ASCII text
set -euo pipefail

cmd="${1:-}"

if printf '%s' "$cmd" | grep -Eq '(^|[;&|]|[[:space:]])gh[[:space:]]+issue[[:space:]]+(comment|create)([[:space:]]|$)'; then
  if printf '%s' "$cmd" | LC_ALL=C grep -qP '[^\x00-\x7F]'; then
    printf '%s\n' 'Non-ASCII characters detected in a `gh issue comment`/`gh issue create` command. Rewrite the issue title/body in English (ASCII only) before running this command.'
    exit 10
  fi
fi

exit 0
