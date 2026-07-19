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

    read_until_quiet "$tmp_drain" "$DRAIN_MAX_SECS" "$DRAIN_STABLE_POLLS" 0
    read_until_quiet "$tmp_out" "$max_secs" "$stable_polls" 1 \
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

    read_until_quiet "$tmp_drain" "$DRAIN_MAX_SECS" "$DRAIN_STABLE_POLLS" 0

    : > "$tmp_out"
    cat "$SERIAL_DEV" > "$tmp_out" 2>/dev/null 9>&- &
    local catpid=$!
    ACTIVE_READER_PID=$catpid
    sleep 0.2
    "$REPO_ROOT/scripts/rpi3_jtag_load.sh" "$elf" > "$load_log" 2>&1
    load_status=$?
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

# Mirrors RPI3_EXAMPLES + RPI3_CHECKSUM_EXAMPLES + RPI3_IRQ_EXAMPLES +
# RPI3_RTC_EXAMPLES in the Makefile -- see examples/common_rpi3/AGENTS.md
# for what's still deliberately excluded
# (preempt/semaphore/condvar/msgqueue/watchdog/rtos_demo need a full
# preemptive scheduler on top of timer interrupts; SD-card-storage
# examples are out of scope entirely). Every .expected/.stdin fixture
# here is reused byte-for-byte from the QEMU/STM32 suites --
# uart_puts/uart_print_* write identical bytes on every HAL, even though
# rtc/timer's underlying time source here (the ARM Generic Timer's
# free-running counter, not a real RTC peripheral) differs -- both
# fixtures only ever check that time advances, never an absolute value.
run_hw_test_rpi3 "start (rpi3)"          "$REPO_ROOT/examples/start/kernel_rpi3.elf"          "$REPO_ROOT/examples/start/start.expected"
run_hw_test_rpi3 "hello (rpi3)"          "$REPO_ROOT/examples/hello/kernel_rpi3.elf"          "$REPO_ROOT/examples/hello/hello.expected"
run_hw_test_rpi3 "print_int (rpi3)"      "$REPO_ROOT/examples/print_int/kernel_rpi3.elf"      "$REPO_ROOT/examples/print_int/print_int.expected"
run_hw_test_rpi3 "print_hex (rpi3)"      "$REPO_ROOT/examples/print_hex/kernel_rpi3.elf"      "$REPO_ROOT/examples/print_hex/print_hex.expected"
run_hw_test_rpi3 "print_ptr (rpi3)"      "$REPO_ROOT/examples/print_ptr/kernel_rpi3.elf"      "$REPO_ROOT/examples/print_ptr/print_ptr.expected"
run_hw_test_rpi3 "mem (rpi3)"            "$REPO_ROOT/examples/mem/kernel_rpi3.elf"            "$REPO_ROOT/examples/mem/mem.expected"
run_hw_test_rpi3 "array (rpi3)"          "$REPO_ROOT/examples/array/kernel_rpi3.elf"          "$REPO_ROOT/examples/array/array.expected"
run_hw_test_rpi3 "fizzbuzz (rpi3)"       "$REPO_ROOT/examples/fizzbuzz/kernel_rpi3.elf"       "$REPO_ROOT/examples/fizzbuzz/fizzbuzz.expected"
run_hw_test_rpi3 "fibonacci (rpi3)"      "$REPO_ROOT/examples/fibonacci/kernel_rpi3.elf"      "$REPO_ROOT/examples/fibonacci/fibonacci.expected"
run_hw_test_rpi3 "bubblesort (rpi3)"     "$REPO_ROOT/examples/bubblesort/kernel_rpi3.elf"     "$REPO_ROOT/examples/bubblesort/bubblesort.expected"
run_hw_test_rpi3 "ringbuf (rpi3)"        "$REPO_ROOT/examples/ringbuf/kernel_rpi3.elf"        "$REPO_ROOT/examples/ringbuf/ringbuf.expected"
run_hw_test_rpi3 "callstack (rpi3)"      "$REPO_ROOT/examples/callstack/kernel_rpi3.elf"      "$REPO_ROOT/examples/callstack/callstack.expected"
run_hw_test_rpi3 "crc8 (rpi3)"           "$REPO_ROOT/examples/crc8/kernel_rpi3.elf"           "$REPO_ROOT/examples/crc8/crc8.expected"
run_hw_test_rpi3 "djb2 (rpi3)"           "$REPO_ROOT/examples/djb2/kernel_rpi3.elf"           "$REPO_ROOT/examples/djb2/djb2.expected"
run_hw_test_rpi3 "bump (rpi3)"           "$REPO_ROOT/examples/bump/kernel_rpi3.elf"           "$REPO_ROOT/examples/bump/bump.expected"
run_hw_test_rpi3 "scheduler (rpi3)"      "$REPO_ROOT/examples/scheduler/kernel_rpi3.elf"      "$REPO_ROOT/examples/scheduler/scheduler.expected"
run_hw_test_rpi3 "struct (rpi3)"         "$REPO_ROOT/examples/struct/kernel_rpi3.elf"         "$REPO_ROOT/examples/struct/struct.expected"
run_hw_test_rpi3 "struct_refined (rpi3)" "$REPO_ROOT/examples/struct_refined/kernel_rpi3.elf" "$REPO_ROOT/examples/struct_refined/struct_refined.expected"
run_hw_test_rpi3 "refined (rpi3)"        "$REPO_ROOT/examples/refined/kernel_rpi3.elf"        "$REPO_ROOT/examples/refined/refined.expected"
run_hw_test_rpi3 "narrow (rpi3)"         "$REPO_ROOT/examples/narrow/kernel_rpi3.elf"         "$REPO_ROOT/examples/narrow/narrow.expected"
run_hw_test_rpi3 "for (rpi3)"            "$REPO_ROOT/examples/for/kernel_rpi3.elf"            "$REPO_ROOT/examples/for/for.expected"
run_hw_test_rpi3 "loop (rpi3)"           "$REPO_ROOT/examples/loop/kernel_rpi3.elf"           "$REPO_ROOT/examples/loop/loop.expected"
run_hw_test_rpi3 "enum (rpi3)"           "$REPO_ROOT/examples/enum/kernel_rpi3.elf"           "$REPO_ROOT/examples/enum/enum.expected"
run_hw_test_rpi3 "nonexhaustive (rpi3)"  "$REPO_ROOT/examples/nonexhaustive/kernel_rpi3.elf"  "$REPO_ROOT/examples/nonexhaustive/nonexhaustive.expected"
run_hw_test_rpi3 "bitops (rpi3)"         "$REPO_ROOT/examples/bitops/kernel_rpi3.elf"         "$REPO_ROOT/examples/bitops/bitops.expected"
run_hw_test_rpi3 "align (rpi3)"          "$REPO_ROOT/examples/align/kernel_rpi3.elf"          "$REPO_ROOT/examples/align/align.expected"
run_hw_test_rpi3 "packed (rpi3)"         "$REPO_ROOT/examples/packed/kernel_rpi3.elf"         "$REPO_ROOT/examples/packed/packed.expected"
run_hw_test_rpi3 "struct_align (rpi3)"   "$REPO_ROOT/examples/struct_align/kernel_rpi3.elf"   "$REPO_ROOT/examples/struct_align/struct_align.expected"
run_hw_test_rpi3 "const_global (rpi3)"   "$REPO_ROOT/examples/const_global/kernel_rpi3.elf"   "$REPO_ROOT/examples/const_global/const_global.expected"
run_hw_test_rpi3 "sizeof_offsetof (rpi3)" "$REPO_ROOT/examples/sizeof_offsetof/kernel_rpi3.elf" "$REPO_ROOT/examples/sizeof_offsetof/sizeof_offsetof.expected"
run_hw_test_rpi3 "inet_checksum (rpi3)"  "$REPO_ROOT/examples/inet_checksum/kernel_rpi3.elf"  "$REPO_ROOT/examples/inet_checksum/inet_checksum.expected"
run_hw_test_rpi3 "ip_parse (rpi3)"       "$REPO_ROOT/examples/ip_parse/kernel_rpi3.elf"       "$REPO_ROOT/examples/ip_parse/ip_parse.expected"
run_hw_test_rpi3 "tcp_parse (rpi3)"      "$REPO_ROOT/examples/tcp_parse/kernel_rpi3.elf"      "$REPO_ROOT/examples/tcp_parse/tcp_parse.expected"
run_hw_test_rpi3 "rtc (rpi3)"            "$REPO_ROOT/examples/rtc/kernel_rpi3.elf"            "$REPO_ROOT/examples/rtc/rtc.expected"       5 30
run_hw_test_rpi3 "timer (rpi3)"          "$REPO_ROOT/examples/timer/kernel_rpi3.elf"          "$REPO_ROOT/examples/timer/timer.expected"   5 30
run_hw_test_rpi3_stdin "echo (rpi3)" "$REPO_ROOT/examples/echo/kernel_rpi3.elf" \
    "$REPO_ROOT/examples/echo/echo.expected" "$REPO_ROOT/examples/echo/echo.stdin"
run_hw_test_rpi3_stdin "irq (rpi3)"  "$REPO_ROOT/examples/irq/kernel_rpi3.elf" \
    "$REPO_ROOT/examples/irq/irq.expected" "$REPO_ROOT/examples/irq/irq.stdin"

echo ""
echo "rpi3 hardware tests: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
    echo "failed tests:"
    for t in "${FAILED_TESTS[@]}"; do
        echo "  - $t"
    done
    exit 1
fi
