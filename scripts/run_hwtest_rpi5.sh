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
# WARNING: the USB MSC/FAT12/shell cases deliberately reformat the attached
# USB mass-storage device. Use only the project's sacrificial test drive.
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
# alarms" reasoning as run_hwtest_rpi3.sh's own reset_before_test. MMU,
# GIC/MIP/MSI-X, and RP1 PCIe link/BAR state can persist across a plain SWD
# re-injection (which only overwrites RAM and moves PC), so a full reboot
# avoids depending on every example's bring-up being idempotent.
reset_before_test() {
    local name="$1"
    local reset_log
    reset_log=$(mktemp)
    if ! "$REPO_ROOT/scripts/rpi5_jtag_reset.sh" --resident-image-unchanged > "$reset_log" 2>&1; then
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

# run_hw_test_rpi5_stdin NAME ELF EXPECTED STDIN_FILE [MAX_SECS]
#                           [STABLE_POLLS] [LINE_PACE_SECS]
#
# Bidirectional GPIO14/15 UART test for issue #164. Start capture before SWD
# injection, wait until the kernel's ready banner is visible, then send the
# fixture in one write. A passing exact-output diff proves the application
# made progress only after asynchronous input; echo/irq contain no polling
# receive path.
run_hw_test_rpi5_stdin() {
    local name="$1" elf="$2" expected="$3" stdin_file="$4" \
          max_secs="${5:-$CAPTURE_MAX_SECS}" \
          stable_polls="${6:-$CAPTURE_STABLE_POLLS}" \
          line_pace_secs="${7:-0}"
    local tmp_drain tmp_out load_log load_status size
    tmp_drain=$(mktemp)
    tmp_out=$(mktemp)
    load_log=$(mktemp)

    reset_before_test "$name"
    read_until_quiet "$tmp_drain" "$DRAIN_MAX_SECS" "$DRAIN_STABLE_POLLS" 0

    : > "$tmp_out"
    cat "$SERIAL_DEV" > "$tmp_out" 2>/dev/null 9>&- &
    local catpid=$!
    ACTIVE_READER_PID=$catpid
    sleep 0.2
    if "$REPO_ROOT/scripts/rpi5_jtag_load.sh" "$elf" > "$load_log" 2>&1; then
        load_status=0
    else
        load_status=$?
    fi

    if [ "$load_status" = "0" ]; then
        local max_wait_polls waited=0
        max_wait_polls=$(awk -v m="$max_secs" -v i="$POLL_INTERVAL" 'BEGIN{printf "%d", m/i}')
        while [ "$waited" -lt "$max_wait_polls" ]; do
            sleep "$POLL_INTERVAL"
            size=$(stat -c%s "$tmp_out" 2>/dev/null || echo 0)
            [ "$size" -gt 0 ] && break
            waited=$((waited + 1))
        done
        if [ "$line_pace_secs" = "0" ]; then
            cat "$stdin_file" > "$SERIAL_DEV"
        else
            while IFS= read -r line || [ -n "$line" ]; do
                printf '%s\n' "$line" > "$SERIAL_DEV"
                sleep "$line_pace_secs"
            done < "$stdin_file"
        fi

        local max_polls last_size=-1 stable=0 poll=0
        max_polls=$(awk -v m="$max_secs" -v i="$POLL_INTERVAL" 'BEGIN{printf "%d", m/i}')
        while [ "$poll" -lt "$max_polls" ]; do
            sleep "$POLL_INTERVAL"
            size=$(stat -c%s "$tmp_out" 2>/dev/null || echo 0)
            if [ "$size" = "$last_size" ]; then
                stable=$((stable + 1))
                [ "$stable" -ge "$stable_polls" ] && break
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
        printf "${RED}FAIL${RST}  %s  (SWD injection failed -- loader log follows)\n" "$name"
        sed 's/^/       /' "$load_log"
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$name")
        save_artifact_file "$HWTEST_ARTIFACT_ROOT" "$name" "$tmp_out" uart.log
        preserve_failure_artifacts "$name" "$tmp_out" "$load_log"
        rm -f "$tmp_drain" "$tmp_out" "$load_log"
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
    rm -f "$tmp_drain" "$tmp_out" "$load_log"
}

# Mirrors RPI5_EXAMPLES in the Makefile -- see
# examples/common_rpi5/AGENTS.md for what's still deliberately excluded
# (Ethernet and opt-in destructive storage probes). type_system_suite/
# algorithm_suite are back
# (issue #165,
# examples/common_rpi5/mmu.S) after real hardware testing confirmed both
# pass with the stage-1 MMU enabled. rtc/timer are back (issue #170,
# examples/common_rpi5/rtc.tkb) -- pure CNTPCT_EL0/CNTFRQ_EL0 polling,
# no interrupt/GIC dependency. echo/irq use issue #164's real RP1 UART0
# MSI-X/MIP0/GIC receive path. Every fixture here is reused byte-for-byte
# from the QEMU/STM32/RPi3 suites.
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
RPI5_SMP_CORES=2 run_hw_test_rpi5 "smp_handoff (rpi5)" "$REPO_ROOT/examples/smp_handoff/kernel_rpi5.elf" \
    "$REPO_ROOT/examples/smp_handoff/smp_handoff.expected" 5 30
RPI5_SMP_CORES=2 run_hw_test_rpi5 "smp_slab (rpi5)" "$REPO_ROOT/examples/smp_slab/kernel_rpi5.elf" \
    "$REPO_ROOT/examples/smp_slab/smp_slab.expected" 5 30
run_hw_test_rpi5 "page_pool (rpi5)" "$REPO_ROOT/examples/page_pool/kernel_rpi5.elf" \
    "$REPO_ROOT/examples/page_pool/page_pool.expected"
# MAX_SECS=5/STABLE_POLLS=30 override: rtc/timer wait up to a real
# 1-second ARM Generic Timer tick between prints -- the default ~0.3s
# idle-quiet threshold mistakes that in-test pause for completion and
# truncates the capture, same gotcha run_hwtest_rpi3.sh's own comment
# documents for these exact two examples.
run_hw_test_rpi5 "rtc (rpi5)" "$REPO_ROOT/examples/rtc/kernel_rpi5.elf" \
    "$REPO_ROOT/examples/rtc/rtc.expected" 5 30
run_hw_test_rpi5 "timer (rpi5)" "$REPO_ROOT/examples/timer/kernel_rpi5.elf" \
    "$REPO_ROOT/examples/timer/timer.expected" 5 30
run_hw_test_rpi5_stdin "echo (rpi5)" "$REPO_ROOT/examples/echo/kernel_rpi5.elf" \
    "$REPO_ROOT/examples/echo/echo.expected" "$REPO_ROOT/examples/echo/echo.stdin"
run_hw_test_rpi5_stdin "irq (rpi5)" "$REPO_ROOT/examples/irq/kernel_rpi5.elf" \
    "$REPO_ROOT/examples/irq/irq.expected" "$REPO_ROOT/examples/irq/irq.stdin"
run_hw_test_rpi5 "preempt (rpi5)" "$REPO_ROOT/examples/preempt/kernel_rpi5.elf" \
    "$REPO_ROOT/examples/preempt/preempt.expected"
run_hw_test_rpi5 "semaphore (rpi5)" "$REPO_ROOT/examples/semaphore/kernel_rpi5.elf" \
    "$REPO_ROOT/examples/semaphore/semaphore.expected"
run_hw_test_rpi5 "condvar (rpi5)" "$REPO_ROOT/examples/condvar/kernel_rpi5.elf" \
    "$REPO_ROOT/examples/condvar/condvar.expected"
run_hw_test_rpi5 "msgqueue (rpi5)" "$REPO_ROOT/examples/msgqueue/kernel_rpi5.elf" \
    "$REPO_ROOT/examples/msgqueue/msgqueue.expected"
run_hw_test_rpi5 "watchdog (rpi5)" "$REPO_ROOT/examples/watchdog/kernel_rpi5.elf" \
    "$REPO_ROOT/examples/watchdog/watchdog.expected"
run_hw_test_rpi5 "rtos_demo (rpi5)" "$REPO_ROOT/examples/rtos_demo/kernel_rpi5.elf" \
    "$REPO_ROOT/examples/rtos_demo/rtos_demo.expected"
run_hw_test_rpi5 "chan_rendezvous (rpi5)" "$REPO_ROOT/examples/chan_rendezvous/kernel_rpi5.elf" \
    "$REPO_ROOT/examples/chan_rendezvous/chan_rendezvous.expected"
# el1_smoke (issue #163's own follow-up, EL2->EL1 drop): a separate
# RPi5-specific source (examples/el1_smoke/el1_smoke_rpi5.tkb), but its
# output is byte-for-byte identical to the RPi3 fixture, reused as-is.
run_hw_test_rpi5 "el1_smoke (rpi5)" "$REPO_ROOT/examples/el1_smoke/kernel_rpi5.elf" \
    "$REPO_ROOT/examples/el1_smoke/el1_smoke.expected"
# hvc_smoke: builds directly on el1_smoke's own EL2->EL1 drop, adding
# the EL1->EL2 hvc call boundary. Separate RPi5-specific source, same
# reasoning as el1_smoke above; output byte-for-byte identical to the
# RPi3 fixture.
run_hw_test_rpi5 "hvc_smoke (rpi5)" "$REPO_ROOT/examples/hvc_smoke/kernel_rpi5.elf" \
    "$REPO_ROOT/examples/hvc_smoke/hvc_smoke.expected"
# vm_page_map (GitHub issue #67 Stage 2): dynamic single-page mapping over
# examples/common_rpi5/mmu.S's own 2MB window (0x40000000, not RPi3's
# 0x80000000 -- see that file's header comment). Separate RPi5-specific
# source and minimal core (vm_page_map_rpi5.tkb / vm_page_map_core_rpi5.tkb),
# same reasoning as el1_smoke/hvc_smoke above; the printed page index and
# byte values do not depend on the VA window's address, so output is
# byte-for-byte identical to the RPi3 fixture.
run_hw_test_rpi5 "vm_page_map (rpi5)" "$REPO_ROOT/examples/vm_page_map/kernel_rpi5.elf" \
    "$REPO_ROOT/examples/vm_page_map/vm_page_map.expected"
run_hw_test_rpi5 "two_page_map (rpi5)" "$REPO_ROOT/examples/two_page_map/kernel_rpi5.elf" \
    "$REPO_ROOT/examples/two_page_map/two_page_map.expected"
run_hw_test_rpi5 "process_vm_smoke (rpi5)" "$REPO_ROOT/examples/process_vm_smoke/kernel_rpi5.elf" \
    "$REPO_ROOT/examples/process_vm_smoke/process_vm_smoke.expected"
run_hw_test_rpi5 "vm_context_switch (rpi5)" "$REPO_ROOT/examples/vm_context_switch/kernel_rpi5.elf" \
    "$REPO_ROOT/examples/vm_context_switch/vm_context_switch.expected"
run_hw_test_rpi5 "vm_task_switch (rpi5)" "$REPO_ROOT/examples/vm_task_switch/kernel_rpi5.elf" \
    "$REPO_ROOT/examples/vm_task_switch/vm_task_switch.expected" 5 30
RPI5_SMP_CORES=2 run_hw_test_rpi5 "smp_task_migrate (rpi5)" "$REPO_ROOT/examples/smp_task_migrate/kernel_rpi5.elf" \
    "$REPO_ROOT/examples/smp_task_migrate/smp_task_migrate.expected" 5 30
RPI5_SMP_CORES=2 run_hw_test_rpi5 "page_split_join (rpi5)" "$REPO_ROOT/examples/page_split_join/kernel_rpi5.elf" \
    "$REPO_ROOT/examples/page_split_join/page_split_join.expected" 5 30
RPI5_SMP_CORES=2 run_hw_test_rpi5 "smp_page_transfer (rpi5)" "$REPO_ROOT/examples/smp_page_transfer/kernel_rpi5.elf" \
    "$REPO_ROOT/examples/smp_page_transfer/smp_page_transfer.expected" 5 30
RPI5_SMP_CORES=2 run_hw_test_rpi5 "multi_address_space (rpi5)" "$REPO_ROOT/examples/multi_address_space/kernel_rpi5.elf" \
    "$REPO_ROOT/examples/multi_address_space/multi_address_space.expected" 5 30
run_hw_test_rpi5 "copy_on_write (rpi5)" "$REPO_ROOT/examples/copy_on_write/kernel_rpi5.elf" \
    "$REPO_ROOT/examples/copy_on_write/copy_on_write.expected"
# el0_smoke (GitHub issue #67 Stage 2 follow-up): EL1->EL0 drop + real SVC
# trap boundary, building on el1_smoke's EL2->EL1 drop and vm_page_map's
# dynamic mapping. Separate RPi5-specific source and el0_asm.S (minus
# issue #158's later fork()-specific additions -- not needed here), same
# reasoning as vm_page_map above; the hand-written EL0 payload's own
# printed text does not depend on the VA window's address, so output is
# byte-for-byte identical to the RPi3 fixture.
run_hw_test_rpi5 "el0_smoke (rpi5)" "$REPO_ROOT/examples/el0_smoke/kernel_rpi5.elf" \
    "$REPO_ROOT/examples/el0_smoke/el0_smoke.expected"
# el0_elf_load (GitHub issue #67 Stage 2 follow-up): a real ELF loader fed
# from a real cpio archive. Full GitHub issue #156-equivalent port
# (multi-page ProcessAddressSpace, hvc-based exit() teardown, the same
# ~20-syscall busybox-shell-ready surface RPi3's own current file has --
# see examples/el0_elf_load/el0_elf_load_rpi5.tkb's own header comment).
# Output is now byte-for-byte identical to RPi3's own fixture (including
# the "hvc: process VM reclaimed" line), so both el0_elf_load.expected
# and el0_elf_load.stdin are the SAME shared, target-independent files.
run_hw_test_rpi5_stdin "el0_elf_load (rpi5)" "$REPO_ROOT/examples/el0_elf_load/kernel_rpi5.elf" \
    "$REPO_ROOT/examples/el0_elf_load/el0_elf_load.expected" "$REPO_ROOT/examples/el0_elf_load/el0_elf_load.stdin"
# These three tests intentionally overwrite the attached USB medium. The
# hwcheck-rpi5 contract now matches hwcheck-rpi3: use a sacrificial drive.
run_hw_test_rpi5 "usb_msc_probe (rpi5)" "$REPO_ROOT/examples/usb_msc_probe/kernel_rpi5.elf" \
    "$REPO_ROOT/examples/usb_msc_probe/usb_msc_probe_rpi5.expected" 15 140
run_hw_test_rpi5 "fatfs_sdcard (rpi5)" "$REPO_ROOT/examples/fatfs_sdcard/kernel_rpi5.elf" \
    "$REPO_ROOT/examples/fatfs_sdcard/fatfs_sdcard.expected" 15 140
run_hw_test_rpi5 "rtos_fatfs_sdcard (rpi5)" "$REPO_ROOT/examples/rtos_fatfs_sdcard/kernel_rpi5.elf" \
    "$REPO_ROOT/examples/rtos_fatfs_sdcard/rtos_fatfs_sdcard.expected" 15 140
# The shell formats and seeds the dedicated USB test medium, then runs a
# syscall-heavy busybox script.  Pace complete input lines so RP1 UART0's
# receive path cannot lose a burst while EL0/EL1/EL2 transitions are busy.
run_hw_test_rpi5_stdin "el0_shell (rpi5)" "$REPO_ROOT/examples/el0_shell/kernel_rpi5.elf" \
    "$REPO_ROOT/examples/el0_shell/el0_shell.expected" "$REPO_ROOT/examples/el0_shell/el0_shell.stdin" 25 140 0.15

echo
echo "RPi5 hardware tests: $PASS passed, $FAIL failed"
if [ "$FAIL" -ne 0 ]; then
    printf 'failed: %s\n' "${FAILED_TESTS[*]}"
    exit 1
fi
