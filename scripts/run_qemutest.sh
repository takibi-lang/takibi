#!/usr/bin/env bash
# QEMU integration test runner — called from repo root via: make qemutest
set -euo pipefail

QEMU="qemu-system-aarch64"
QEMU_COMMON="-machine virt -cpu cortex-a53 -nographic -semihosting-config enable=on,target=native"
TIMEOUT=10

PASS=0
FAIL=0

# ANSI colours only when writing to a terminal
if [ -t 1 ]; then
    GRN='\033[32m' RED='\033[31m' RST='\033[0m'
else
    GRN='' RED='' RST=''
fi

# run_test NAME KERNEL EXPECTED [STDIN_FILE]
#
# Runs QEMU with the given kernel, feeds STDIN_FILE (if any) via a named pipe,
# and compares stdout byte-for-byte against EXPECTED.
run_test() {
    local name="$1" kernel="$2" expected="$3" stdin_file="${4:-}"
    local tmp_out
    tmp_out=$(mktemp)

    if [ -n "$stdin_file" ]; then
        # Interactive test: use a named pipe so QEMU and the feeder
        # synchronise automatically — no sleep required.
        local tmp_fifo
        tmp_fifo=$(mktemp -u)
        mkfifo "$tmp_fifo"
        timeout "$TIMEOUT" $QEMU $QEMU_COMMON -kernel "$kernel" \
            < "$tmp_fifo" > "$tmp_out" 2>/dev/null &
        local qpid=$!
        cat "$stdin_file" > "$tmp_fifo"   # blocks until QEMU opens the pipe
        wait "$qpid" 2>/dev/null || true
        rm -f "$tmp_fifo"
    else
        echo | timeout "$TIMEOUT" $QEMU $QEMU_COMMON -kernel "$kernel" \
            > "$tmp_out" 2>/dev/null
    fi

    if diff -q "$expected" "$tmp_out" > /dev/null 2>&1; then
        printf "${GRN}PASS${RST}  %s\n" "$name"
        PASS=$((PASS + 1))
    else
        printf "${RED}FAIL${RST}  %s\n" "$name"
        printf "       expected bytes: %s\n" "$(od -An -c "$expected" | tr -s ' \n' ' ')"
        printf "       got bytes:      %s\n" "$(od -An -c "$tmp_out"  | tr -s ' \n' ' ')"
        FAIL=$((FAIL + 1))
    fi

    rm -f "$tmp_out"
}

# run_test_timed NAME KERNEL EXPECTED MIN_SECS
#
# Like run_test, but also verifies that QEMU ran for at least MIN_SECS seconds.
# Used for delay/timer tests where the output alone cannot prove a real wait occurred.
run_test_timed() {
    local name="$1" kernel="$2" expected="$3" min_secs="$4"
    local tmp_out t0 t1 elapsed output_ok=1 timing_ok=1
    tmp_out=$(mktemp)

    t0=$(date +%s)
    echo | timeout "$TIMEOUT" $QEMU $QEMU_COMMON -kernel "$kernel" \
        > "$tmp_out" 2>/dev/null
    t1=$(date +%s)
    elapsed=$((t1 - t0))

    diff -q "$expected" "$tmp_out" > /dev/null 2>&1 || output_ok=0
    [ "$elapsed" -ge "$min_secs" ]               || timing_ok=0

    if [ "$output_ok" -eq 1 ] && [ "$timing_ok" -eq 1 ]; then
        printf "${GRN}PASS${RST}  %s  (${elapsed}s >= ${min_secs}s)\n" "$name"
        PASS=$((PASS + 1))
    else
        printf "${RED}FAIL${RST}  %s\n" "$name"
        [ "$output_ok" -eq 0 ] && {
            printf "       expected bytes: %s\n" "$(od -An -c "$expected" | tr -s ' \n' ' ')"
            printf "       got bytes:      %s\n" "$(od -An -c "$tmp_out"  | tr -s ' \n' ' ')"
        }
        [ "$timing_ok" -eq 0 ] && \
            printf "       elapsed %ds < required %ds\n" "$elapsed" "$min_secs"
        FAIL=$((FAIL + 1))
    fi

    rm -f "$tmp_out"
}

# run_compile_error_test NAME TKB_FILE ERROR_FILE
#
# コンパイルが失敗し、stderr に ERROR_FILE の内容（部分文字列）が含まれることを確認する。
# QEMU は不要。コンパイラのエラー検出パイプライン全体を統合テストする。
run_compile_error_test() {
    local name="$1" tkb="$2" error_file="$3"
    local tmp_err tmp_obj expected_msg
    tmp_err=$(mktemp)
    tmp_obj=$(mktemp --suffix=.o)
    expected_msg=$(cat "$error_file")

    if dune exec takibi -- "$tkb" --target aarch64-none-elf -o "$tmp_obj" >"$tmp_err" 2>&1; then
        printf "${RED}FAIL${RST}  %s\n" "$name"
        printf "       expected compile error, but compilation succeeded\n"
        FAIL=$((FAIL + 1))
    else
        if grep -qF "$expected_msg" "$tmp_err"; then
            printf "${GRN}PASS${RST}  %s\n" "$name"
            PASS=$((PASS + 1))
        else
            printf "${RED}FAIL${RST}  %s\n" "$name"
            printf "       expected: %s\n" "$expected_msg"
            printf "       got:      %s\n" "$(cat "$tmp_err")"
            FAIL=$((FAIL + 1))
        fi
    fi

    rm -f "$tmp_err" "$tmp_obj"
}

echo "Running compile-error tests (no QEMU required)..."
echo ""

run_compile_error_test "oob_const_read"  examples/oob_const_read/oob_const_read.tkb   examples/oob_const_read/oob_const_read.error
run_compile_error_test "oob_const_write" examples/oob_const_write/oob_const_write.tkb examples/oob_const_write/oob_const_write.error
run_compile_error_test "oob_char_array"  examples/oob_char_array/oob_char_array.tkb   examples/oob_char_array/oob_char_array.error
run_compile_error_test "oob_global"      examples/oob_global/oob_global.tkb           examples/oob_global/oob_global.error
run_compile_error_test "oob_size1"       examples/oob_size1/oob_size1.tkb             examples/oob_size1/oob_size1.error

echo ""
echo "Running QEMU integration tests..."
echo ""

run_test "start"     examples/start/kernel.elf     examples/start/start.expected
run_test "hello"     examples/hello/kernel.elf     examples/hello/hello.expected
run_test "print_int" examples/print_int/kernel.elf examples/print_int/print_int.expected
run_test "echo"      examples/echo/kernel.elf      examples/echo/echo.expected \
                     examples/echo/echo.stdin
run_test "print_hex" examples/print_hex/kernel.elf examples/print_hex/print_hex.expected
run_test "print_ptr" examples/print_ptr/kernel.elf examples/print_ptr/print_ptr.expected
run_test "mem"       examples/mem/kernel.elf       examples/mem/mem.expected
run_test "array"     examples/array/kernel.elf     examples/array/array.expected
run_test "fizzbuzz"  examples/fizzbuzz/kernel.elf  examples/fizzbuzz/fizzbuzz.expected
run_test "fibonacci"  examples/fibonacci/kernel.elf  examples/fibonacci/fibonacci.expected
run_test "bubblesort" examples/bubblesort/kernel.elf examples/bubblesort/bubblesort.expected
run_test "ringbuf"    examples/ringbuf/kernel.elf    examples/ringbuf/ringbuf.expected
run_test "callstack"  examples/callstack/kernel.elf  examples/callstack/callstack.expected
run_test "crc8"       examples/crc8/kernel.elf       examples/crc8/crc8.expected
run_test "djb2"       examples/djb2/kernel.elf       examples/djb2/djb2.expected
run_test "bump"       examples/bump/kernel.elf       examples/bump/bump.expected
run_test_timed "timer" examples/timer/kernel.elf examples/timer/timer.expected 1
run_test_timed "rtc"   examples/rtc/kernel.elf   examples/rtc/rtc.expected     1
run_test       "irq"   examples/irq/kernel.elf   examples/irq/irq.expected \
                       examples/irq/irq.stdin
run_test "scheduler" examples/scheduler/kernel.elf examples/scheduler/scheduler.expected
run_test "preempt"   examples/preempt/kernel.elf   examples/preempt/preempt.expected
run_test "semaphore" examples/semaphore/kernel.elf examples/semaphore/semaphore.expected
run_test "condvar"   examples/condvar/kernel.elf   examples/condvar/condvar.expected
run_test "struct"    examples/struct/kernel.elf    examples/struct/struct.expected
run_test "msgqueue"  examples/msgqueue/kernel.elf  examples/msgqueue/msgqueue.expected
run_test "watchdog" examples/watchdog/kernel.elf examples/watchdog/watchdog.expected

echo ""
if [ "$FAIL" -eq 0 ]; then
    printf "${GRN}All $PASS tests passed.${RST}\n"
else
    printf "${RED}$FAIL test(s) failed${RST} ($PASS passed).\n"
fi

[ "$FAIL" -eq 0 ]
