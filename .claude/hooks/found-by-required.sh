#!/usr/bin/env bash
# Claude Code PreToolUse hook (Bash matcher): blocks `gh issue create`
# invocations with no `Found-by:` field, and `git commit` invocations that
# close a GitHub issue without a `Found-by:` trailer.
set -euo pipefail

input="$(cat)"
cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // empty')"
repo_root="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel)}"

set +e
reason="$(bash "$repo_root/scripts/hooks/found-by-policy.sh" --command "$cmd")"
status=$?
set -e

if [ "$status" -eq 10 ]; then
  jq -n --arg reason "$reason" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $reason
    }
  }'
  exit 0
fi

exit 0
