#!/usr/bin/env bash
# Claude Code PreToolUse hook (Bash matcher): blocks `gh issue comment` /
# `gh issue create` invocations whose command string contains non-ASCII text.
set -euo pipefail

input="$(cat)"
cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // empty')"
repo_root="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel)}"

set +e
reason="$(bash "$repo_root/scripts/hooks/gh-issue-ascii-policy.sh" "$cmd")"
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
