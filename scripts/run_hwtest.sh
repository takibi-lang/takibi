#!/usr/bin/env bash
# STM32 hardware integration test runner -- called from repo root via: make hwcheck
# Unlike run_qemutest.sh, these tests need the real STM32F746G-DISCOVERY board
# connected via USB (ST-LINK VCP for serial + SWD for flashing), so this is a
# separate target from `make check`/`make qemutest`, which must stay runnable
# on any clone of this repo with no physical hardware attached.
set -euo pipefail

SERIAL_DEV="${STM32_SERIAL_DEV:-/dev/ttyACM0}"
BAUD=115200
FLASH_ADDR=0x08000000

# Idle-detection polling constants (see read_until_quiet below). These
# examples finish -- and the UART goes idle -- in well under a second, so
# waiting out a fixed multi-second `timeout N cat` per test (as an earlier
# version of this script did) was the dominant cost of `make hwcheck`,
# multiplied across ~29 examples on every commit. Polling for actual
# quiescence instead cuts a ~4s/test fixed cost down to however long the
# board actually takes to respond.
POLL_INTERVAL=0.05
DRAIN_MAX_SECS=0.5
DRAIN_STABLE_POLLS=2      # ~100ms of no growth
CAPTURE_MAX_SECS=2        # safety cap if a test hangs/never produces output
CAPTURE_STABLE_POLLS=4    # ~200ms of no growth after output starts

PASS=0
FAIL=0
FAILED_TESTS=()

# ANSI colours only when writing to a terminal
if [ -t 1 ]; then
    GRN='\033[32m' RED='\033[31m' RST='\033[0m'
else
    GRN='' RED='' RST=''
fi

if [ ! -e "$SERIAL_DEV" ]; then
    echo "error: $SERIAL_DEV not found -- is the STM32F746G-DISCOVERY board connected?" >&2
    exit 1
fi

if ! st-info --probe > /dev/null 2>&1; then
    echo "error: st-info --probe failed -- is the ST-LINK debug interface accessible?" >&2
    exit 1
fi

# read_until_quiet OUTFILE MAX_SECS STABLE_POLLS WAIT_FOR_DATA [POST_START_CMD]
#
# Reads $SERIAL_DEV into OUTFILE until no new bytes have arrived for
# STABLE_POLLS * POLL_INTERVAL seconds, or MAX_SECS elapses (a safety cap in
# case a test hangs and never produces output -- diffing an incomplete
# capture against EXPECTED still fails correctly in that case, it just
# doesn't hang the whole suite).
#
# WAIT_FOR_DATA=1 requires at least one byte to have arrived before
# quiescence can be declared -- needed when POST_START_CMD (e.g.
# `st-flash reset`) is what actually triggers the output, since the reader
# starts running before that happens and the initial silence beforehand
# must not be mistaken for "already done". Pass WAIT_FOR_DATA=0 for a plain
# drain with no POST_START_CMD, where "nothing was ever buffered" is itself
# a valid, fast exit. POST_START_CMD runs once, a short settle delay after
# the reader attaches, and is what step-2 called the "second, but harmless"
# explicit reset (see run_hw_test below for why a reset is needed at all).
read_until_quiet() {
    local outfile="$1" max_secs="$2" stable_polls_needed="$3" wait_for_data="$4" post_start_cmd="${5:-}"
    : > "$outfile"
    cat "$SERIAL_DEV" > "$outfile" 2>/dev/null &
    local catpid=$!
    if [ -n "$post_start_cmd" ]; then
        sleep 0.1
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
}

# run_hw_test NAME BIN EXPECTED
#
# Flashes BIN at FLASH_ADDR, resets, and captures UART output, diffing
# against EXPECTED byte-for-byte (same expected-file convention as
# run_qemutest.sh's run_test).
#
# The serial reader is started BEFORE the (explicit) reset, not after: at
# 16MHz, boot plus a tiny program runs in microseconds, and `st-flash write`
# itself already resets and runs the newly flashed program as a side effect,
# before this function ever opens the serial port. During step-2's manual
# verification, flashing and then opening the serial port afterward missed
# the output entirely -- it had already been transmitted and was gone by the
# time `cat` started.
#
# That still leaves one wrinkle discovered while porting a full batch of
# examples: `st-flash write`'s own automatic run happens with nobody reading
# yet, and its output doesn't vanish cleanly -- a short tail fragment of it
# survives in a small kernel/USB-CDC buffer and would otherwise show up
# prepended to the *next* capture once a reader finally attaches. The drain
# call below opens the port and discards whatever's sitting there (that
# stale fragment from the write-triggered run) before starting the real
# capture -- so only the explicit `st-flash reset` below is actually being
# measured.
run_hw_test() {
    local name="$1" bin="$2" expected="$3"
    local tmp_out tmp_drain tmp_flash_log
    tmp_out=$(mktemp)
    tmp_drain=$(mktemp)
    tmp_flash_log=$(mktemp)

    if ! st-flash write "$bin" "$FLASH_ADDR" > "$tmp_flash_log" 2>&1; then
        printf "${RED}FAIL${RST}  %s  (st-flash write failed)\n" "$name"
        sed 's/^/       /' "$tmp_flash_log"
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$name")
        rm -f "$tmp_out" "$tmp_drain" "$tmp_flash_log"
        return
    fi

    stty -F "$SERIAL_DEV" "$BAUD" raw -echo
    read_until_quiet "$tmp_drain" "$DRAIN_MAX_SECS" "$DRAIN_STABLE_POLLS" 0
    rm -f "$tmp_drain"

    read_until_quiet "$tmp_out" "$CAPTURE_MAX_SECS" "$CAPTURE_STABLE_POLLS" 1 \
        "st-flash reset > /dev/null 2>&1"

    if diff -q "$expected" "$tmp_out" > /dev/null 2>&1; then
        printf "${GRN}PASS${RST}  %s\n" "$name"
        PASS=$((PASS + 1))
    else
        printf "${RED}FAIL${RST}  %s\n" "$name"
        printf "       expected bytes: %s\n" "$(od -An -c "$expected" | tr -s ' \n' ' ')"
        printf "       got bytes:      %s\n" "$(od -An -c "$tmp_out"  | tr -s ' \n' ' ')"
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$name")
    fi

    rm -f "$tmp_out" "$tmp_flash_log"
}

echo "Running STM32 hardware integration tests against $SERIAL_DEV..."
echo ""

# Every example built by the Makefile's STM32_BINS list (see the "STM32
# hardware bring-up" section there for what's included/excluded and why).
# Every .expected file here is the same one run_qemutest.sh's run_test calls
# already diff against for the AArch64/QEMU build -- uart_puts/uart_print_*
# write the exact same bytes on either HAL, so no separate expected output
# is needed for hardware.
run_hw_test "start (stm32)"         examples/start/kernel_stm32.bin         examples/start/start.expected
run_hw_test "hello (stm32)"         examples/hello/kernel_stm32.bin         examples/hello/hello.expected
run_hw_test "print_int (stm32)"     examples/print_int/kernel_stm32.bin     examples/print_int/print_int.expected
run_hw_test "print_hex (stm32)"     examples/print_hex/kernel_stm32.bin     examples/print_hex/print_hex.expected
run_hw_test "print_ptr (stm32)"     examples/print_ptr/kernel_stm32.bin     examples/print_ptr/print_ptr.expected
run_hw_test "mem (stm32)"           examples/mem/kernel_stm32.bin           examples/mem/mem.expected
run_hw_test "array (stm32)"         examples/array/kernel_stm32.bin         examples/array/array.expected
run_hw_test "fizzbuzz (stm32)"      examples/fizzbuzz/kernel_stm32.bin      examples/fizzbuzz/fizzbuzz.expected
run_hw_test "fibonacci (stm32)"     examples/fibonacci/kernel_stm32.bin     examples/fibonacci/fibonacci.expected
run_hw_test "bubblesort (stm32)"    examples/bubblesort/kernel_stm32.bin    examples/bubblesort/bubblesort.expected
run_hw_test "ringbuf (stm32)"       examples/ringbuf/kernel_stm32.bin       examples/ringbuf/ringbuf.expected
run_hw_test "callstack (stm32)"     examples/callstack/kernel_stm32.bin     examples/callstack/callstack.expected
run_hw_test "crc8 (stm32)"          examples/crc8/kernel_stm32.bin          examples/crc8/crc8.expected
run_hw_test "djb2 (stm32)"          examples/djb2/kernel_stm32.bin          examples/djb2/djb2.expected
run_hw_test "bump (stm32)"          examples/bump/kernel_stm32.bin          examples/bump/bump.expected
run_hw_test "scheduler (stm32)"     examples/scheduler/kernel_stm32.bin     examples/scheduler/scheduler.expected
run_hw_test "struct (stm32)"        examples/struct/kernel_stm32.bin        examples/struct/struct.expected
run_hw_test "refined (stm32)"       examples/refined/kernel_stm32.bin       examples/refined/refined.expected
run_hw_test "narrow (stm32)"        examples/narrow/kernel_stm32.bin        examples/narrow/narrow.expected
run_hw_test "for (stm32)"           examples/for/kernel_stm32.bin           examples/for/for.expected
run_hw_test "loop (stm32)"          examples/loop/kernel_stm32.bin          examples/loop/loop.expected
run_hw_test "enum (stm32)"          examples/enum/kernel_stm32.bin          examples/enum/enum.expected
run_hw_test "nonexhaustive (stm32)" examples/nonexhaustive/kernel_stm32.bin examples/nonexhaustive/nonexhaustive.expected
run_hw_test "bitops (stm32)"        examples/bitops/kernel_stm32.bin        examples/bitops/bitops.expected
run_hw_test "align (stm32)"         examples/align/kernel_stm32.bin         examples/align/align.expected
run_hw_test "packed (stm32)"        examples/packed/kernel_stm32.bin        examples/packed/packed.expected
run_hw_test "struct_align (stm32)"  examples/struct_align/kernel_stm32.bin  examples/struct_align/struct_align.expected
run_hw_test "const_global (stm32)"  examples/const_global/kernel_stm32.bin  examples/const_global/const_global.expected
run_hw_test "sizeof (stm32)"        examples/sizeof/kernel_stm32.bin        examples/sizeof/sizeof.expected

echo ""
if [ "$FAIL" -eq 0 ]; then
    printf "${GRN}All $PASS hardware test(s) passed.${RST}\n"
else
    printf "${RED}$FAIL hardware test(s) failed${RST} ($PASS passed).\n"
    printf "${RED}Failed:${RST}"
    for t in "${FAILED_TESTS[@]}"; do
        printf "  %s" "$t"
    done
    printf "\n"
fi

[ "$FAIL" -eq 0 ]
