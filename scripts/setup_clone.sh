#!/usr/bin/env bash
# Per-clone Git settings this repository relies on. Git does not carry them in
# a clone, so the Makefile runs this on every `make` invocation outside CI
# rather than trusting anyone to remember. Idempotent; writes only the clone's
# own .git/config, never global settings.
#
# Settings:
#   core.hooksPath=.githooks   the commit-msg hook enforcing Found-by/Protocol
set -euo pipefail

cd "$(dirname "$0")/.."
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0

set_local() {
  if [ "$(git config --local --get "$1" || true)" != "$2" ]; then
    git config --local "$1" "$2"
    printf 'setup: set %s=%s in this clone\n' "$1" "$2" >&2
  fi
}

set_local core.hooksPath .githooks
