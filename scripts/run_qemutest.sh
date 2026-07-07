#!/usr/bin/env bash
# QEMU integration test runner -- called from repo root via: make qemutest
set -euo pipefail

QEMU="qemu-system-aarch64"
QEMU_COMMON="-machine virt -cpu cortex-a53 -nographic -semihosting-config enable=on,target=native"
TIMEOUT=10

# Invoke the built binary directly rather than "dune exec takibi --": under
# `make -j`, this script's own recipe can run concurrently with other Make
# jobs that also touch dune (e.g. "dune test"), and dune's build-directory
# lock file is not safe against concurrent dune invocations (observed:
# "Unexpected contents of build directory global lock file" / spurious
# failures in run_compile_error_test below). The Makefile already ensures
# _build/default/bin/main.exe exists and is current before this script runs.
TAKIBI="_build/default/bin/main.exe"

PASS=0
FAIL=0
FAILED_TESTS=()

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
        # synchronise automatically -- no sleep required.
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
        FAILED_TESTS+=("$name")
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
        FAILED_TESTS+=("$name")
    fi

    rm -f "$tmp_out"
}

# run_compile_error_test NAME TKB_FILE ERROR_FILE [EXTRA_TAKIBI_FLAGS...]
#
# Verifies that compilation fails and that stderr contains the contents of ERROR_FILE
# as a substring. QEMU is not needed. Integration-tests the full compiler error detection pipeline.
# Trailing arguments are passed through to takibi (e.g. --forbid-trap for a
# test that only fails under a specific mode).
run_compile_error_test() {
    local name="$1" tkb="$2" error_file="$3"
    shift 3
    local tmp_err tmp_obj expected_msg
    tmp_err=$(mktemp)
    tmp_obj=$(mktemp --suffix=.o)
    expected_msg=$(cat "$error_file")

    if "$TAKIBI" "$tkb" --target aarch64-none-elf -o "$tmp_obj" "$@" >"$tmp_err" 2>&1; then
        printf "${RED}FAIL${RST}  %s\n" "$name"
        printf "       expected compile error, but compilation succeeded\n"
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$name")
    else
        if grep -qF "$expected_msg" "$tmp_err"; then
            printf "${GRN}PASS${RST}  %s\n" "$name"
            PASS=$((PASS + 1))
        else
            printf "${RED}FAIL${RST}  %s\n" "$name"
            printf "       expected: %s\n" "$expected_msg"
            printf "       got:      %s\n" "$(cat "$tmp_err")"
            FAIL=$((FAIL + 1))
            FAILED_TESTS+=("$name")
        fi
    fi

    rm -f "$tmp_err" "$tmp_obj"
}

# run_forbid_trap_ok_test NAME TKB_FILES...
#
# Verifies that compilation SUCCEEDS under --forbid-trap, i.e. the program
# generates zero runtime trap checks (all array indices / refined casts are
# proven at the type level). Compile-only; QEMU is not needed. The positive
# counterpart of run_compile_error_test's forbid_trap_wrong registration.
run_forbid_trap_ok_test() {
    local name="$1"
    shift
    local tmp_err tmp_obj
    tmp_err=$(mktemp)
    tmp_obj=$(mktemp --suffix=.o)

    if "$TAKIBI" "$@" --target aarch64-none-elf -o "$tmp_obj" --forbid-trap >"$tmp_err" 2>&1; then
        printf "${GRN}PASS${RST}  %s\n" "$name"
        PASS=$((PASS + 1))
    else
        printf "${RED}FAIL${RST}  %s\n" "$name"
        printf "       expected --forbid-trap compile to succeed, got:\n"
        sed 's/^/       /' "$tmp_err"
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$name")
    fi

    rm -f "$tmp_err" "$tmp_obj"
}

# run_virtio_test NAME KERNEL SCRIPT
#
# Launches QEMU with a virtio-net-device backed by a UDP -netdev dgram
# (one UDP datagram == one raw Ethernet frame) and runs the given python
# SCRIPT (e.g. virtio_net_test.py, arp_test.py), which sends/verifies
# frames directly over that socket. Correctness is judged entirely by the
# python script's exit code, not by diffing QEMU's stdout, so the kernel
# is free to print debug output via uart_puts without affecting the
# result. Uses its own timeout (VIRTIO_TIMEOUT) rather than TIMEOUT: the
# python scripts send dozens of frames with a bounded per-frame retry
# loop, which legitimately takes longer than the simple byte-diff tests
# above.
VIRTIO_TIMEOUT=30
run_virtio_test() {
    local name="$1" kernel="$2" script="$3"
    local qemu_log
    qemu_log=$(mktemp)

    timeout "$VIRTIO_TIMEOUT" $QEMU $QEMU_COMMON \
        -global virtio-mmio.force-legacy=on \
        -netdev dgram,id=net0,local.type=inet,local.host=127.0.0.1,local.port=17771,remote.type=inet,remote.host=127.0.0.1,remote.port=17772 \
        -device virtio-net-device,netdev=net0,mac=52:54:00:12:34:56,csum=off,guest_csum=off,gso=off,guest_tso4=off,guest_tso6=off,guest_ufo=off,guest_uso4=off,guest_uso6=off,mrg_rxbuf=off,ctrl_vq=off,mq=off,indirect_desc=off,event_idx=off \
        -kernel "$kernel" > "$qemu_log" 2>&1 &
    local qpid=$!

    local rc=0
    timeout 25 python3 "$(dirname "$0")/$script" || rc=$?

    kill "$qpid" 2>/dev/null || true
    wait "$qpid" 2>/dev/null || true

    if [ "$rc" -eq 0 ]; then
        printf "${GRN}PASS${RST}  %s\n" "$name"
        PASS=$((PASS + 1))
    else
        printf "${RED}FAIL${RST}  %s\n" "$name"
        printf "       qemu output:\n"
        sed 's/^/       /' "$qemu_log"
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$name")
    fi

    rm -f "$qemu_log"
}

# run_no_trap_test NAME KERNEL
#
# Disassembles with llvm-objdump and checks that the count of brk instructions
# (llvm.trap -> AArch64 brk #0x1) is zero. Verifies that array bounds are fully
# proven at the type level.
run_no_trap_test() {
    local name="$1" kernel="$2"
    local count
    count=$(llvm-objdump-19 --disassemble "$kernel" 2>/dev/null | grep -c "brk" || true)
    if [ "$count" -eq 0 ]; then
        printf "${GRN}PASS${RST}  %s  (no brk)\n" "$name"
        PASS=$((PASS + 1))
    else
        printf "${RED}FAIL${RST}  %s  ($count brk instruction(s) -- runtime trap risk)\n" "$name"
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$name")
    fi
}

# run_dwarf_test NAME KERNEL SRC_TKB
#
# Verifies the DWARF line table emitted by a -g build actually resolves an
# address back to the correct source line, using two independent tools so a
# bug in either one alone wouldn't slip through:
#   - llvm-dwarfdump-19 --debug-line: checks SRC_TKB's basename appears in
#     the file_names table (proves the compile unit references the right
#     source file at all).
#   - addr2line, pointed at the address of `app_main` (found via llvm-nm-19):
#     checks the resolved "file:line" is an ABSOLUTE path ending in
#     ":<MAIN_LINE>". Requiring an absolute path guards against the exact
#     bug this check was written for: DIFile directories left relative get
#     silently concatenated onto the compile unit's comp_dir by these tools,
#     e.g. "examples/common/examples/fizzbuzz/fizzbuzz.tkb" instead of
#     ".../examples/fizzbuzz/fizzbuzz.tkb" (see lib/llvm_gen.ml's
#     di_file_for comment for the fix).
# MAIN_LINE (the source line `fn app_main()` is declared on) is passed explicitly
# rather than grepped out of SRC_TKB, so this check fails loudly if fizzbuzz.tkb
# is ever edited without updating it, instead of silently checking the wrong line.
run_dwarf_test() {
    local name="$1" kernel="$2" src_tkb="$3" main_line="$4"
    local src_base main_addr resolved

    if ! llvm-dwarfdump-19 --debug-line "$kernel" 2>/dev/null | grep -qF "name: \"$(basename "$src_tkb")\""; then
        printf "${RED}FAIL${RST}  %s  (%s missing from DWARF file_names table)\n" "$name" "$(basename "$src_tkb")"
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$name")
        return
    fi

    main_addr=$(llvm-nm-19 "$kernel" 2>/dev/null | awk '$3 == "app_main" { print "0x" $1; exit }')
    if [ -z "$main_addr" ]; then
        printf "${RED}FAIL${RST}  %s  (could not find 'app_main' symbol via llvm-nm-19)\n" "$name"
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$name")
        return
    fi

    resolved=$(addr2line -e "$kernel" -f -C "$main_addr" 2>/dev/null | tail -n1)
    if [[ "$resolved" == /* && "$resolved" == *":$main_line" ]]; then
        printf "${GRN}PASS${RST}  %s  (app_main -> %s)\n" "$name" "$resolved"
        PASS=$((PASS + 1))
    else
        printf "${RED}FAIL${RST}  %s  (expected an absolute path ending \":%s\", got \"%s\")\n" \
            "$name" "$main_line" "$resolved"
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$name")
    fi
}

# run_dwarf_var_test NAME KERNEL VARNAME TAG DECL_FILE_SUBSTR DECL_LINE TYPE_NAME
#
# Verifies a parameter/local variable (added to DWARF via gen_func's
# declare_var, see lib/llvm_gen.ml) shows up with the right name/declaration
# site/type. Uses `llvm-dwarfdump-19 --name=VARNAME`, which prints only the
# debug info entries whose DW_AT_name exactly matches VARNAME -- a small,
# targeted query rather than a full-file dump.
#
# Deliberately does NOT diff the whole entry or care about attribute order:
# only 5 substrings are checked, independently, and everything else
# (the DIE's own address, DW_AT_location's register/PC-range content, which
# depends on register allocation and shifts on any unrelated codegen change)
# is ignored. This keeps the test decoupled from llvm-dwarfdump's exact
# textual formatting -- an LLVM version bump that reorders attributes or adds
# a new one won't break this, only an actual regression in what we emit will.
run_dwarf_var_test() {
    local name="$1" kernel="$2" varname="$3" tag="$4" decl_file="$5" decl_line="$6" type_name="$7"
    local out ok=1
    out=$(llvm-dwarfdump-19 --name="$varname" "$kernel" 2>/dev/null)

    echo "$out" | grep -qF "$tag"                                        || ok=0
    echo "$out" | grep "DW_AT_name"      | grep -qF "\"$varname\")"       || ok=0
    echo "$out" | grep "DW_AT_decl_file" | grep -qF "$decl_file"          || ok=0
    echo "$out" | grep "DW_AT_decl_line" | grep -qF "($decl_line)"        || ok=0
    echo "$out" | grep "DW_AT_type"      | grep -qF "\"$type_name\")"     || ok=0

    if [ "$ok" -eq 1 ]; then
        printf "${GRN}PASS${RST}  %s\n" "$name"
        PASS=$((PASS + 1))
    else
        printf "${RED}FAIL${RST}  %s  (llvm-dwarfdump-19 --name=%s did not match expectations)\n" "$name" "$varname"
        printf "%s\n" "$out" | sed 's/^/       /'
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$name")
    fi
}

echo "Running compile-error tests (no QEMU required)..."
echo ""

run_compile_error_test "oob_const_read"  examples/oob_const_read/oob_const_read.tkb   examples/oob_const_read/oob_const_read.error
run_compile_error_test "oob_const_write" examples/oob_const_write/oob_const_write.tkb examples/oob_const_write/oob_const_write.error
run_compile_error_test "oob_char_array"  examples/oob_char_array/oob_char_array.tkb   examples/oob_char_array/oob_char_array.error
run_compile_error_test "oob_global"      examples/oob_global/oob_global.tkb           examples/oob_global/oob_global.error
run_compile_error_test "oob_size1"       examples/oob_size1/oob_size1.tkb             examples/oob_size1/oob_size1.error
run_compile_error_test "refined_param_mismatch"  examples/refined_param_mismatch/refined_param_mismatch.tkb   examples/refined_param_mismatch/refined_param_mismatch.error
run_compile_error_test "refined_return_mismatch" examples/refined_return_mismatch/refined_return_mismatch.tkb examples/refined_return_mismatch/refined_return_mismatch.error
run_compile_error_test "refined_assign_mismatch" examples/refined_assign_mismatch/refined_assign_mismatch.tkb examples/refined_assign_mismatch/refined_assign_mismatch.error
run_compile_error_test "match_nonexhaustive"      examples/match_nonexhaustive/match_nonexhaustive.tkb           examples/match_nonexhaustive/match_nonexhaustive.error
run_compile_error_test "match_nonexhaustive_open" examples/match_nonexhaustive_open/match_nonexhaustive_open.tkb examples/match_nonexhaustive_open/match_nonexhaustive_open.error
run_compile_error_test "enum_cast_wrong_dst" examples/enum_cast_wrong_dst/enum_cast_wrong_dst.tkb examples/enum_cast_wrong_dst/enum_cast_wrong_dst.error
run_compile_error_test "enum_cast_wrong_src" examples/enum_cast_wrong_src/enum_cast_wrong_src.tkb examples/enum_cast_wrong_src/enum_cast_wrong_src.error
run_compile_error_test "ptr_cast_wrong"      examples/ptr_cast_wrong/ptr_cast_wrong.tkb           examples/ptr_cast_wrong/ptr_cast_wrong.error
run_compile_error_test "const_global_wrong"  examples/const_global_wrong/const_global_wrong.tkb   examples/const_global_wrong/const_global_wrong.error
run_compile_error_test "forbid_trap_wrong"   examples/forbid_trap_wrong/forbid_trap_wrong.tkb     examples/forbid_trap_wrong/forbid_trap_wrong.error --forbid-trap
run_forbid_trap_ok_test "forbid_trap_ok"     examples/forbid_trap_ok/forbid_trap_ok.tkb
run_forbid_trap_ok_test "forbid_trap_slice"  examples/common/uart.tkb examples/common/print.tkb examples/slice/slice.tkb
run_forbid_trap_ok_test "forbid_trap_foreach" examples/common/uart.tkb examples/common/print.tkb examples/foreach/foreach.tkb
run_forbid_trap_ok_test "forbid_trap_http_server" examples/common/uart.tkb examples/common/print.tkb examples/common/gic.tkb examples/common/virtio_mmio.tkb examples/common/netconfig.tkb examples/common/inet_checksum.tkb examples/common/netutil.tkb examples/http_server/http_server.tkb
run_forbid_trap_ok_test "forbid_trap_arp_reply" examples/common/uart.tkb examples/common/print.tkb examples/common/gic.tkb examples/common/virtio_mmio.tkb examples/common/netconfig.tkb examples/common/netutil.tkb examples/arp_reply/arp_reply.tkb
run_forbid_trap_ok_test "forbid_trap_icmp_echo" examples/common/uart.tkb examples/common/print.tkb examples/common/gic.tkb examples/common/virtio_mmio.tkb examples/common/netconfig.tkb examples/common/inet_checksum.tkb examples/common/netutil.tkb examples/icmp_echo/icmp_echo.tkb
run_forbid_trap_ok_test "forbid_trap_ip_parse" examples/common/uart.tkb examples/common/print.tkb examples/common/inet_checksum.tkb examples/common/netutil.tkb examples/ip_parse/ip_parse.tkb
run_forbid_trap_ok_test "forbid_trap_tcp_echo" examples/common/uart.tkb examples/common/print.tkb examples/common/gic.tkb examples/common/virtio_mmio.tkb examples/common/netconfig.tkb examples/common/inet_checksum.tkb examples/common/netutil.tkb examples/tcp_echo/tcp_echo.tkb
run_forbid_trap_ok_test "forbid_trap_tcp_parse" examples/common/uart.tkb examples/common/print.tkb examples/common/inet_checksum.tkb examples/common/netutil.tkb examples/tcp_parse/tcp_parse.tkb

echo ""
echo "Running no-trap checks (brk must be zero in these kernels)..."
echo ""

# Examples whose bounds should be fully proven at the type level. If brk appears, review the type annotations.
for e in start hello echo print_int print_hex print_ptr mem array fizzbuzz fibonacci \
          bubblesort ringbuf callstack crc8 djb2 bump timer rtc irq scheduler preempt \
          semaphore condvar struct msgqueue watchdog refined narrow for loop enum nonexhaustive bitops align packed struct_align const_global sizeof_offsetof int64 net_echo arp_reply inet_checksum ip_parse icmp_echo tcp_parse tcp_echo http_server; do
# enum (P4c): Color was made NON-EXHAUSTIVE (`_;`) since its one cast site
# (`raw as Color`) has no static evidence bounding raw to {0,1,2} -- see
# CLAUDE.md's P4c section. No trap at all now (round-trip guaranteed).
# ip_parse (P4c-2): ihl is clamped via `min(ihl, 20)`, provably bounding
# the checksum span against pkt's actual capacity regardless of the wire
# byte's value -- see ip_parse.tkb's comment.
# tcp_parse (P4c, revised): rather than assert the residual check away,
# ip_total_len is now VALIDATED (`if (ip_total_len >= ihl && ip_total_len
# <= 40)`) before being trusted -- what any real binary parser needs to do
# regardless of --forbid-trap. Once narrowed, tcp_len's Sub-derived range
# and the same-base rule close the checksum span outright, no unsafe
# needed. See tcp_parse.tkb's comment.
# tcp_echo (P4c-1): its two data-echo sites are wrapped in
# `unsafe { ... }` (documented, evidence-backed assertions -- see
# tcp_echo.tkb's comments) rather than left as silent runtime checks.
    run_no_trap_test "$e (no-trap)" "examples/$e/kernel.elf"
done

echo ""
echo "Running DWARF debug-info check (-g build)..."
echo ""

run_dwarf_test "fizzbuzz (dwarf)" examples/fizzbuzz/kernel.debug.elf examples/fizzbuzz/fizzbuzz.tkb 3

FIB_DEBUG_ELF=examples/fibonacci/kernel.debug.elf
run_dwarf_var_test "fibonacci a (dwarf var)"   "$FIB_DEBUG_ELF" a   DW_TAG_variable          fibonacci.tkb 4 i32
run_dwarf_var_test "fibonacci b (dwarf var)"   "$FIB_DEBUG_ELF" b   DW_TAG_variable          fibonacci.tkb 5 i32
run_dwarf_var_test "fibonacci tmp (dwarf var)" "$FIB_DEBUG_ELF" tmp DW_TAG_variable          fibonacci.tkb 6 i32
run_dwarf_var_test "uart_putc c (dwarf param)" "$FIB_DEBUG_ELF" c   DW_TAG_formal_parameter  uart.tkb      1 u8

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
run_test "refined"  examples/refined/kernel.elf  examples/refined/refined.expected
run_test "narrow"   examples/narrow/kernel.elf   examples/narrow/narrow.expected
run_test "for"      examples/for/kernel.elf      examples/for/for.expected
run_test "loop"     examples/loop/kernel.elf     examples/loop/loop.expected
run_test "enum"          examples/enum/kernel.elf          examples/enum/enum.expected
run_test "nonexhaustive" examples/nonexhaustive/kernel.elf examples/nonexhaustive/nonexhaustive.expected
run_test "bitops"        examples/bitops/kernel.elf        examples/bitops/bitops.expected
run_test "align"         examples/align/kernel.elf         examples/align/align.expected
run_test "packed"        examples/packed/kernel.elf        examples/packed/packed.expected
run_test "struct_align"  examples/struct_align/kernel.elf  examples/struct_align/struct_align.expected
run_test "const_global"  examples/const_global/kernel.elf  examples/const_global/const_global.expected
run_test "sizeof_offsetof" examples/sizeof_offsetof/kernel.elf examples/sizeof_offsetof/sizeof_offsetof.expected
run_test "slice"         examples/slice/kernel.elf         examples/slice/slice.expected
run_test "foreach"       examples/foreach/kernel.elf       examples/foreach/foreach.expected
run_test "int64"         examples/int64/kernel.elf         examples/int64/int64.expected
run_test "inet_checksum" examples/inet_checksum/kernel.elf examples/inet_checksum/inet_checksum.expected
run_test "ip_parse"      examples/ip_parse/kernel.elf      examples/ip_parse/ip_parse.expected
run_test "tcp_parse"     examples/tcp_parse/kernel.elf     examples/tcp_parse/tcp_parse.expected
run_virtio_test "net_echo"   examples/net_echo/kernel.elf   virtio_net_test.py
run_virtio_test "arp_reply"  examples/arp_reply/kernel.elf  arp_test.py
run_virtio_test "icmp_echo"  examples/icmp_echo/kernel.elf  icmp_echo_test.py
run_virtio_test "tcp_echo"   examples/tcp_echo/kernel.elf   tcp_echo_test.py
run_virtio_test "http_server" examples/http_server/kernel.elf http_server_test.py

echo ""
if [ "$FAIL" -eq 0 ]; then
    printf "${GRN}All $PASS tests passed.${RST}\n"
else
    printf "${RED}$FAIL test(s) failed${RST} ($PASS passed).\n"
    printf "${RED}Failed:${RST}"
    for t in "${FAILED_TESTS[@]}"; do
        printf "  %s" "$t"
    done
    printf "\n"
fi

[ "$FAIL" -eq 0 ]
