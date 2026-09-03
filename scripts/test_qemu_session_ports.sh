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

# Read the geometry from the file that owns it, so this test does not become a
# second place the numbers are written down.
# shellcheck source=scripts/qemu_session_ports.sh
. "$helper"
stride="$QEMU_SESSION_PORT_STRIDE"
blocks="$QEMU_SESSION_PORT_BLOCKS"

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
[ "$(offset_for "$registry" takibi-codex)" = "$stride" ] || fail "second block is not 1"
[ "$(offset_for "$registry" takibi-codex-3)" = "$((stride * 2))" ] \
    || fail "a name outside any fixed list must still get a block"
[ "$(offset_for "$registry" takibi-claude)" = 0 ] \
    || fail "a session's block is not stable across calls"
[ "$(offset_for "$registry" takibi-claude 7000)" = 7000 ] \
    || fail "an explicit offset must win over the registry"

# Concurrent claims are serialised: every session gets a block of its own.
concurrent="$tmp_dir/concurrent"
mkdir -p "$concurrent"
for index in $(seq 1 "$blocks"); do
    offset_for "$concurrent" "session-$index" >/dev/null &
done
wait
lines="$(wc -l <"$concurrent/blocks")"
distinct_blocks="$(cut -d' ' -f1 "$concurrent/blocks" | sort -u | wc -l)"
distinct_names="$(cut -d' ' -f2 "$concurrent/blocks" | sort -u | wc -l)"
[ "$lines" = "$blocks" ] && [ "$distinct_blocks" = "$blocks" ] \
    && [ "$distinct_names" = "$blocks" ] \
    || fail "$blocks concurrent claims produced $lines lines, $distinct_blocks blocks"

# A holder killed without unlocking leaves nothing behind: flock is released by
# the kernel when the descriptor closes, however the holder died.
killed="$tmp_dir/killed"
mkdir -p "$killed"
bash -c "exec 8>'$killed/lock'; flock 8; exec sleep 60" &
holder=$!
sleep 0.3
kill -KILL "$holder" 2>/dev/null || true
wait "$holder" 2>/dev/null || true
timeout 5 env TAKIBI_SESSION_REGISTRY="$killed" TAKIBI_SESSION=after-kill \
    bash -c ". '$helper'; qemu_session_port_offset" >/dev/null \
    || fail "a killed holder left the registry lock stuck"

# Exhaustion and corruption are refused by name rather than silently reused.
full="$tmp_dir/full"
mkdir -p "$full"
for index in $(seq 1 "$blocks"); do offset_for "$full" "full-$index" >/dev/null; done
if offset_for "$full" overflow >"$tmp_dir/overflow.log" 2>&1; then
    fail "a session past the block count was given a block"
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
[ "$shifted" = "$((18673 + stride)) $((18080 + stride)) 18671" ] \
    || fail "shifting named ports produced '$shifted'"

# A repeated lane's samples must stay inside the session's own block: the lane
# runner adds the session offset afterwards, so a base past the window lands in
# another clone's block rather than merely colliding with this one's lanes.
repeat="$repo_root/scripts/repeat_kernel_lane.sh"
if bash "$repeat" --port-base "$QEMU_SESSION_REPEAT_BASE" \
        "$((QEMU_SESSION_REPEAT_MAX_SAMPLES + 1))" true \
        >"$tmp_dir/repeat-count.log" 2>&1; then
    fail "a sample count past the repeat window was accepted"
fi
grep -F "outside this session's repeat window" "$tmp_dir/repeat-count.log" \
    >/dev/null || fail "an oversized repeat run did not name the window"
if bash "$repeat" --port-base "$((QEMU_SESSION_REPEAT_BASE - 1))" 1 true \
        >"$tmp_dir/repeat-base.log" 2>&1; then
    fail "a base below the repeat window was accepted"
fi
bash "$repeat" --mode check "$QEMU_SESSION_REPEAT_MAX_SAMPLES" true \
    >/dev/null 2>&1 || fail "the largest fitting repeat run was refused"

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
LOW = 17773
failures = []


def with_constants(**overrides):
    merged = dict(constants)
    merged.update(overrides)
    module.session_port_constants = lambda: merged


def geometry(ports):
    """Run the check with its diagnostics captured rather than printed."""
    captured = io.StringIO()
    with contextlib.redirect_stdout(captured):
        ok = module.check_block_geometry(ports)
    return ok, captured.getvalue()


def accepts(what, ports):
    ok, output = geometry(ports)
    if not ok:
        failures.append(f"{what} was rejected: {output.strip()}")


def rejects(what, ports, because):
    ok, output = geometry(ports)
    if ok:
        failures.append(f"{what} was accepted")
    elif because not in output:
        failures.append(f"{what} was rejected for the wrong reason: {output.strip()}")


# Every rule is checked by the message it produces, because one bad geometry can
# break several of them at once and a bare rejection would pass for the wrong
# reason.
with_constants()
accepts("the real lane geometry", [LOW, 18706])
rejects(
    "a lane span wider than one block",
    [LOW, LOW + stride],
    "so two sessions would overlap",
)
rejects(
    "a top block at the ephemeral floor",
    [LOW, floor - stride * (blocks - 1)],
    "ephemeral floor",
)
with_constants(QEMU_SESSION_REPEAT_BASE=18706)
rejects(
    "a repeat window overlapping a lane port",
    [LOW, 18706],
    "at or below the highest lane port",
)
with_constants(QEMU_SESSION_REPEAT_MAX_SAMPLES=stride)
rejects(
    "a repeat window reaching past the block",
    [LOW, 18706],
    "past this block's last port",
)

for failure in failures:
    print(f"FAIL qemu-session-ports: {failure}")
sys.exit(1 if failures else 0)
PY

echo "PASS qemu-session-ports: blocks are stable, exclusive, bounded, and survive a killed holder"
