#!/usr/bin/env bash
# Controls for the stale-kernel guard (GitHub issue #526's sibling problem:
# a lane that is green about a binary nobody asked for).
#
# The guard exists because a person debugging a lane runs its script directly
# and bypasses make's dependency graph. So the control runs the guard
# directly too, against a fabricated tree, rather than through a lane.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/kernel_elf_freshness.sh
. "$repo_root/scripts/kernel_elf_freshness.sh"

cases=0
claim() { cases=$((cases + 1)); }
fail() { echo "FAIL kernel-elf-freshness control: $*" >&2; exit 1; }

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

# A kernel newer than every source is accepted. `find -newer` compares against
# the real tree, so the fixture only has to be newer than all of it.
fresh="$tmp_dir/fresh.elf"
: >"$fresh"
kernel_elf_refuse_stale "$fresh" "fresh kernel" 2>/dev/null \
    && claim || fail "a kernel newer than every source was refused"

# A kernel older than the sources is refused, and the message names the target
# that builds it -- the whole point, since `make kernelbuild` does not.
stale="$tmp_dir/stale.elf"
: >"$stale"
touch -d '2000-01-01' "$stale"
message="$(kernel_elf_refuse_stale "$stale" "stale kernel" 2>&1 || true)"
kernel_elf_refuse_stale "$stale" "stale kernel" 2>/dev/null \
    && fail "a kernel older than the sources was accepted" || claim
grep -q "kernelbuild-check" <<<"$message" \
    && claim || fail "the refusal did not name the target that builds it: $message"
grep -q "stale kernel" <<<"$message" \
    && claim || fail "the refusal did not name the kernel: $message"

# A kernel that does not exist at all is refused rather than treated as fresh:
# `find -newer` against a missing file matches nothing, which would otherwise
# read exactly like an up-to-date build.
kernel_elf_refuse_stale "$tmp_dir/absent.elf" "absent kernel" 2>/dev/null \
    && fail "a kernel that does not exist was accepted" || claim

echo "PASS kernel-elf-freshness controls: $cases claims -- a fresh kernel is accepted, a stale one is refused with the target that builds it named, and a missing one is refused rather than read as up to date"
