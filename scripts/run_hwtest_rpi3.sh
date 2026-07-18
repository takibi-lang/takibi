#!/usr/bin/env bash
# Raspberry Pi 3B hardware integration test runner -- called from repo
# root via: make hwcheck-rpi3
#
# Unlike STM32's scripts/run_hwtest_ram.sh, this cannot reset the board
# between examples -- the 6-pin GPIO JTAG header has no wired system
# reset line (see examples/common_rpi3/AGENTS.md). What makes a
# multi-example run possible anyway: scripts/rpi3_jtag_load.sh's safety
# check gates on the halted core's MMU state, not a specific address, so
# catching a PREVIOUS example's own injected payload (still parked in
# its own halt loop, MMU off) is exactly as safe to overwrite as
# catching examples/common_rpi3/jtag_stub.S's spin loop -- only ONE
# power cycle is needed per Raspbian boot, not one per example. If the
# board is still running Raspbian (never power-cycled to the stub this
# session), the first example's injection fails fast with a clear
# error, rather than silently producing a confusing UART mismatch.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SERIAL_DEV="${RPI3_SERIAL_DEV:-$("$REPO_ROOT/scripts/rpi_uart_dev.sh")}"
BAUD=115200

# Same idle-detection polling constants and reasoning as
# scripts/run_hwtest_ram.sh (see that file's header comment) -- reused
# verbatim rather than re-derived, since the serial-side timing behavior
# these tune for has nothing to do with how the firmware got onto the chip.
POLL_INTERVAL=0.05
DRAIN_MAX_SECS=1.0
DRAIN_STABLE_POLLS=6
CAPTURE_MAX_SECS=3
CAPTURE_STABLE_POLLS=6

PASS=0
FAIL=0
FAILED_TESTS=()

if [ -t 1 ]; then
    GRN='\033[32m' RED='\033[31m' RST='\033[0m'
else
    GRN='' RED='' RST=''
fi

if [ -z "$SERIAL_DEV" ] || [ ! -e "$SERIAL_DEV" ]; then
    echo "error: could not resolve the Raspberry Pi UART device (scripts/rpi_uart_dev.sh" >&2
    echo "found: '$SERIAL_DEV') -- is the UART cable connected?" >&2
    exit 1
fi
stty -F "$SERIAL_DEV" "$BAUD" raw -echo

ACTIVE_READER_PID=""
cleanup_reader() {
    if [ -n "$ACTIVE_READER_PID" ]; then
        kill "$ACTIVE_READER_PID" 2>/dev/null || true
        wait "$ACTIVE_READER_PID" 2>/dev/null || true
        ACTIVE_READER_PID=""
    fi
}
trap cleanup_reader EXIT
trap 'cleanup_reader; exit 130' INT TERM HUP

# read_until_quiet: same idle-detection technique as
# scripts/run_hwtest_ram.sh (see that file for the full comment) --
# copied rather than shared, matching this test suite's existing
# convention of each runner being a single self-contained script.
read_until_quiet() {
    local outfile="$1" max_secs="$2" stable_polls_needed="$3" wait_for_data="$4" post_start_cmd="${5:-}"
    : > "$outfile"
    cat "$SERIAL_DEV" > "$outfile" 2>/dev/null 9>&- &
    local catpid=$!
    ACTIVE_READER_PID=$catpid
    if [ -n "$post_start_cmd" ]; then
        sleep 0.2
        eval "$post_start_cmd"
    fi
    local max_polls
    max_polls=$(awk -v m="$max_secs" -v i="$POLL_INTERVAL" 'BEGIN{printf "%d", m/i}')
    local last_size=-1 stable=0 poll=0 size seen_any=0
    while [ "$poll" -lt "$max_polls" ]; do
        sleep "$POLL_INTERVAL"
        size=$(stat -c%s "$outfile" 2>/dev/null || echo 0)
        [ "$size" -gt 0 ] && seen_any=1
        if { [ "$wait_for_data" -eq 0 ] || [ "$seen_any" -eq 1 ]; } && [ "$size" = "$last_size" ]; then
            stable=$((stable + 1))
            [ "$stable" -ge "$stable_polls_needed" ] && break
        else
            stable=0
        fi
        last_size="$size"
        poll=$((poll + 1))
    done
    kill "$catpid" 2>/dev/null || true
    wait "$catpid" 2>/dev/null || true
    ACTIVE_READER_PID=""
}

# run_hw_test_rpi3 NAME ELF EXPECTED
#
# Distinguishes two different failure modes rather than collapsing them
# into one UART mismatch: (1) rpi3_jtag_load.sh itself failing (almost
# always the MMU-state safety check refusing a still-Raspbian board --
# actionable: power-cycle and retry) vs (2) injection succeeding but the
# captured UART output not matching -- an actual test failure.
run_hw_test_rpi3() {
    local name="$1" elf="$2" expected="$3"
    local tmp_drain tmp_out load_log load_status_file load_status
    tmp_drain=$(mktemp)
    tmp_out=$(mktemp)
    load_log=$(mktemp)
    load_status_file=$(mktemp)

    read_until_quiet "$tmp_drain" "$DRAIN_MAX_SECS" "$DRAIN_STABLE_POLLS" 0
    read_until_quiet "$tmp_out" "$CAPTURE_MAX_SECS" "$CAPTURE_STABLE_POLLS" 1 \
        "\"$REPO_ROOT/scripts/rpi3_jtag_load.sh\" \"$elf\" > \"$load_log\" 2>&1; echo \$? > \"$load_status_file\""

    load_status=$(cat "$load_status_file" 2>/dev/null || echo 1)

    if [ "$load_status" != "0" ]; then
        printf "${RED}FAIL${RST}  %s  (JTAG injection failed -- see log below;" "$name"
        printf " likely needs a power cycle to examples/common_rpi3/jtag_stub.img)\n"
        sed 's/^/       /' "$load_log"
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$name")
    elif cmp -s "$expected" "$tmp_out"; then
        printf "${GRN}PASS${RST}  %s\n" "$name"
        PASS=$((PASS + 1))
    else
        printf "${RED}FAIL${RST}  %s  (unexpected UART output)\n" "$name"
        printf "       expected: %s\n" "$(od -An -c "$expected" | tr -s ' \n' ' ')"
        printf "       actual:   %s\n" "$(od -An -c "$tmp_out" | tr -s ' \n' ' ')"
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$name")
    fi
    rm -f "$tmp_drain" "$tmp_out" "$load_log" "$load_status_file"
}

# Only examples/hello is ported to this target so far (see
# examples/common_rpi3/AGENTS.md) -- add more lines here one at a time
# as each is ported and verified, matching this project's YAGNI stance,
# not speculatively ahead of that.
run_hw_test_rpi3 "hello (rpi3)" "$REPO_ROOT/examples/hello/kernel_rpi3.elf" "$REPO_ROOT/examples/hello/hello.expected"

echo ""
echo "rpi3 hardware tests: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
    echo "failed tests:"
    for t in "${FAILED_TESTS[@]}"; do
        echo "  - $t"
    done
    exit 1
fi
