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
CAPTURE_SECS=3

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

# run_hw_test NAME BIN EXPECTED
#
# Flashes BIN at FLASH_ADDR, resets, and captures UART output for
# CAPTURE_SECS seconds, diffing against EXPECTED byte-for-byte (same
# expected-file convention as run_qemutest.sh's run_test).
#
# The serial reader is started BEFORE the reset, not after: at 16MHz, boot
# plus a tiny program runs in microseconds, and `st-flash write` itself
# already resets and runs the newly flashed program as a side effect. During
# step-2's manual verification, flashing and then opening the serial port
# afterward missed the output entirely -- "Hello, World!" had already been
# transmitted and was gone by the time `cat` started. Opening the port and
# starting the background reader first, then triggering the (second, but
# harmless) explicit reset, avoids the race.
run_hw_test() {
    local name="$1" bin="$2" expected="$3"
    local tmp_out tmp_flash_log
    tmp_out=$(mktemp)
    tmp_flash_log=$(mktemp)

    if ! st-flash write "$bin" "$FLASH_ADDR" > "$tmp_flash_log" 2>&1; then
        printf "${RED}FAIL${RST}  %s  (st-flash write failed)\n" "$name"
        sed 's/^/       /' "$tmp_flash_log"
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$name")
        rm -f "$tmp_out" "$tmp_flash_log"
        return
    fi

    stty -F "$SERIAL_DEV" "$BAUD" raw -echo
    timeout "$CAPTURE_SECS" cat "$SERIAL_DEV" > "$tmp_out" &
    local catpid=$!
    sleep 0.3
    st-flash reset > /dev/null 2>&1
    wait "$catpid" 2>/dev/null || true

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

run_hw_test "hello (stm32)" examples/hello/kernel_stm32.bin examples/hello/hello.expected

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
