#!/usr/bin/env bash
# GitHub issue #713: execute the compiler's AArch64 variant-return
# description against the backend's real machine convention.
#
# The debug sidecar (--emit-debug-metadata) says where a variant result
# lives on return: registers x0..x7, one per scalar leaf, or the buffer the
# caller passed in x8. During #693 it said "registers" for a ten-leaf result
# LLVM returned through x8, and the injected failure never arrived. The unit
# tests compare the sidecar with the classifier's own formula, so they could
# not have seen it. This lane compiles kernel/tests/debug_return_abi, boots
# it on QEMU virt, and lets GDB force a payload-free case at the first
# instruction of three real non-inlined callees (four leaves in 32 bytes,
# eight leaves, nine leaves), using only the sidecar. The caller reports
# what it observed over the UART; the verdict is that report.
#
# DEBUG_RETURN_ABI_FLAVOR selects production lowering (the kernel's flags,
# no DWARF) or the existing debug lowering (-g). DEBUG_RETURN_ABI_METADATA
# substitutes a sidecar, which is how the counterfactual controls feed a
# wrong classification through the same path.
set -euo pipefail
trap 'takibi_status=$?; echo "[$(basename "$0")] aborted at line $LINENO with exit $takibi_status: $BASH_COMMAND" >&2' ERR

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# A counterfactual run enters through this script too, so the Makefile line
# that starts it is one scripts/check_qemu_lane_ports.py reads. The wrapper
# calls back in with the variable cleared.
if [ -n "${DEBUG_RETURN_ABI_COUNTERFACTUAL:-}" ]; then
    exec python3 "$REPO_ROOT/scripts/run_kernel_debug_return_abi_counterfactual.py" \
        "$DEBUG_RETURN_ABI_COUNTERFACTUAL"
fi
FLAVOR="${DEBUG_RETURN_ABI_FLAVOR:-production}"
case "$FLAVOR" in
    production) FLAGS=(--frame-pointers --forbid-trap) ;;
    debug) FLAGS=(--frame-pointers --forbid-trap -g) ;;
    *) echo "error: DEBUG_RETURN_ABI_FLAVOR must be production or debug" >&2; exit 2 ;;
esac
LABEL="kernel/qemu debug-return-abi ($FLAVOR${DEBUG_RETURN_ABI_LABEL:+, $DEBUG_RETURN_ABI_LABEL})"
ARTIFACT_DIR="${DEBUG_RETURN_ABI_ARTIFACT_DIR:-${TAKIBI_LANE_ARTIFACT_ROOT:-$REPO_ROOT/_build}/kernel-debug-return-abi-qemu}"
RUN_DIR="$ARTIFACT_DIR/$FLAVOR"
GDB_PORT="${DEBUG_RETURN_ABI_GDB_PORT:-18610}"
TIMEOUT_SECS="${DEBUG_RETURN_ABI_TIMEOUT:-30}"
TAKIBI="$REPO_ROOT/_build/default/bin/main.exe"
FIXTURE="$REPO_ROOT/kernel/tests/debug_return_abi"

mkdir -p "$RUN_DIR"
exec 9>"$RUN_DIR/runner.lock"
if ! flock -n 9; then
    echo "FAIL $LABEL: another runner already owns $RUN_DIR" >&2
    exit 1
fi
rm -f "$RUN_DIR"/uart.log "$RUN_DIR"/gdb.log "$RUN_DIR"/qemu.log

# Build from source every run: the fixture is a few hundred bytes, and a
# stale ELF here would test a compiler nobody asked about. The sidecar is
# its own compiler mode, run with the same flags as the object.
"$TAKIBI" "$FIXTURE/fixture.tkb" --target aarch64-none-elf --cpu cortex-a53 \
    "${FLAGS[@]}" -o "$RUN_DIR/fixture.o"
"$TAKIBI" "$FIXTURE/fixture.tkb" --target aarch64-none-elf --cpu cortex-a53 \
    "${FLAGS[@]}" --emit-debug-metadata "$RUN_DIR/metadata.json"
llvm-mc-19 --triple=aarch64-none-elf --filetype=obj "$FIXTURE/entry.S" \
    -o "$RUN_DIR/entry.o"
ld.lld-19 -T "$FIXTURE/link.ld" "$RUN_DIR/entry.o" \
    "$RUN_DIR/fixture.o" -o "$RUN_DIR/fixture.elf"
METADATA="${DEBUG_RETURN_ABI_METADATA:-$RUN_DIR/metadata.json}"

. "$REPO_ROOT/scripts/qemu_session_ports.sh"
qemu_session_shift_ports GDB_PORT
python3 "$REPO_ROOT/scripts/qemu_port_guard.py" "$LABEL" "tcp:$GDB_PORT" || exit 1

# The guest exits through semihosting when its report is done.
timeout "$TIMEOUT_SECS" qemu-system-aarch64 \
    -machine virt -cpu cortex-a53 -m 128 -display none -monitor none \
    -serial "file:$RUN_DIR/uart.log" \
    -semihosting-config enable=on,target=native \
    -S -gdb "tcp:127.0.0.1:$GDB_PORT" \
    -kernel "$RUN_DIR/fixture.elf" >"$RUN_DIR/qemu.log" 2>&1 &
QEMU_PID=$!
stop_qemu() {
    if [ -n "${QEMU_PID:-}" ]; then
        kill "$QEMU_PID" 2>/dev/null || true
        wait "$QEMU_PID" 2>/dev/null || true
        QEMU_PID=""
    fi
}
trap stop_qemu EXIT
trap 'stop_qemu; exit 130' INT TERM HUP

# QEMU's gdbstub may not listen yet; only a refused connection is retried.
gdb_log="$RUN_DIR/gdb.log"
for _ in $(seq 1 50); do
    timeout "$TIMEOUT_SECS" gdb-multiarch -q -nx -batch "$RUN_DIR/fixture.elf" \
        -ex "target remote 127.0.0.1:$GDB_PORT" \
        -ex "source $REPO_ROOT/scripts/kernel_debug_metadata.gdb" \
        -ex "takibi-debug-metadata $METADATA" \
        -x "$REPO_ROOT/scripts/debug_return_abi.gdb" >"$gdb_log" 2>&1 || true
    if grep -q 'could not connect\|Connection refused' "$gdb_log"; then
        sleep 0.1
        continue
    fi
    break
done
qemu_status=0
wait "$QEMU_PID" || qemu_status=$?
QEMU_PID=""
trap - EXIT INT TERM HUP

fail() {
    echo "FAIL $LABEL: $1" >&2
    echo "artifacts: $RUN_DIR" >&2
    sed 's/^/  uart: /' "$RUN_DIR/uart.log" >&2 2>/dev/null || true
    sed 's/^/  gdb: /' "$gdb_log" >&2 || true
    exit 1
}

[ "$qemu_status" -eq 0 ] || fail "QEMU exited with status $qemu_status before the fixture's semihosting exit"
grep -qx 'debug-return-abi: done' "$RUN_DIR/uart.log" ||
    fail "the fixture never reported done"
for probe in direct eight nine; do
    grep -qx "debug-return-abi: $probe control observed=normal" "$RUN_DIR/uart.log" ||
        fail "$probe control round did not observe an intact normal result"
    observed="$(sed -n "s/^debug-return-abi: $probe forced observed=//p" "$RUN_DIR/uart.log")"
    [ -n "$observed" ] || fail "$probe forced round has no outcome"
    [ "$observed" = forced ] ||
        fail "return ABI mismatch at $probe: the caller observed $observed after GDB forced Forced"
done
for expected in 'DebugAbiDirect::Forced via registers' \
                'DebugAbiEightLeaves::Forced via registers' \
                'DebugAbiNineLeaves::Forced via indirect'; do
    grep -qF "takibi-force-variant-return: $expected" "$gdb_log" ||
        fail "GDB did not report '$expected'"
done
echo "PASS $LABEL: forced results arrived through the real return convention at four, eight and nine leaves"
