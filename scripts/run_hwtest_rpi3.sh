#!/usr/bin/env bash
# Raspberry Pi 3B hardware integration test runner -- called from repo
# root via: make hwcheck-rpi3
#
# The 6-pin GPIO JTAG header has no wired system reset line (see
# examples/common_rpi3/AGENTS.md), so this cannot use STM32's
# scripts/run_hwtest_ram.sh's own `reset halt` -- but
# scripts/rpi3_jtag_reset.sh reaches the same end state a different way
# (BCM2837's own watchdog-based software reset, poked via JTAG), and
# every test below runs it first (see reset_before_test's own comment).
# scripts/rpi3_jtag_load.sh's own EL2H safety check still matters
# independently of that: if the board is still running Raspbian (never
# power-cycled to the stub this session), injection fails fast with a
# clear error, rather than silently producing a confusing UART mismatch
# -- rpi3_jtag_reset.sh only recovers a board already parked in
# examples/common_rpi3/jtag_stub.S's spin loop, it cannot get a live
# Raspbian session there.
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

# reset_before_test NAME
#
# Full BCM2837 chip reset (scripts/rpi3_jtag_reset.sh) run before EVERY
# single hardware test in this suite, not just opportunistically when
# something looks broken. This board's JTAG re-injection
# (rpi3_jtag_load.sh) only replaces the running payload -- it does not
# reset MMU/cache/peripheral/interrupt-controller/DWC2-USB state left
# behind by whatever ran before it. Real-hardware experience (GitHub
# issue #145's own investigation, and independently reproduced by the
# project owner) repeatedly found tests that pass in isolation fail when
# run back-to-back with no reset in between -- garbled UART output,
# unreachable networking, even a USB drive sector-write failure -- all
# traced to leftover state, not a real regression, and all resolved by
# resetting first. A reset costs ~4.3s measured on this hardware
# (rpi3_jtag_load.sh itself is ~0.4s), so decoupling every test this way
# costs the whole suite a few extra minutes in exchange for eliminating
# an entire recurring class of false alarms -- confirmed worth it on
# real hardware rather than continuing to chase individual flaky
# transitions one at a time.
reset_before_test() {
    local name="$1"
    local reset_log
    reset_log=$(mktemp)
    if ! "$REPO_ROOT/scripts/rpi3_jtag_reset.sh" > "$reset_log" 2>&1; then
        printf "${RED}FAIL${RST}  %s  (JTAG reset failed -- log follows)\n" "$name"
        sed 's/^/       /' "$reset_log"
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$name")
        rm -f "$reset_log"
        exit 1
    fi
    rm -f "$reset_log"
}

# run_hw_test_rpi3 NAME ELF EXPECTED [MAX_SECS] [STABLE_POLLS]
#
# Distinguishes two different failure modes rather than collapsing them
# into one UART mismatch: (1) rpi3_jtag_load.sh itself failing (almost
# always the EL2H safety check refusing a still-Raspbian board --
# actionable: power-cycle/scripts/rpi3_jtag_reset.sh and retry) vs
# (2) injection succeeding but the captured UART output not matching --
# an actual test failure.
#
# Optional MAX_SECS/STABLE_POLLS override the module-level
# CAPTURE_MAX_SECS/CAPTURE_STABLE_POLLS defaults -- needed for
# examples/rtc and examples/timer, which wait up to a real 1-second ARM
# Generic Timer tick between two print statements (see
# examples/common_rpi3/rtc.tkb): the default ~0.3s idle-quiet threshold
# mistakes that in-test pause for completion and truncates the capture
# before the second print arrives, same gotcha
# examples/common_stm32/AGENTS.md documents for the STM32 harness.
run_hw_test_rpi3() {
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
        "if \"$REPO_ROOT/scripts/rpi3_jtag_load.sh\" \"$elf\" > \"$load_log\" 2>&1; then load_status=0; else load_status=\$?; fi; echo \"\$load_status\" > \"$load_status_file\""

    load_status=$(cat "$load_status_file" 2>/dev/null || echo 1)

    if [ "$load_status" != "0" ]; then
        printf "${RED}FAIL${RST}  %s  (JTAG injection failed -- loader log follows)\n" "$name"
        sed 's/^/       /' "$load_log"
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$name")
        rm -f "$tmp_drain" "$tmp_out" "$load_log" "$load_status_file"
        exit 1
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

# run_hw_test_rpi3_suite SUITE_NAME ELF MANIFEST
#
# Reset/load once, then retain one PASS/FAIL result per original example by
# splitting the marked UART stream with the shared suite-output checker.
run_hw_test_rpi3_suite() {
    local suite_name="$1" elf="$2" manifest="$3"
    local tmp_drain tmp_out load_log load_status_file load_status
    local report status name expected actual
    tmp_drain=$(mktemp)
    tmp_out=$(mktemp)
    load_log=$(mktemp)
    load_status_file=$(mktemp)
    report=$(mktemp)

    reset_before_test "$suite_name (rpi3)"
    read_until_quiet "$tmp_drain" "$DRAIN_MAX_SECS" "$DRAIN_STABLE_POLLS" 0
    read_until_quiet "$tmp_out" "$CAPTURE_MAX_SECS" "$CAPTURE_STABLE_POLLS" 1 \
        "if \"$REPO_ROOT/scripts/rpi3_jtag_load.sh\" \"$elf\" > \"$load_log\" 2>&1; then load_status=0; else load_status=\$?; fi; echo \"\$load_status\" > \"$load_status_file\""
    load_status=$(cat "$load_status_file" 2>/dev/null || echo 1)

    if [ "$load_status" != "0" ]; then
        printf "${RED}FAIL${RST}  %s (rpi3)  (JTAG injection failed -- loader log follows)\n" "$suite_name"
        sed 's/^/       /' "$load_log"
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$suite_name (rpi3)")
        rm -f "$tmp_drain" "$tmp_out" "$load_log" "$load_status_file" "$report"
        exit 1
    fi

    python3 "$(dirname "$0")/check_suite_output.py" "$tmp_out" \
        "$manifest" > "$report" || true
    [ -s "$report" ] || printf 'ERROR\tsuite checker produced no result\n' > "$report"

    while IFS=$'\t' read -r status name expected actual; do
        case "$status" in
            PASS)
                printf "${GRN}PASS${RST}  %s (rpi3)\n" "$name"
                PASS=$((PASS + 1))
                ;;
            FAIL)
                printf "${RED}FAIL${RST}  %s (rpi3)\n" "$name"
                printf "       expected bytes: %s\n" "$expected"
                printf "       got bytes:      %s\n" "$actual"
                FAIL=$((FAIL + 1))
                FAILED_TESTS+=("$name (rpi3)")
                ;;
            ERROR)
                printf "${RED}FAIL${RST}  %s (rpi3)  (%s)\n" "$suite_name" "$name"
                FAIL=$((FAIL + 1))
                FAILED_TESTS+=("$suite_name (rpi3)")
                ;;
        esac
    done < "$report"
    rm -f "$tmp_drain" "$tmp_out" "$load_log" "$load_status_file" "$report"
}

# run_hw_test_rpi3_stdin NAME ELF EXPECTED STDIN_FILE
#
# RPi3 counterpart of scripts/run_hwtest_ram.sh's run_hw_test_ram_stdin
# (echo, irq): waits for the first output byte (confirming the
# firmware's read loop has actually started) before writing STDIN_FILE
# to the serial port. Same load-failure-vs-mismatch distinction as
# run_hw_test_rpi3 above.
run_hw_test_rpi3_stdin() {
    local name="$1" elf="$2" expected="$3" stdin_file="$4"
    local tmp_drain tmp_out load_log load_status_file load_status
    tmp_drain=$(mktemp)
    tmp_out=$(mktemp)
    load_log=$(mktemp)
    load_status_file=$(mktemp)

    reset_before_test "$name"
    read_until_quiet "$tmp_drain" "$DRAIN_MAX_SECS" "$DRAIN_STABLE_POLLS" 0

    : > "$tmp_out"
    cat "$SERIAL_DEV" > "$tmp_out" 2>/dev/null 9>&- &
    local catpid=$!
    ACTIVE_READER_PID=$catpid
    sleep 0.2
    if "$REPO_ROOT/scripts/rpi3_jtag_load.sh" "$elf" > "$load_log" 2>&1; then
        load_status=0
    else
        load_status=$?
    fi
    echo "$load_status" > "$load_status_file"

    if [ "$load_status" = "0" ]; then
        local max_wait_polls waited=0 size
        max_wait_polls=$(awk -v m="$CAPTURE_MAX_SECS" -v i="$POLL_INTERVAL" 'BEGIN{printf "%d", m/i}')
        while [ "$waited" -lt "$max_wait_polls" ]; do
            sleep "$POLL_INTERVAL"
            size=$(stat -c%s "$tmp_out" 2>/dev/null || echo 0)
            [ "$size" -gt 0 ] && break
            waited=$((waited + 1))
        done
        cat "$stdin_file" > "$SERIAL_DEV"

        local max_polls last_size=-1 stable=0 poll=0
        max_polls=$(awk -v m="$CAPTURE_MAX_SECS" -v i="$POLL_INTERVAL" 'BEGIN{printf "%d", m/i}')
        while [ "$poll" -lt "$max_polls" ]; do
            sleep "$POLL_INTERVAL"
            size=$(stat -c%s "$tmp_out" 2>/dev/null || echo 0)
            if [ "$size" = "$last_size" ]; then
                stable=$((stable + 1))
                [ "$stable" -ge "$CAPTURE_STABLE_POLLS" ] && break
            else
                stable=0
            fi
            last_size="$size"
            poll=$((poll + 1))
        done
    fi
    kill "$catpid" 2>/dev/null || true
    wait "$catpid" 2>/dev/null || true
    ACTIVE_READER_PID=""

    if [ "$load_status" != "0" ]; then
        printf "${RED}FAIL${RST}  %s  (JTAG injection failed -- loader log follows)\n" "$name"
        sed 's/^/       /' "$load_log"
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$name")
        rm -f "$tmp_drain" "$tmp_out" "$load_log" "$load_status_file"
        exit 1
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

# run_hw_test_rpi3_usb_msc NAME ELF SCRIPT
#
# GitHub issue #145's real USB Mass Storage driver (examples/usb_msc_probe)
# -- same "no filesystem at this layer, verify a deterministic byte round
# trip independently" principle as scripts/run_hwtest_ram.sh's own
# run_hw_test_ram_sdcard (SCRIPT is scripts/usb_msc_test.py, the USB
# counterpart of scripts/sdcard_test.py), adapted to this board's JTAG
# loader instead of STM32's OpenOCD RAM load. Destroys whatever was
# previously on the attached USB drive every run (confirmed acceptable
# for this project's own dedicated test drive, same as sdcard's).
run_hw_test_rpi3_usb_msc() {
    local name="$1" elf="$2" script="$3"
    local tmp_drain tmp_out load_log load_status_file load_status
    tmp_drain=$(mktemp)
    tmp_out=$(mktemp)
    load_log=$(mktemp)
    load_status_file=$(mktemp)

    reset_before_test "$name"
    read_until_quiet "$tmp_drain" "$DRAIN_MAX_SECS" "$DRAIN_STABLE_POLLS" 0
    read_until_quiet "$tmp_out" 20 140 1 \
        "if \"$REPO_ROOT/scripts/rpi3_jtag_load.sh\" \"$elf\" > \"$load_log\" 2>&1; then load_status=0; else load_status=\$?; fi; echo \"\$load_status\" > \"$load_status_file\""

    load_status=$(cat "$load_status_file" 2>/dev/null || echo 1)

    if [ "$load_status" != "0" ]; then
        printf "${RED}FAIL${RST}  %s  (JTAG injection failed -- loader log follows)\n" "$name"
        sed 's/^/       /' "$load_log"
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$name")
        rm -f "$tmp_drain" "$tmp_out" "$load_log" "$load_status_file"
        exit 1
    elif python3 "$(dirname "$0")/$script" "$tmp_out"; then
        printf "${GRN}PASS${RST}  %s\n" "$name"
        PASS=$((PASS + 1))
    else
        printf "${RED}FAIL${RST}  %s\n" "$name"
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$name")
    fi
    rm -f "$tmp_drain" "$tmp_out" "$load_log" "$load_status_file"
}

# Mirrors RPI3_EXAMPLES + RPI3_IRQ_EXAMPLES + RPI3_RTC_EXAMPLES +
# RPI3_SCHED_EXAMPLES in the Makefile -- see
# examples/common_rpi3/AGENTS.md for what's still deliberately excluded
# (semaphore/condvar/msgqueue/watchdog/rtos_demo, the rest of the
# preemptive-scheduler group examples/preempt is the first of; SD-card-
# storage examples are out of scope entirely). Every .expected/.stdin
# fixture here is reused byte-for-byte from the QEMU/STM32 suites --
# uart_puts/uart_print_* write identical bytes on every HAL, even though
# rtc/timer's underlying time source here (the ARM Generic Timer's
# free-running counter, not a real RTC peripheral) differs -- both
# fixtures only ever check that time advances, never an absolute value.
run_hw_test_rpi3 "start (rpi3)"          "$REPO_ROOT/examples/start/kernel_rpi3.elf"          "$REPO_ROOT/examples/start/start.expected"
run_hw_test_rpi3_suite basic_suite "$REPO_ROOT/examples/basic_suite/kernel_rpi3.elf" \
    "$REPO_ROOT/examples/basic_suite/cases.txt"
run_hw_test_rpi3_suite type_system_suite "$REPO_ROOT/examples/type_system_suite/kernel_rpi3.elf" \
    "$REPO_ROOT/examples/type_system_suite/cases.txt"
run_hw_test_rpi3_suite algorithm_suite "$REPO_ROOT/examples/algorithm_suite/kernel_rpi3.elf" \
    "$REPO_ROOT/examples/algorithm_suite/cases.txt"
run_hw_test_rpi3 "bump (rpi3)"           "$REPO_ROOT/examples/bump/kernel_rpi3.elf"           "$REPO_ROOT/examples/bump/bump.expected"
run_hw_test_rpi3 "scheduler (rpi3)"      "$REPO_ROOT/examples/scheduler/kernel_rpi3.elf"      "$REPO_ROOT/examples/scheduler/scheduler.expected"
run_hw_test_rpi3 "klock_guard (rpi3)"    "$REPO_ROOT/examples/klock_guard/kernel_rpi3.elf"    "$REPO_ROOT/examples/klock_guard/klock_guard.expected"
run_hw_test_rpi3 "percpu (rpi3)"         "$REPO_ROOT/examples/percpu/kernel_rpi3.elf"         "$REPO_ROOT/examples/percpu/percpu.expected"
RPI3_SMP_CORES=4 run_hw_test_rpi3 "smp_handoff (rpi3)" "$REPO_ROOT/examples/smp_handoff/kernel_rpi3.elf" "$REPO_ROOT/examples/smp_handoff/smp_handoff.expected" 5 30
run_hw_test_rpi3 "page_pool (rpi3)"       "$REPO_ROOT/examples/page_pool/kernel_rpi3.elf"       "$REPO_ROOT/examples/page_pool/page_pool.expected"
run_hw_test_rpi3 "vm_page_map (rpi3)"     "$REPO_ROOT/examples/vm_page_map/kernel_rpi3.elf"     "$REPO_ROOT/examples/vm_page_map/vm_page_map.expected" 5 6
RPI3_SMP_CORES=4 run_hw_test_rpi3 "smp_page_transfer (rpi3)" "$REPO_ROOT/examples/smp_page_transfer/kernel_rpi3.elf" "$REPO_ROOT/examples/smp_page_transfer/smp_page_transfer.expected" 5 30
RPI3_SMP_CORES=4 run_hw_test_rpi3 "multi_address_space (rpi3)" "$REPO_ROOT/examples/multi_address_space/kernel_rpi3.elf" "$REPO_ROOT/examples/multi_address_space/multi_address_space.expected" 5 30
run_hw_test_rpi3 "rtc (rpi3)"            "$REPO_ROOT/examples/rtc/kernel_rpi3.elf"            "$REPO_ROOT/examples/rtc/rtc.expected"       5 30
run_hw_test_rpi3 "timer (rpi3)"          "$REPO_ROOT/examples/timer/kernel_rpi3.elf"          "$REPO_ROOT/examples/timer/timer.expected"   5 30
run_hw_test_rpi3_stdin "echo (rpi3)" "$REPO_ROOT/examples/echo/kernel_rpi3.elf" \
    "$REPO_ROOT/examples/echo/echo.expected" "$REPO_ROOT/examples/echo/echo.stdin"
run_hw_test_rpi3_stdin "irq (rpi3)"  "$REPO_ROOT/examples/irq/kernel_rpi3.elf" \
    "$REPO_ROOT/examples/irq/irq.expected" "$REPO_ROOT/examples/irq/irq.stdin"
run_hw_test_rpi3 "preempt (rpi3)"        "$REPO_ROOT/examples/preempt/kernel_rpi3.elf"        "$REPO_ROOT/examples/preempt/preempt.expected"
run_hw_test_rpi3 "semaphore (rpi3)"      "$REPO_ROOT/examples/semaphore/kernel_rpi3.elf"      "$REPO_ROOT/examples/semaphore/semaphore.expected"
run_hw_test_rpi3 "condvar (rpi3)"        "$REPO_ROOT/examples/condvar/kernel_rpi3.elf"        "$REPO_ROOT/examples/condvar/condvar.expected"
run_hw_test_rpi3 "msgqueue (rpi3)"       "$REPO_ROOT/examples/msgqueue/kernel_rpi3.elf"       "$REPO_ROOT/examples/msgqueue/msgqueue.expected"
run_hw_test_rpi3 "watchdog (rpi3)"       "$REPO_ROOT/examples/watchdog/kernel_rpi3.elf"       "$REPO_ROOT/examples/watchdog/watchdog.expected"
run_hw_test_rpi3 "rtos_demo (rpi3)"      "$REPO_ROOT/examples/rtos_demo/kernel_rpi3.elf"      "$REPO_ROOT/examples/rtos_demo/rtos_demo.expected"
run_hw_test_rpi3 "chan_rendezvous (rpi3)" "$REPO_ROOT/examples/chan_rendezvous/kernel_rpi3.elf" "$REPO_ROOT/examples/chan_rendezvous/chan_rendezvous.expected"
# usb_probe pauses for real hardware settle times mid-test --
# lan9514_wait_link() polls up to 50 x 100ms = 5s of real silence
# waiting for PHY autonegotiation against the point-to-point peer, with
# no UART output during the wait. Same idle-quiet-threshold gotcha
# rtc/timer hit above, same fix, but the quiet threshold itself must
# exceed the pause (30 polls = 1.5s was still shorter than the up-to-5s
# real gap and truncated the capture before "eth link: up" arrived):
# 20s max capture, 140 stable polls = 7s quiet threshold.
run_hw_test_rpi3 "usb_probe (rpi3)"      "$REPO_ROOT/examples/usb_probe/kernel_rpi3.elf"      "$REPO_ROOT/examples/usb_probe/usb_probe.expected"   20 140
# usb_msc_probe (rpi3): GitHub issue #145 -- real USB Mass Storage Bulk-Only
# Transport + SCSI-10 round trip against whatever drive is attached to the
# board's USB-A ports. Uses the sdcard-style Python-checked dump instead of
# a static .expected fixture (see run_hw_test_rpi3_usb_msc's own comment) --
# destroys whatever was previously on the drive every run, confirmed
# acceptable for this project's own dedicated test drive.
run_hw_test_rpi3_usb_msc "usb_msc_probe (rpi3)" "$REPO_ROOT/examples/usb_msc_probe/kernel_rpi3.elf" usb_msc_test.py
# fatfs_sdcard (rpi3): GitHub issue #145's own follow-on -- fat12.tkb's
# FAT12 logic wired onto the real USB Mass Storage drive via
# examples/common_rpi3/fat12_usbmsc.tkb, byte-for-byte the same shared
# fatfs_sdcard.tkb source STM32 already runs against its own real SD
# card. Reuses STM32's own fatfs_sdcard.expected fixture unchanged --
# confirmed byte-identical on real hardware, same as every other shared
# example's fixture in this file. Destructive (formats the attached
# drive), same acceptance as usb_msc_probe above. fat_format() performs
# about 128 USB writes without UART output; a real run has occasionally
# paused for more than the old 2s quiet threshold inside that operation.
# Keep the 15s overall ceiling, but require 7s of silence before treating
# the capture as complete so USB-media erase/write latency cannot produce
# a truncated false failure.
run_hw_test_rpi3 "fatfs_sdcard (rpi3)" "$REPO_ROOT/examples/fatfs_sdcard/kernel_rpi3.elf" "$REPO_ROOT/examples/fatfs_sdcard/fatfs_sdcard.expected" 15 140
# rtos_fatfs_sdcard (rpi3): the same FAT12-on-USB-mass-storage work moved
# behind the Simple RTOS task/channel boundary -- byte-for-byte the shared
# rtos_fatfs_sdcard.tkb source and STM32's own .expected fixture. This is
# the regression test for usb_dwc2.tkb's dma_prepare_rx-before-bulk-IN
# (the read corruption it fixes only ever manifested with the RTOS
# scheduler tick running -- see dwc2_bulk_in's own comment). Destructive
# (formats the attached drive), same acceptance as the two tests above.
# Same fat_format() quiet-window requirement as fatfs_sdcard above.
run_hw_test_rpi3 "rtos_fatfs_sdcard (rpi3)" "$REPO_ROOT/examples/rtos_fatfs_sdcard/kernel_rpi3.elf" "$REPO_ROOT/examples/rtos_fatfs_sdcard/rtos_fatfs_sdcard.expected" 15 140

echo ""
echo "rpi3 hardware tests: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
    echo "failed tests:"
    for t in "${FAILED_TESTS[@]}"; do
        echo "  - $t"
    done
    exit 1
fi
