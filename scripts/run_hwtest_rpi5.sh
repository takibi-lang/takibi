#!/usr/bin/env bash
# Raspberry Pi 5 (BCM2712) hardware integration test runner -- called from
# repo root via: make hwcheck-rpi5
#
# Structure mirrors scripts/run_hwtest_rpi3.sh (reset-before-each-test,
# drain-then-capture, plain vs. suite runners) rather than being derived
# independently -- the same "leftover state from a previous test causes a
# flaky-looking failure" lesson RPi3's own hardware testing learned (issue
# #145) applies here too, and scripts/rpi5_jtag_reset.sh's PSCI SYSTEM_RESET
# trick (unlike RPi3's watchdog-register reset) is now confirmed to reliably
# rerun the currently-resident image, which is exactly what every test below
# needs: injection is over SWD directly into RAM, not by rewriting the SD
# card's kernel_2712.img, so PSCI reset's own "does not reliably reload a
# CHANGED file" limitation (GitHub issue #162) never applies to this loop.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SERIAL_DEV="${RPI5_SERIAL_DEV:-$("$REPO_ROOT/scripts/rpi5_uart_dev.sh")}"
BAUD=115200

POLL_INTERVAL=0.05
DRAIN_MAX_SECS=1.0
DRAIN_STABLE_POLLS=6
CAPTURE_MAX_SECS=5
CAPTURE_STABLE_POLLS=6

PASS=0
FAIL=0
FAILED_TESTS=()
HWTEST_ARTIFACT_ROOT="${RPI5_HWTEST_ARTIFACT_DIR:-$REPO_ROOT/_build/hwtest-rpi5}"
FAILURE_ARTIFACT_ROOT="${RPI5_FAILURE_ARTIFACT_DIR:-$REPO_ROOT/_build/hwtest-rpi5-failures}"

# shellcheck source=scripts/test_artifacts.sh
source "$REPO_ROOT/scripts/test_artifacts.sh"

if [ -t 1 ]; then
    GRN='\033[32m' RED='\033[31m' RST='\033[0m'
else
    GRN='' RED='' RST=''
fi

if [ -z "$SERIAL_DEV" ] || [ ! -e "$SERIAL_DEV" ]; then
    echo "error: could not resolve the Raspberry Pi 5 UART device (scripts/rpi5_uart_dev.sh" >&2
    echo "found: '$SERIAL_DEV') -- is the Debug Probe UART cable connected?" >&2
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

preserve_failure_artifacts() {
    local name="$1" uart_log="$2" loader_log="$3" reset_log="${4:-}"
    local safe_name artifact_dir
    safe_name=$(printf '%s' "$name" | tr -cs 'A-Za-z0-9._-' '_')
    artifact_dir="$FAILURE_ARTIFACT_ROOT/$safe_name"
    mkdir -p "$artifact_dir"
    if [ -f "$uart_log" ]; then
        cp "$uart_log" "$artifact_dir/uart.log"
    fi
    if [ -f "$loader_log" ]; then
        cp "$loader_log" "$artifact_dir/loader.log"
    fi
    if [ -n "$reset_log" ] && [ -f "$reset_log" ]; then
        cp "$reset_log" "$artifact_dir/reset.log"
    fi
    printf "       failure artifacts: %s\n" "$artifact_dir"
}

# read_until_quiet: same idle-detection technique as
# scripts/run_hwtest_rpi3.sh (see that file for the full comment).
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

# reset_before_test NAME
#
# Full BCM2712 reboot (scripts/rpi5_jtag_reset.sh's PSCI SYSTEM_RESET
# trampoline) run before EVERY test, same "eliminate leftover-state false
# alarms" reasoning as run_hwtest_rpi3.sh's own reset_before_test -- this
# board has no MMU/interrupt state to leak yet (Stage A), but RP1 PCIe
# link/BAR state from a previous test's uart_init() persists across a
# plain SWD re-injection (which only overwrites RAM and moves PC, it does
# not touch RP1), so a full reboot before each test avoids depending on
# every example's own PCIe bring-up being idempotent.
reset_before_test() {
    local name="$1"
    local reset_log
    reset_log=$(mktemp)
    if ! "$REPO_ROOT/scripts/rpi5_jtag_reset.sh" > "$reset_log" 2>&1; then
        printf "${RED}FAIL${RST}  %s  (PSCI reset failed -- log follows)\n" "$name"
        sed 's/^/       /' "$reset_log"
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$name")
        preserve_failure_artifacts "$name" /dev/null /dev/null "$reset_log"
        rm -f "$reset_log"
        exit 1
    fi
    rm -f "$reset_log"
}

# run_hw_test_rpi5 NAME ELF EXPECTED [MAX_SECS] [STABLE_POLLS]
run_hw_test_rpi5() {
    local name="$1" elf="$2" expected="$3" \
          max_secs="${4:-$CAPTURE_MAX_SECS}" stable_polls="${5:-$CAPTURE_STABLE_POLLS}"
    local tmp_drain tmp_out load_log load_status_file load_status
    tmp_drain=$(mktemp)
    tmp_out=$(mktemp)
    load_log=$(mktemp)
    load_status_file=$(mktemp)

    reset_before_test "$name"
    read_until_quiet "$tmp_drain" "$DRAIN_MAX_SECS" "$DRAIN_STABLE_POLLS" 0
    read_until_quiet "$tmp_out" "$max_secs" "$stable_polls" 1 \
        "if \"$REPO_ROOT/scripts/rpi5_jtag_load.sh\" \"$elf\" > \"$load_log\" 2>&1; then load_status=0; else load_status=\$?; fi; echo \"\$load_status\" > \"$load_status_file\""

    load_status=$(cat "$load_status_file" 2>/dev/null || echo 1)

    if [ "$load_status" != "0" ]; then
        printf "${RED}FAIL${RST}  %s  (SWD injection failed -- loader log follows)\n" "$name"
        sed 's/^/       /' "$load_log"
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$name")
        save_artifact_file "$HWTEST_ARTIFACT_ROOT" "$name" "$tmp_out" uart.log
        preserve_failure_artifacts "$name" "$tmp_out" "$load_log"
        rm -f "$tmp_drain" "$tmp_out" "$load_log" "$load_status_file"
        exit 1
    elif cmp -s "$expected" "$tmp_out"; then
        save_artifact_file "$HWTEST_ARTIFACT_ROOT" "$name" "$tmp_out" uart.log
        printf "${GRN}PASS${RST}  %s\n" "$name"
        PASS=$((PASS + 1))
    else
        printf "${RED}FAIL${RST}  %s  (unexpected UART output)\n" "$name"
        printf "       expected: %s\n" "$(od -An -c "$expected" | tr -s ' \n' ' ')"
        printf "       actual:   %s\n" "$(od -An -c "$tmp_out" | tr -s ' \n' ' ')"
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$name")
        save_artifact_file "$HWTEST_ARTIFACT_ROOT" "$name" "$tmp_out" uart.log
        preserve_failure_artifacts "$name" "$tmp_out" "$load_log"
    fi
    rm -f "$tmp_drain" "$tmp_out" "$load_log" "$load_status_file"
}

# run_hw_test_rpi5_suite SUITE_NAME ELF MANIFEST
#
# Reset/load once, then retain one PASS/FAIL result per original example by
# splitting the marked UART stream with the shared suite-output checker --
# same reasoning and same scripts/check_suite_output.py as
# run_hwtest_rpi3.sh's own run_hw_test_rpi3_suite.
run_hw_test_rpi5_suite() {
    local suite_name="$1" elf="$2" manifest="$3"
    local tmp_drain tmp_out load_log load_status_file load_status
    local report status name expected actual suite_failed=0
    tmp_drain=$(mktemp)
    tmp_out=$(mktemp)
    load_log=$(mktemp)
    load_status_file=$(mktemp)
    report=$(mktemp)

    reset_before_test "$suite_name (rpi5)"
    read_until_quiet "$tmp_drain" "$DRAIN_MAX_SECS" "$DRAIN_STABLE_POLLS" 0
    read_until_quiet "$tmp_out" "$CAPTURE_MAX_SECS" "$CAPTURE_STABLE_POLLS" 1 \
        "if \"$REPO_ROOT/scripts/rpi5_jtag_load.sh\" \"$elf\" > \"$load_log\" 2>&1; then load_status=0; else load_status=\$?; fi; echo \"\$load_status\" > \"$load_status_file\""
    load_status=$(cat "$load_status_file" 2>/dev/null || echo 1)

    if [ "$load_status" != "0" ]; then
        printf "${RED}FAIL${RST}  %s (rpi5)  (SWD injection failed -- loader log follows)\n" "$suite_name"
        sed 's/^/       /' "$load_log"
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$suite_name (rpi5)")
        save_artifact_file "$HWTEST_ARTIFACT_ROOT" "$suite_name (rpi5)" "$tmp_out" uart.log
        preserve_failure_artifacts "$suite_name (rpi5)" "$tmp_out" "$load_log"
        rm -f "$tmp_drain" "$tmp_out" "$load_log" "$load_status_file" "$report"
        exit 1
    fi

    python3 "$(dirname "$0")/check_suite_output.py" "$tmp_out" \
        "$manifest" > "$report" || true
    [ -s "$report" ] || printf 'ERROR\tsuite checker produced no result\n' > "$report"

    while IFS=$'\t' read -r status name expected actual; do
        case "$status" in
            PASS)
                save_artifact_file "$HWTEST_ARTIFACT_ROOT" "$name (rpi5)" "$tmp_out" uart.log
                printf "${GRN}PASS${RST}  %s (rpi5)\n" "$name"
                PASS=$((PASS + 1))
                ;;
            FAIL)
                save_artifact_file "$HWTEST_ARTIFACT_ROOT" "$name (rpi5)" "$tmp_out" uart.log
                printf "${RED}FAIL${RST}  %s (rpi5)\n" "$name"
                printf "       expected bytes: %s\n" "$expected"
                printf "       got bytes:      %s\n" "$actual"
                FAIL=$((FAIL + 1))
                FAILED_TESTS+=("$name (rpi5)")
                suite_failed=1
                ;;
            ERROR)
                save_artifact_file "$HWTEST_ARTIFACT_ROOT" "$suite_name (rpi5)" "$tmp_out" uart.log
                printf "${RED}FAIL${RST}  %s (rpi5)  (%s)\n" "$suite_name" "$name"
                FAIL=$((FAIL + 1))
                FAILED_TESTS+=("$suite_name (rpi5)")
                suite_failed=1
                ;;
        esac
    done < "$report"
    if [ "$suite_failed" -ne 0 ]; then
        preserve_failure_artifacts "$suite_name (rpi5)" "$tmp_out" "$load_log"
    fi
    rm -f "$tmp_drain" "$tmp_out" "$load_log" "$load_status_file" "$report"
}

# Mirrors RPI5_EXAMPLES in the Makefile -- see
# examples/common_rpi5/AGENTS.md for what's still deliberately excluded
# (anything needing irq/USB/networking/EL0/EL1/SMP, until issues #163/
# #164 land). type_system_suite/algorithm_suite are back (issue #165,
# examples/common_rpi5/mmu.S) after real hardware testing confirmed both
# pass with the stage-1 MMU enabled. rtc/timer are back (issue #170,
# examples/common_rpi5/rtc.tkb) -- pure CNTPCT_EL0/CNTFRQ_EL0 polling,
# no interrupt/GIC dependency. Every .expected/cases.txt fixture here is
# reused byte-for-byte from the QEMU/STM32/RPi3 suites -- uart_puts/
# uart_print_* write identical bytes on every HAL.
run_hw_test_rpi5 "start (rpi5)" "$REPO_ROOT/examples/start/kernel_rpi5.elf" \
    "$REPO_ROOT/examples/start/start.expected"
run_hw_test_rpi5_suite basic_suite "$REPO_ROOT/examples/basic_suite/kernel_rpi5.elf" \
    "$REPO_ROOT/examples/basic_suite/cases.txt"
run_hw_test_rpi5_suite type_system_suite "$REPO_ROOT/examples/type_system_suite/kernel_rpi5.elf" \
    "$REPO_ROOT/examples/type_system_suite/cases.txt"
run_hw_test_rpi5_suite algorithm_suite "$REPO_ROOT/examples/algorithm_suite/kernel_rpi5.elf" \
    "$REPO_ROOT/examples/algorithm_suite/cases.txt"
run_hw_test_rpi5 "bump (rpi5)" "$REPO_ROOT/examples/bump/kernel_rpi5.elf" \
    "$REPO_ROOT/examples/bump/bump.expected"
run_hw_test_rpi5 "scheduler (rpi5)" "$REPO_ROOT/examples/scheduler/kernel_rpi5.elf" \
    "$REPO_ROOT/examples/scheduler/scheduler.expected"
run_hw_test_rpi5 "klock_guard (rpi5)" "$REPO_ROOT/examples/klock_guard/kernel_rpi5.elf" \
    "$REPO_ROOT/examples/klock_guard/klock_guard.expected"
run_hw_test_rpi5 "percpu (rpi5)" "$REPO_ROOT/examples/percpu/kernel_rpi5.elf" \
    "$REPO_ROOT/examples/percpu/percpu.expected"
# MAX_SECS=5/STABLE_POLLS=30 override: rtc/timer wait up to a real
# 1-second ARM Generic Timer tick between prints -- the default ~0.3s
# idle-quiet threshold mistakes that in-test pause for completion and
# truncates the capture, same gotcha run_hwtest_rpi3.sh's own comment
# documents for these exact two examples.
run_hw_test_rpi5 "rtc (rpi5)" "$REPO_ROOT/examples/rtc/kernel_rpi5.elf" \
    "$REPO_ROOT/examples/rtc/rtc.expected" 5 30
run_hw_test_rpi5 "timer (rpi5)" "$REPO_ROOT/examples/timer/kernel_rpi5.elf" \
    "$REPO_ROOT/examples/timer/timer.expected" 5 30

echo
echo "RPi5 hardware tests: $PASS passed, $FAIL failed"
if [ "$FAIL" -ne 0 ]; then
    printf 'failed: %s\n' "${FAILED_TESTS[*]}"
    exit 1
fi
