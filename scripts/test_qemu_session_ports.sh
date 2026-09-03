#!/usr/bin/env bash
# Regression controls for the per-session QEMU port block claim.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
helper="$repo_root/scripts/qemu_session_ports.sh"
tmp_dir="$(mktemp -d)"
trap 'rm -r "$tmp_dir"' EXIT

fail() {
    echo "FAIL qemu-session-ports: $1" >&2
    exit 1
}

# Ask the helper for one session's offset, with the registry under $1.
offset_for() {
    local registry="$1" session="${2-}" extra="${3-}"
    env TAKIBI_SESSION_REGISTRY="$registry" \
        ${session:+TAKIBI_SESSION="$session"} \
        ${extra:+TAKIBI_QEMU_PORT_OFFSET="$extra"} \
        bash -c ". '$helper'; qemu_session_port_offset"
}

# An unconfigured tree keeps the documented single-session ports.
registry="$tmp_dir/registry"
mkdir -p "$registry"
[ "$(offset_for "$registry")" = 0 ] \
    || fail "a session with no name must take no offset"
[ "$(offset_for "$tmp_dir/absent" claude)" = 0 ] \
    || fail "a missing registry directory must take no offset"

# Blocks are handed out in order, and a name keeps the block it was given.
[ "$(offset_for "$registry" takibi-claude)" = 0 ] || fail "first block is not 0"
[ "$(offset_for "$registry" takibi-codex)" = 1000 ] || fail "second block is not 1"
[ "$(offset_for "$registry" takibi-codex-3)" = 2000 ] \
    || fail "a name outside any fixed list must still get a block"
[ "$(offset_for "$registry" takibi-claude)" = 0 ] \
    || fail "a session's block is not stable across calls"
[ "$(offset_for "$registry" takibi-claude 7000)" = 7000 ] \
    || fail "an explicit offset must win over the registry"

# Concurrent claims are serialised: every session gets a block of its own.
concurrent="$tmp_dir/concurrent"
mkdir -p "$concurrent"
for index in $(seq 1 12); do
    offset_for "$concurrent" "session-$index" >/dev/null &
done
wait
lines="$(wc -l <"$concurrent/blocks")"
distinct_blocks="$(cut -d' ' -f1 "$concurrent/blocks" | sort -u | wc -l)"
distinct_names="$(cut -d' ' -f2 "$concurrent/blocks" | sort -u | wc -l)"
[ "$lines" = 12 ] && [ "$distinct_blocks" = 12 ] && [ "$distinct_names" = 12 ] \
    || fail "12 concurrent claims produced $lines lines, $distinct_blocks blocks"

# A holder killed without unlocking leaves nothing behind: flock is released by
# the kernel when the descriptor closes, however the holder died.
bash -c "exec 8>'$concurrent/lock'; flock 8; exec sleep 60" &
holder=$!
sleep 0.3
kill -KILL "$holder" 2>/dev/null || true
wait "$holder" 2>/dev/null || true
timeout 5 env TAKIBI_SESSION_REGISTRY="$concurrent" TAKIBI_SESSION=after-kill \
    bash -c ". '$helper'; qemu_session_port_offset" >/dev/null \
    || fail "a killed holder left the registry lock stuck"

# Exhaustion and corruption are refused by name rather than silently reused.
full="$tmp_dir/full"
mkdir -p "$full"
for index in $(seq 1 14); do offset_for "$full" "full-$index" >/dev/null; done
if offset_for "$full" overflow >"$tmp_dir/overflow.log" 2>&1; then
    fail "a fifteenth session was given a block"
fi
grep -F "port blocks are claimed" "$tmp_dir/overflow.log" >/dev/null \
    || fail "exhaustion did not say the registry is full"

broken="$tmp_dir/broken"
mkdir -p "$broken"
printf 'not-a-block-line\n' >"$broken/blocks"
if offset_for "$broken" any >"$tmp_dir/broken.log" 2>&1; then
    fail "a malformed registry line was accepted"
fi
grep -F "$broken/blocks" "$tmp_dir/broken.log" >/dev/null \
    || fail "the malformed-registry message does not name the file"

# The shift applies to every named port and to nothing else.
shifted="$(env TAKIBI_SESSION_REGISTRY="$registry" TAKIBI_SESSION=takibi-codex \
    bash -c ". '$helper'
             SERIAL_PORT=18673
             HTTP_PORT=18080
             UNTOUCHED=18671
             qemu_session_shift_ports SERIAL_PORT HTTP_PORT
             echo \"\$SERIAL_PORT \$HTTP_PORT \$UNTOUCHED\"")"
[ "$shifted" = "19673 19080 18671" ] \
    || fail "shifting named ports produced '$shifted'"

# The block geometry check rejects lanes that would overlap or run past the
# ephemeral floor, rather than only reporting today's healthy numbers.
python3 - "$repo_root" <<'PY' || exit 1
import contextlib
import importlib.util
import io
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
spec = importlib.util.spec_from_file_location(
    "check_qemu_lane_ports", root / "scripts" / "check_qemu_lane_ports.py"
)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

constants = module.session_port_constants()
stride = constants["QEMU_SESSION_PORT_STRIDE"]
blocks = constants["QEMU_SESSION_PORT_BLOCKS"]
floor = constants["QEMU_SESSION_EPHEMERAL_FLOOR"]

def geometry(ports):
    """Run the check with its expected diagnostics captured, not printed."""
    with contextlib.redirect_stdout(io.StringIO()):
        return module.check_block_geometry(ports)


if not geometry([17773, 17773 + stride - 1]):
    print("FAIL qemu-session-ports: a span of exactly one block was rejected")
    sys.exit(1)
if geometry([17773, 17773 + stride]):
    print("FAIL qemu-session-ports: a span wider than one block was accepted")
    sys.exit(1)
if geometry([17773, floor - stride * (blocks - 1)]):
    print("FAIL qemu-session-ports: a top block at the ephemeral floor was accepted")
    sys.exit(1)
PY

echo "PASS qemu-session-ports: blocks are stable, exclusive, bounded, and survive a killed holder"
