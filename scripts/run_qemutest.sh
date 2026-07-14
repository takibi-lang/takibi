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
HOST_ONLY="${1:-}"
HOST_ONLY_NAME="${2:-}"

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
# Verifies that compilation fails, stderr contains each non-empty line in
# ERROR_FILE as a diagnostic substring, and at least one diagnostic includes
# a source location. QEMU is not needed. Integration-tests the full compiler
# error detection pipeline while keeping ERROR_FILE stable against line-number
# churn in the negative fixture source.
# Trailing arguments are passed through to takibi (e.g. --forbid-trap for a
# test that only fails under a specific mode).
run_compile_error_test() {
    local name="$1" tkb="$2" error_file="$3"
    shift 3
    local tmp_err tmp_obj
    tmp_err=$(mktemp)
    tmp_obj=$(mktemp --suffix=.o)

    if "$TAKIBI" "$tkb" --target aarch64-none-elf -o "$tmp_obj" "$@" >"$tmp_err" 2>&1; then
        printf "${RED}FAIL${RST}  %s\n" "$name"
        printf "       expected compile error, but compilation succeeded\n"
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$name")
    else
        local msg_ok=1 loc_ok=1 expected_line
        while IFS= read -r expected_line || [ -n "$expected_line" ]; do
            if [ -n "$expected_line" ] && ! grep -qF "$expected_line" "$tmp_err"; then
                msg_ok=0
                break
            fi
        done < "$error_file"
        if ! grep -Eq '^File "[^"]+", line [0-9]+, character [0-9]+: ' "$tmp_err"; then
            loc_ok=0
        fi

        if [ "$msg_ok" -eq 1 ] && [ "$loc_ok" -eq 1 ]; then
            printf "${GRN}PASS${RST}  %s\n" "$name"
            PASS=$((PASS + 1))
        else
            printf "${RED}FAIL${RST}  %s\n" "$name"
            if [ "$msg_ok" -ne 1 ]; then
                printf "       expected diagnostic substring: %s\n" "$expected_line"
            fi
            if [ "$loc_ok" -ne 1 ]; then
                printf "       expected at least one source location diagnostic: File \"...\", line N, character M: ...\n"
            fi
            printf "       got:\n"
            sed 's/^/       /' "$tmp_err"
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

# run_linux_binary_test NAME BINARY EXPECTED
#
# Executes a host Linux/AMD64 user-space Takibi binary and diffs stdout against
# EXPECTED. QEMU is not involved, but this lives in the same harness as the
# compile-only tests so `make check` gets one coloured PASS/FAIL stream.
run_linux_binary_test() {
    local name="$1" binary="$2" expected="$3"
    local tmp_out
    tmp_out=$(mktemp)

    if "$binary" > "$tmp_out"; then
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
    else
        local status=$?
        printf "${RED}FAIL${RST}  %s\n" "$name"
        printf "       process exited with status %d\n" "$status"
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$name")
    fi

    rm -f "$tmp_out"
}

# run_inline_optimizer_test NAME OBJECT
#
# Verifies the explicit `inline fn` contract on a purpose-built object:
# inline_helper must have no call relocation, while normal_helper must still
# have one. This avoids coupling optimizer regression coverage to a larger
# example's private helper names.
run_inline_optimizer_test() {
    local name="$1" obj="$2"
    local objdump_out nm_out ok=1
    objdump_out=$(mktemp)
    nm_out=$(mktemp)

    llvm-objdump-19 -dr "$obj" > "$objdump_out"
    if grep -Eq 'R_AARCH64_CALL26[[:space:]]+inline_helper$' "$objdump_out"; then
        ok=0
        printf "${RED}FAIL${RST}  %s\n" "$name"
        printf "       inline_helper was not inlined despite inline fn\n"
    elif ! grep -Eq 'R_AARCH64_CALL26[[:space:]]+normal_helper$' "$objdump_out"; then
        ok=0
        printf "${RED}FAIL${RST}  %s\n" "$name"
        printf "       normal_helper was unexpectedly inlined without inline fn\n"
    else
        llvm-nm-19 --undefined-only "$obj" > "$nm_out"
        if grep -Eq '[[:space:]]U[[:space:]]+(memcpy|memset|memmove|bzero)$' "$nm_out"; then
            ok=0
            printf "${RED}FAIL${RST}  %s\n" "$name"
            printf "       optimizer introduced a libc memory-call dependency\n"
            sed 's/^/       /' "$nm_out"
        fi
    fi

    if [ "$ok" -eq 1 ]; then
        printf "${GRN}PASS${RST}  %s\n" "$name"
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$name")
    fi

    rm -f "$objdump_out" "$nm_out"
}

run_host_integration_tests() {
    local only="${1:-}"
    if [ -z "$only" ] || [ "$only" = "linux_hello" ]; then
        run_linux_binary_test "linux_hello (linux amd64)" examples/linux_hello/linux_hello.linux examples/linux_hello/linux_hello.expected
    fi
    if [ -z "$only" ] || [ "$only" = "inline_check" ]; then
        run_inline_optimizer_test "inline_check" examples/inline_check/inline_check.o
    fi
}

# run_fatfs_test NAME KERNEL EXPECTED MTOOLS_SCRIPT
#
# Like run_test (diffs QEMU's stdout against EXPECTED), but also:
# - seeds the scratch dir with a FAT image built by REAL mformat/mcopy (not
#   by fatfs.tkb) before QEMU even starts, containing one file (SEED.TXT),
#   so fatfs.tkb's load_seed_from_host()+fat_open(FA_READ) is exercised
#   against genuinely independent, third-party-written interop, not just
#   its own round trip. mformat's flags are forced to match fatfs.tkb's
#   fixed layout constants exactly (SECTOR_SIZE=512, TOTAL_SECTORS=128,
#   1 sector/cluster, RESERVED_SECTORS=1, NUM_FATS=2, FAT_SIZE_SECTORS=1
#   sector, ROOT_ENTRY_COUNT=16) -- fatfs.tkb doesn't parse the on-disk BPB
#   dynamically (see its header comment), so the seed image's geometry must
#   line up exactly. mtools' `-r`/`-L`/etc. flags are NOT 1:1 with these
#   field values (e.g. `-r 1` -> 16 root entries, confirmed empirically),
#   see the flags below.
# - verifies the FAT12 disk image the kernel wrote out via ARM semihosting
#   (fatfs.tkb's dump_disk_to_host(), landing in QEMU's cwd as
#   "fatfs_disk.img"): QEMU is run from that same scratch directory so both
#   images have a known location, then MTOOLS_SCRIPT hands the dumped image
#   to the host's `mtools` (mdir/mcopy) -- an independent oracle that the
#   produced image is a spec-valid, correctly-populated FAT12 volume, not
#   just that fatfs.tkb's own status prints claim success.
run_fatfs_test() {
    local name="$1" kernel="$2" expected="$3" mtools_script="$4"
    local kernel_abs tmp_dir tmp_out ok=1
    kernel_abs="$(pwd)/$kernel"
    tmp_dir=$(mktemp -d)
    tmp_out=$(mktemp)

    printf 'hello from mtools seed!\r\n' > "$tmp_dir/seedfile.txt"
    mformat -C -i "$tmp_dir/fatfs_seed.img" -t 2 -h 2 -n 32 -c 1 -r 1 -L 1 :: > /dev/null
    mcopy -i "$tmp_dir/fatfs_seed.img" "$tmp_dir/seedfile.txt" ::SEED.TXT

    ( cd "$tmp_dir" && echo | timeout "$TIMEOUT" $QEMU $QEMU_COMMON -kernel "$kernel_abs" > "$tmp_out" 2>/dev/null )

    if ! diff -q "$expected" "$tmp_out" > /dev/null 2>&1; then
        printf "${RED}FAIL${RST}  %s (output mismatch)\n" "$name"
        printf "       expected bytes: %s\n" "$(od -An -c "$expected" | tr -s ' \n' ' ')"
        printf "       got bytes:      %s\n" "$(od -An -c "$tmp_out"  | tr -s ' \n' ' ')"
        ok=0
    fi

    if [ "$ok" -eq 1 ] && ! python3 "$(dirname "$0")/$mtools_script" "$tmp_dir/fatfs_disk.img"; then
        printf "${RED}FAIL${RST}  %s (mtools verification failed)\n" "$name"
        ok=0
    fi

    if [ "$ok" -eq 1 ]; then
        printf "${GRN}PASS${RST}  %s\n" "$name"
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$name")
    fi

    rm -f "$tmp_out"
    rm -rf "$tmp_dir"
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

# run_dwarf_gdb_global_set_test NAME KERNEL EXPECTED
#
# Exercises the part llvm-dwarfdump-only checks cannot cover: GDB must be
# able to print typed Takibi globals, display enum/struct/slice types, write a
# struct member through `set variable`, and have that write affect subsequent
# target behavior. The fixture prints dwarf_global_pair.count from app_main;
# GDB rewrites it at the app_main breakpoint, then QEMU should print the new
# value.
run_dwarf_gdb_global_set_test() {
    local name="$1" kernel="$2" expected="$3"
    local qemu_out gdb_out gdb_norm gdb_diff port qpid ok=1

    if ! command -v gdb-multiarch >/dev/null 2>&1; then
        printf "${RED}FAIL${RST}  %s  (gdb-multiarch not found)\n" "$name"
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$name")
        return
    fi

    qemu_out=$(mktemp)
    gdb_out=$(mktemp)
    gdb_norm=$(mktemp)
    gdb_diff=$(mktemp)
    port=$((23000 + RANDOM % 1000))

    $QEMU $QEMU_COMMON -S -gdb "tcp::$port" -kernel "$kernel" > "$qemu_out" 2>&1 &
    qpid=$!

    local ready=0
    for _ in $(seq 1 50); do
        if gdb-multiarch -q -batch "$kernel" \
              -ex "target remote :$port" -ex "disconnect" >/dev/null 2>&1; then
            ready=1
            break
        fi
        sleep 0.1
    done

    if [ "$ready" -ne 1 ]; then
        ok=0
        printf "gdbstub did not become ready\n" > "$gdb_out"
    else
        timeout "$TIMEOUT" gdb-multiarch -q -batch "$kernel" \
            -ex "target remote :$port" \
            -ex "break app_main" \
            -ex "break examples/dwarf_debug/dwarf_debug.tkb:38" \
            -ex "break dwarf_args_probe" \
            -ex "break examples/dwarf_debug/dwarf_debug.tkb:52" \
            -ex "break examples/dwarf_debug/dwarf_debug.tkb:59" \
            -ex "break examples/dwarf_debug/dwarf_debug.tkb:67" \
            -ex "break examples/dwarf_debug/dwarf_debug.tkb:73" \
            -ex "break examples/dwarf_debug/dwarf_debug.tkb:88" \
            -ex "break examples/dwarf_debug/dwarf_debug.tkb:93" \
            -ex "break examples/dwarf_debug/dwarf_debug.tkb:97" \
            -ex "break examples/dwarf_debug/dwarf_debug.tkb:103" \
            -ex "break dwarf_tuple_stop" \
            -ex "continue" \
            -ex "p dwarf_global_state" \
            -ex "p dwarf_global_pair" \
            -ex "ptype dwarf_global_slice" \
            -ex "set variable dwarf_global_pair.count = 99" \
            -ex "p dwarf_global_pair" \
            -ex "echo DBG_STEP\\n" \
            -ex "step" \
            -ex "echo DBG_BT\\n" \
            -ex "bt" \
            -ex "echo DBG_NEXT\\n" \
            -ex "next" \
            -ex "continue" \
            -ex "p flags" \
            -ex "p seq" \
            -ex "p ack" \
            -ex "p tcp_len" \
            -ex "p tcp_hdr_len" \
            -ex "echo DBG_FRAME\\n" \
            -ex "p frame" \
            -ex "p frame.ptr" \
            -ex "p frame.len" \
            -ex "echo DBG_PAIR_SNAPSHOT\\n" \
            -ex "p pair_snapshot" \
            -ex "echo DBG_ARRAY_NESTED\\n" \
            -ex "p *local_words@3" \
            -ex "p local_words[0]" \
            -ex "p nested_snapshot.pair" \
            -ex "p *nested_snapshot.words@2" \
            -ex "p nested_snapshot.marker" \
            -ex "continue" \
            -ex "stepi" \
            -ex "stepi" \
            -ex "stepi" \
            -ex "stepi" \
            -ex "stepi" \
            -ex "stepi" \
            -ex "stepi" \
            -ex "stepi" \
            -ex "echo DBG_ARGS\\n" \
            -ex "p arg_pair" \
            -ex "p arg_frame" \
            -ex "p arg_frame.len" \
            -ex "bt" \
            -ex "continue" \
            -ex "echo DBG_IF_LOCAL\\n" \
            -ex "p if_local" \
            -ex "bt" \
            -ex "continue" \
            -ex "echo DBG_LOOP_LOCAL\\n" \
            -ex "p loop_local" \
            -ex "p loop_i" \
            -ex "bt" \
            -ex "continue" \
            -ex "echo DBG_ELSE_LOCAL\\n" \
            -ex "p else_local" \
            -ex "bt" \
            -ex "continue" \
            -ex "echo DBG_MATCH_LOCAL\\n" \
            -ex "p match_local" \
            -ex "bt" \
            -ex "continue" \
            -ex "echo DBG_MATCH_WILD_LOCAL\\n" \
            -ex "p match_wild_seen" \
            -ex "bt" \
            -ex "continue" \
            -ex "echo DBG_BLOCK_LOCAL\\n" \
            -ex "p block_local" \
            -ex "bt" \
            -ex "continue" \
            -ex "echo DBG_FOR_LOCAL\\n" \
            -ex "p for_local" \
            -ex "bt" \
            -ex "continue" \
            -ex "echo DBG_FOREACH_LOCAL\\n" \
            -ex "p foreach_local" \
            -ex "bt" \
            -ex "continue" \
            -ex "echo DBG_TUPLE_LOCAL\\n" \
            -ex "p tuple_stop_arg" \
            -ex "select-frame 1" \
            -ex "p tuple_ok" \
            -ex "p tuple_value" \
            -ex "p tuple_total" \
            -ex "bt" \
            -ex "continue" \
            > "$gdb_out" 2>&1 || ok=0
    fi

    for _ in $(seq 1 50); do
        if ! kill -0 "$qpid" 2>/dev/null; then
            break
        fi
        sleep 0.1
    done
    if kill -0 "$qpid" 2>/dev/null; then
        ok=0
        kill "$qpid" 2>/dev/null || true
    fi
    wait "$qpid" 2>/dev/null || true

    {
        sed -n 's/^\$[0-9][0-9]* = \(DwarfState::Busy\)$/p dwarf_global_state => \1/p' "$gdb_out"
        sed -n '0,/count = 42/s/^\$[0-9][0-9]* = \({state = DwarfState::Idle, count = 42}\)$/p dwarf_global_pair before => \1/p' "$gdb_out"
        awk '
          /^type = struct \[u8; 4\.\.\] \{$/ {
            print "ptype dwarf_global_slice => struct [u8; 4..] {"
            in_block = 1
            next
          }
          in_block {
            print
            if ($0 == "}") in_block = 0
          }
        ' "$gdb_out"
        awk '
          /^DBG_FRAME$/ { exit }
          !done && /^\$[0-9][0-9]* = \{state = DwarfState::Idle, count = 99\}$/ {
            print "p dwarf_global_pair after => {state = DwarfState::Idle, count = 99}"
            done = 1
          }
        ' "$gdb_out"
        awk '
          /^DBG_STEP$/ { in_step = 1; next }
          in_step && /^dwarf_locals_probe \(\) at .*dwarf_debug\.tkb:27$/ {
            print "step => dwarf_locals_probe:27"
            in_step = 0
          }
        ' "$gdb_out"
        awk '
          /^DBG_BT$/ { in_bt = 1; next }
          /^DBG_NEXT$/ { in_bt = 0 }
          in_bt && /^#0  dwarf_locals_probe \(\) at .*dwarf_debug\.tkb:27$/ {
            print "bt locals #0 => dwarf_locals_probe:27"
          }
          in_bt && /^#1  .* in app_main \(\) at .*dwarf_debug\.tkb:123$/ {
            print "bt locals #1 => app_main:123"
          }
        ' "$gdb_out"
        awk '
          /^DBG_NEXT$/ { in_next = 1; next }
          in_next && /^28[[:space:]]+let seq:/ {
            print "next => dwarf_locals_probe:28"
            in_next = 0
          }
        ' "$gdb_out"
        sed -n 's/^\$[0-9][0-9]* = 18.*$/p flags => 18/p' "$gdb_out"
        sed -n 's/^\$[0-9][0-9]* = 287454020$/p seq => 287454020/p' "$gdb_out"
        sed -n 's/^\$[0-9][0-9]* = 1432778632$/p ack => 1432778632/p' "$gdb_out"
        sed -n 's/^\$[0-9][0-9]* = 40$/p tcp_len => 40/p' "$gdb_out"
        sed -n 's/^\$[0-9][0-9]* = 20$/p tcp_hdr_len => 20/p' "$gdb_out"
        awk '
          /^DBG_FRAME$/ { in_frame = 1; next }
          in_frame == 1 && /^\$[0-9][0-9]* = \{ptr = 0x[0-9a-f][0-9a-f]*, len = 0\}$/ {
            line = $0
            sub(/^\$[0-9][0-9]* = /, "p frame => ", line)
            print line
            in_frame = 2
            next
          }
          in_frame == 2 && /^\$[0-9][0-9]* = \(u8 \*\) 0x[0-9a-f][0-9a-f]*$/ {
            line = $0
            sub(/^\$[0-9][0-9]* = \(u8 \*\) /, "p frame.ptr => ", line)
            print line
            in_frame = 3
            next
          }
          in_frame == 3 && /^\$[0-9][0-9]* = 0$/ {
            print "p frame.len => 0"
            in_frame = 0
          }
        ' "$gdb_out"
        awk '
          /^DBG_PAIR_SNAPSHOT$/ { in_pair = 1; next }
          in_pair && /^\$[0-9][0-9]* = \{state = DwarfState::Idle, count = 123\}$/ {
            print "p pair_snapshot => {state = DwarfState::Idle, count = 123}"
            in_pair = 0
          }
        ' "$gdb_out"
        awk '
          /^DBG_ARRAY_NESTED$/ { in_agg = 1; next }
          /^DBG_ARGS$/ { in_agg = 0 }
          in_agg && /^\$[0-9][0-9]* = \{7, 8, 9\}$/ {
            print "p *local_words@3 => {7, 8, 9}"
          }
          in_agg && /^\$[0-9][0-9]* = 7$/ {
            print "p local_words[0] => 7"
          }
          in_agg && /^\$[0-9][0-9]* = \{state = DwarfState::Busy, count = 88\}$/ {
            print "p nested_snapshot.pair => {state = DwarfState::Busy, count = 88}"
          }
          in_agg && /^\$[0-9][0-9]* = \{10, 20\}$/ {
            print "p *nested_snapshot.words@2 => {10, 20}"
          }
          in_agg && /^\$[0-9][0-9]* = 305419896$/ {
            print "p nested_snapshot.marker => 305419896"
          }
        ' "$gdb_out"
        awk '
          /^DBG_ARGS$/ { in_args = 1; next }
          in_args && /^\$[0-9][0-9]* = \{state = DwarfState::Idle, count = 99\}$/ {
            print "p arg_pair => {state = DwarfState::Idle, count = 99}"
          }
          in_args && /^\$[0-9][0-9]* = \{ptr = 0x[0-9a-f][0-9a-f]*, len = 0\}$/ {
            line = $0
            sub(/^\$[0-9][0-9]* = /, "p arg_frame => ", line)
            print line
          }
          in_args && /^\$[0-9][0-9]* = 0$/ {
            print "p arg_frame.len => 0"
          }
          in_args && /^#0  .*dwarf_args_probe .*dwarf_debug\.tkb:42$/ {
            print "bt args #0 => dwarf_args_probe:42"
          }
          in_args && /^#1  .* in app_main \(\) at .*dwarf_debug\.tkb:124$/ {
            print "bt args #1 => app_main:124"
            in_args = 0
          }
        ' "$gdb_out"
        awk '
          /^DBG_IF_LOCAL$/ { in_if = 1; next }
          /^DBG_LOOP_LOCAL$/ { in_if = 0 }
          in_if && /^\$[0-9][0-9]* = 201$/ {
            print "p if_local => 201"
          }
          in_if && /^#0  dwarf_scope_probe .* at .*dwarf_debug\.tkb:52$/ {
            print "bt if #0 => dwarf_scope_probe:52"
          }
        ' "$gdb_out"
        awk '
          /^DBG_LOOP_LOCAL$/ { in_loop = 1; next }
          /^DBG_ELSE_LOCAL$/ { in_loop = 0 }
          in_loop && /^\$[0-9][0-9]* = 202$/ {
            print "p loop_local => 202"
          }
          in_loop && /^#0  dwarf_scope_probe .* at .*dwarf_debug\.tkb:59$/ {
            print "bt loop #0 => dwarf_scope_probe:59"
          }
        ' "$gdb_out"
        awk '
          /^DBG_ELSE_LOCAL$/ { in_else = 1; next }
          /^DBG_MATCH_LOCAL$/ { in_else = 0 }
          in_else && /^\$[0-9][0-9]* = 208$/ {
            print "p else_local => 208"
          }
          in_else && /^#0  dwarf_scope_probe .* at .*dwarf_debug\.tkb:69$/ {
            print "bt else #0 => dwarf_scope_probe:69"
          }
        ' "$gdb_out"
        awk '
          /^DBG_MATCH_LOCAL$/ { in_match = 1; next }
          /^DBG_MATCH_WILD_LOCAL$/ { in_match = 0 }
          in_match && /^\$[0-9][0-9]* = 203$/ {
            print "p match_local => 203"
          }
          in_match && /^#0  dwarf_scope_probe .* at .*dwarf_debug\.tkb:73$/ {
            print "bt match #0 => dwarf_scope_probe:73"
            in_match = 0
          }
        ' "$gdb_out"
        awk '
          /^DBG_MATCH_WILD_LOCAL$/ { in_wild = 1; next }
          /^DBG_BLOCK_LOCAL$/ { in_wild = 0 }
          in_wild && /^\$[0-9][0-9]* = 204$/ {
            print "p match_wild_seen => 204"
          }
          in_wild && /^#0  dwarf_scope_probe .* at .*dwarf_debug\.tkb:92$/ {
            print "bt match wild #0 => dwarf_scope_probe:92"
          }
        ' "$gdb_out"
        awk '
          /^DBG_BLOCK_LOCAL$/ { in_block = 1; next }
          /^DBG_FOR_LOCAL$/ { in_block = 0 }
          in_block && /^\$[0-9][0-9]* = 207$/ {
            print "p block_local => 207"
          }
          in_block && /^#0  dwarf_scope_probe .* at .*dwarf_debug\.tkb:95$/ {
            print "bt block #0 => dwarf_scope_probe:95"
          }
        ' "$gdb_out"
        awk '
          /^DBG_FOR_LOCAL$/ { in_for = 1; next }
          /^DBG_FOREACH_LOCAL$/ { in_for = 0 }
          in_for && /^\$[0-9][0-9]* = 206$/ {
            print "p for_local => 206"
          }
          in_for && /^#0  dwarf_scope_probe .* at .*dwarf_debug\.tkb:99$/ {
            print "bt for #0 => dwarf_scope_probe:99"
          }
        ' "$gdb_out"
        awk '
          /^DBG_FOREACH_LOCAL$/ { in_foreach = 1; next }
          in_foreach && /^\$[0-9][0-9]* = 205$/ {
            print "p foreach_local => 205"
            next
          }
          in_foreach && /^#0  dwarf_scope_probe .* at .*dwarf_debug\.tkb:103$/ {
            print "bt foreach #0 => dwarf_scope_probe:103"
            in_foreach = 0
          }
        ' "$gdb_out"
        awk '
          /^DBG_TUPLE_LOCAL$/ { in_tuple = 1; next }
          in_tuple && /^\$[0-9][0-9]* = 380$/ && !saw_stop {
            print "p tuple_stop_arg => 380"
            saw_stop = 1
            next
          }
          in_tuple && /^\$[0-9][0-9]* = true$/ {
            print "p tuple_ok => true"
          }
          in_tuple && /^\$[0-9][0-9]* = 314$/ {
            print "p tuple_value => 314"
          }
          in_tuple && /^\$[0-9][0-9]* = 380$/ {
            print "p tuple_total => 380"
          }
          in_tuple && /^#0  dwarf_tuple_stop .* at .*dwarf_debug\.tkb:113$/ {
            print "bt tuple #0 => dwarf_tuple_stop:113"
          }
          in_tuple && /^#1  .*dwarf_tuple_probe \(\) at .*dwarf_debug\.tkb:119$/ {
            print "bt tuple #1 => dwarf_tuple_probe:119"
          }
          in_tuple && /^#2  .* in app_main \(\) at .*dwarf_debug\.tkb:126$/ {
            print "bt tuple #2 => app_main:126"
            in_tuple = 0
          }
        ' "$gdb_out"
        printf "qemu output => %s\n" "$(tr -d '\r' < "$qemu_out")"
    } > "$gdb_norm"

    if ! diff -u "$expected" "$gdb_norm" > "$gdb_diff"; then
        ok=0
    fi

    if [ "$ok" -eq 1 ]; then
        printf "${GRN}PASS${RST}  %s\n" "$name"
        PASS=$((PASS + 1))
    else
        printf "${RED}FAIL${RST}  %s  (GDB global print/set regression)\n" "$name"
        printf "       normalized diff:\n"
        sed 's/^/       /' "$gdb_diff"
        printf "       gdb output:\n"
        sed 's/^/       /' "$gdb_out"
        printf "       qemu output:\n"
        sed 's/^/       /' "$qemu_out"
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$name")
    fi

    rm -f "$qemu_out" "$gdb_out" "$gdb_norm" "$gdb_diff"
}

if [ "$HOST_ONLY" = "--host-only" ]; then
    run_host_integration_tests "$HOST_ONLY_NAME"
    [ "$FAIL" -eq 0 ]
    exit $?
fi

echo "Running host integration tests (no QEMU required)..."
echo ""

run_host_integration_tests

echo ""
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
run_compile_error_test "cond_not_bool"         examples/cond_not_bool/cond_not_bool.tkb                 examples/cond_not_bool/cond_not_bool.error
run_compile_error_test "affine_double_consume" examples/affine_double_consume/affine_double_consume.tkb examples/affine_double_consume/affine_double_consume.error
run_compile_error_test "affine_never_consumed" examples/affine_never_consumed/affine_never_consumed.tkb examples/affine_never_consumed/affine_never_consumed.error
run_compile_error_test "linear_never_consumed" examples/linear_never_consumed/linear_never_consumed.tkb examples/linear_never_consumed/linear_never_consumed.error
run_compile_error_test "linear_branch_missed" examples/linear_branch_missed/linear_branch_missed.tkb examples/linear_branch_missed/linear_branch_missed.error
run_compile_error_test "linear_cast_discard" examples/linear_cast_discard/linear_cast_discard.tkb examples/linear_cast_discard/linear_cast_discard.error
run_compile_error_test "linear_overwrite" examples/linear_overwrite/linear_overwrite.tkb examples/linear_overwrite/linear_overwrite.error
run_compile_error_test "private_mint_wrong" examples/private_mint_wrong/private_mint_wrong.tkb examples/private_mint_wrong/private_mint_wrong.error
run_compile_error_test "private_field_wrong" examples/private_field_wrong/private_field_wrong.tkb examples/private_field_wrong/private_field_wrong.error
run_compile_error_test "opaque_arith_wrong" examples/opaque_arith_wrong/opaque_arith_wrong.tkb examples/opaque_arith_wrong/opaque_arith_wrong.error
run_compile_error_test "affine_launder_wrong" examples/affine_launder_wrong/affine_launder_wrong.tkb examples/affine_launder_wrong/affine_launder_wrong.error
run_compile_error_test "tuple_linear_leak_wrong" examples/tuple_linear_leak_wrong/tuple_linear_leak_wrong.tkb examples/tuple_linear_leak_wrong/tuple_linear_leak_wrong.error
run_compile_error_test "tuple_field_wrong" examples/tuple_field_wrong/tuple_field_wrong.tkb examples/tuple_field_wrong/tuple_field_wrong.error
run_compile_error_test "tuple_cast_wrong" examples/tuple_cast_wrong/tuple_cast_wrong.tkb examples/tuple_cast_wrong/tuple_cast_wrong.error
run_compile_error_test "field_double_consume_wrong" examples/field_double_consume_wrong/field_double_consume_wrong.tkb examples/field_double_consume_wrong/field_double_consume_wrong.error
run_compile_error_test "field_never_consumed_wrong" examples/field_never_consumed_wrong/field_never_consumed_wrong.tkb examples/field_never_consumed_wrong/field_never_consumed_wrong.error
run_compile_error_test "affine_param_never_consumed" examples/affine_param_never_consumed/affine_param_never_consumed.tkb examples/affine_param_never_consumed/affine_param_never_consumed.error
run_compile_error_test "align_ptr_unproven" examples/align_ptr_unproven/align_ptr_unproven.tkb examples/align_ptr_unproven/align_ptr_unproven.error
run_compile_error_test "klock_guard_forgot_unlock" examples/klock_guard_forgot_unlock/klock_guard_forgot_unlock.tkb examples/klock_guard_forgot_unlock/klock_guard_forgot_unlock.error
run_compile_error_test "percpu_unrefined_rejected" examples/percpu_unrefined_rejected/percpu_unrefined_rejected.tkb examples/percpu_unrefined_rejected/percpu_unrefined_rejected.error --forbid-trap

echo ""
echo "Running DWARF debug-info check (-g build)..."
echo ""

FIB_DEBUG_ELF=examples/fibonacci/kernel.debug.elf
run_dwarf_var_test "fibonacci a (dwarf var)"   "$FIB_DEBUG_ELF" a   DW_TAG_variable          fibonacci.tkb 4 i32
run_dwarf_var_test "fibonacci b (dwarf var)"   "$FIB_DEBUG_ELF" b   DW_TAG_variable          fibonacci.tkb 5 i32
run_dwarf_var_test "fibonacci tmp (dwarf var)" "$FIB_DEBUG_ELF" tmp DW_TAG_variable          fibonacci.tkb 6 i32
run_dwarf_var_test "uart_putc c (dwarf param)" "$FIB_DEBUG_ELF" c   DW_TAG_formal_parameter  uart.tkb      1 u8
run_dwarf_gdb_global_set_test "typed globals via gdb (dwarf)" examples/dwarf_debug/kernel.debug.elf examples/dwarf_debug/dwarf_debug.gdb.expected

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
run_test "struct_refined" examples/struct_refined/kernel.elf examples/struct_refined/struct_refined.expected
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
run_test "affine_escape_via_index" examples/affine_escape_via_index/kernel.elf examples/affine_escape_via_index/affine_escape_via_index.expected
run_test "linear_obligation" examples/linear_obligation/kernel.elf examples/linear_obligation/linear_obligation.expected
run_test "tuple_pair" examples/tuple_pair/kernel.elf examples/tuple_pair/tuple_pair.expected
run_test "field_lease" examples/field_lease/kernel.elf examples/field_lease/field_lease.expected
run_test "align_ptr_proof" examples/align_ptr_proof/kernel.elf examples/align_ptr_proof/align_ptr_proof.expected
run_test "klock_guard" examples/klock_guard/kernel.elf examples/klock_guard/klock_guard.expected
run_test "percpu" examples/percpu/kernel.elf examples/percpu/percpu.expected
run_test "chan_rendezvous" examples/chan_rendezvous/kernel.elf examples/chan_rendezvous/chan_rendezvous.expected
run_test "rtos_demo" examples/rtos_demo/kernel.elf examples/rtos_demo/rtos_demo.expected
run_test "inet_checksum" examples/inet_checksum/kernel.elf examples/inet_checksum/inet_checksum.expected
run_test "ip_parse"      examples/ip_parse/kernel.elf      examples/ip_parse/ip_parse.expected
run_test "tcp_parse"     examples/tcp_parse/kernel.elf     examples/tcp_parse/tcp_parse.expected
run_virtio_test "net_echo"   examples/net_echo/kernel.elf   virtio_net_test.py
run_virtio_test "arp_reply"  examples/arp_reply/kernel.elf  arp_test.py
run_virtio_test "icmp_echo"  examples/icmp_echo/kernel.elf  icmp_echo_test.py
run_virtio_test "tcp_echo"   examples/tcp_echo/kernel.elf   tcp_echo_test.py
run_virtio_test "http_server" examples/http_server/kernel.elf http_server_test.py
run_fatfs_test "fatfs" examples/fatfs/kernel.elf examples/fatfs/fatfs.expected fatfs_mtools_test.py

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
