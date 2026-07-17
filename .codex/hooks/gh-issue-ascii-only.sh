#!/usr/bin/env bash
# Codex PreToolUse hook (Bash matcher): flags `gh issue comment` /
# `gh issue create` invocations whose command string contains non-ASCII text.
#
# Codex hook support currently documents `systemMessage` for PreToolUse, not a
# Claude-style structured deny decision. This hook exits non-zero on violation
# so current clients can stop or surface the failed hook, while AGENTS.md carries
# the same rule for all GitHub access paths.
set -euo pipefail

input="$(cat)"
cmd="$(printf '%s' "$input" | jq -r '
  .tool_input.command //
  .tool_input.cmd //
  .tool_input.args.command //
  .tool_input.arguments.command //
  .input.command //
  .command //
  empty
')"

repo_root="$(git rev-parse --show-toplevel)"

set +e
reason="$(bash "$repo_root/scripts/hooks/gh-issue-ascii-policy.sh" "$cmd")"
status=$?
set -e

if [ "$status" -eq 10 ]; then
  jq -n --arg reason "$reason" '{
    systemMessage: $reason
  }'
  exit 1
fi

exit 0
