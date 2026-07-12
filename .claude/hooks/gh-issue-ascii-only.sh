#!/usr/bin/env bash
# PreToolUse hook (Bash matcher): blocks `gh issue comment` / `gh issue create`
# invocations whose command string contains non-ASCII characters, mirroring
# this repo's all-ASCII source policy (see `make langcheck` in the root
# Makefile / CLAUDE.md). Forces issue title/body text to be written in
# English before the command is allowed to run.
set -euo pipefail

input="$(cat)"
cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // empty')"

if printf '%s' "$cmd" | grep -Eq '(^|[;&|]|[[:space:]])gh[[:space:]]+issue[[:space:]]+(comment|create)([[:space:]]|$)'; then
  if printf '%s' "$cmd" | LC_ALL=C grep -qP '[^\x00-\x7F]'; then
    jq -n '{
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "deny",
        permissionDecisionReason: "Non-ASCII characters detected in a `gh issue comment`/`gh issue create` command. Rewrite the issue title/body in English (ASCII only) before running this command."
      }
    }'
    exit 0
  fi
fi

exit 0
