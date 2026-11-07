#!/usr/bin/env bash
# Controls for the one-lane-chain-per-worktree claim (GitHub issue #1433,
# scripts/qemu_lane_owner.sh). Real processes stand in for lane chains, and
# the owner record is a temporary file, so this touches no QEMU and no port.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
pids=()
cleanup() {
    for p in "${pids[@]}"; do kill "$p" 2>/dev/null || true; done
    rm -r "$tmp_dir"
}
trap cleanup EXIT

cases=0
claim() { cases=$((cases + 1)); }
fail() {
    echo "FAIL qemu-lane-owner: $1" >&2
    exit 1
}

# shellcheck source=scripts/qemu_lane_owner.sh
. "$repo_root/scripts/qemu_lane_owner.sh"
export TAKIBI_QEMU_LANE_OWNER_FILE="$tmp_dir/owner"

chain() { sleep 300 & pids+=("$!"); }

chain; a="${pids[-1]}"
chain; b="${pids[-1]}"

qemu_lane_owner_claim "$a" 2>/dev/null || fail "the first chain was refused"
claim
qemu_lane_owner_claim "$a" 2>/dev/null || fail "a second lane of the owning chain was refused"
claim
if qemu_lane_owner_claim "$b" 2>"$tmp_dir/err"; then
    fail "a second chain was admitted while the owner lives"
fi
grep -q "another QEMU lane chain owns this worktree: pid $a" "$tmp_dir/err" \
    || fail "the refusal does not name the owning chain: $(cat "$tmp_dir/err")"
claim

kill "$a"; wait "$a" 2>/dev/null || true
qemu_lane_owner_claim "$b" 2>/dev/null || fail "a dead owner still refused a new chain"
claim

# A record whose PID is live but whose start time differs is a reused PID.
chain; c="${pids[-1]}"
echo "$c 1" > "$TAKIBI_QEMU_LANE_OWNER_FILE"
qemu_lane_owner_claim "$b" 2>/dev/null || fail "a reused PID was taken for a live owner"
claim

# The gate is wired: qemu.sh claims before it starts QEMU, and the Makefile
# names one chain for all its sub-makes.
grep -q '^qemu_lane_owner_claim || exit 1$' "$repo_root/scripts/qemu.sh" \
    || fail "scripts/qemu.sh does not claim the worktree before starting QEMU"
claim
grep -q '^export TAKIBI_LANE_ROOT_PID$' "$repo_root/Makefile" \
    || fail "the Makefile does not export TAKIBI_LANE_ROOT_PID"
claim
root_a="$(make -s -C "$repo_root" -f "$repo_root/Makefile" --eval 'lane-root-probe: ; @echo $(TAKIBI_LANE_ROOT_PID)' lane-root-probe 2>/dev/null)"
root_b="$(TAKIBI_LANE_ROOT_PID=4242 make -s -C "$repo_root" -f "$repo_root/Makefile" --eval 'lane-root-probe: ; @echo $(TAKIBI_LANE_ROOT_PID)' lane-root-probe 2>/dev/null)"
[ -n "$root_a" ] && [ "$root_a" != "$$" ] || fail "the top-level make named no chain of its own: '$root_a'"
[ "$root_b" = 4242 ] || fail "a sub-make did not inherit its chain: '$root_b'"
claim

echo "PASS qemu-lane-owner: $cases claims -- one chain per worktree, its own parallel lanes admitted, another refused by name, dead and reused-PID owners released, and the gate wired into qemu.sh and the Makefile"
