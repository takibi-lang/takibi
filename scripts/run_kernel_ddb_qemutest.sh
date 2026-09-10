#!/usr/bin/env bash
# Resumable DDB regression: QEMU injects a real serial BREAK, the kernel
# inspects its compiler-generated IRQ frame, and `continue` resumes boot.
set -euo pipefail

# `set -e` aborts with no context, and everything before the first echo below
# is setup that prints nothing on success. A CI run failed here with exit 74
# and not one line of output, so which command produced 74 could not be
# determined from the log at all -- the lane was an absence, which is the one
# thing a reader cannot act on.
trap 'status=$?; echo "[kernel/qemu ddb] aborted at line $LINENO with exit $status: $BASH_COMMAND" >&2' ERR

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ELF="${KERNEL_QEMU_DDB_ELF:-$REPO_ROOT/kernel/build/qemu/kernel-debug.elf}"
EXT2_IMAGE="$REPO_ROOT/kernel/build/user/ext2.img"
ARTIFACT_DIR="${KERNEL_QEMU_DDB_ARTIFACT_DIR:-$REPO_ROOT/_build/kernel-ddb-qemu}"
SERIAL_PORT="${KERNEL_QEMU_DDB_SERIAL_PORT:-18701}"
QMP_PORT="${KERNEL_QEMU_DDB_QMP_PORT:-18702}"
GDB_PORT="${KERNEL_QEMU_DDB_GDB_PORT:-18703}"
BREAK_SOURCE="${KERNEL_QEMU_DDB_BREAK_SOURCE:-uart}"
UART_LOG="$ARTIFACT_DIR/uart.log"
GDB_VIEW_LOG="$ARTIFACT_DIR/kernel-state-gdb.log"
GDB_INVALID_LOG="$ARTIFACT_DIR/kernel-state-invalid-gdb.log"
GDB_REPLACED_TEST="$ARTIFACT_DIR/kernel-state-replaced-test.gdb"
SNAPSHOT_READY="$ARTIFACT_DIR/snapshot.ready"
SNAPSHOT_RELEASE="$ARTIFACT_DIR/snapshot.release"
QEMU_EXT2_IMAGE="$ARTIFACT_DIR/ext2.img"
KERNEL_READ_ADDRESS="$(llvm-nm-19 "$ELF" | awk '$3 == "kernel_ddb_breakpoint_test_enabled" && !seen { print $1; seen = 1 }')"
if [ -z "$KERNEL_READ_ADDRESS" ]; then
    echo "kernel DDB read-test symbol not found" >&2
    exit 1
fi

mkdir -p "$ARTIFACT_DIR"
rm -f "$SNAPSHOT_READY" "$SNAPSHOT_RELEASE"
cp "$EXT2_IMAGE" "$QEMU_EXT2_IMAGE"
. "$REPO_ROOT/scripts/qemu_session_ports.sh"
qemu_session_shift_ports SERIAL_PORT QMP_PORT GDB_PORT
python3 "$REPO_ROOT/scripts/qemu_port_guard.py" "kernel/qemu ddb" \
    "tcp:$SERIAL_PORT" "tcp:$QMP_PORT" "tcp:$GDB_PORT" || exit 1

qemu-system-aarch64 \
    -machine virt -cpu cortex-a53 -smp 2 -m 1024 -display none \
    -qmp "tcp:127.0.0.1:$QMP_PORT,server=on,wait=off" \
    -gdb "tcp:127.0.0.1:$GDB_PORT" -S \
    -chardev "socket,id=debug_uart,host=127.0.0.1,port=$SERIAL_PORT,server=on,wait=off" \
    -serial chardev:debug_uart \
    -global virtio-mmio.force-legacy=on \
    -drive "file=$QEMU_EXT2_IMAGE,if=none,format=raw,id=vd0" \
    -device virtio-blk-device,drive=vd0 \
    -kernel "$ELF" >"$ARTIFACT_DIR/qemu.log" 2>&1 &
qemu_pid=$!
driver_pid=""
cleanup() {
    if [ -n "$driver_pid" ]; then kill "$driver_pid" 2>/dev/null || true; fi
    kill "$qemu_pid" 2>/dev/null || true
    wait "$qemu_pid" 2>/dev/null || true
}
trap cleanup EXIT INT TERM HUP

python3 "$REPO_ROOT/scripts/run_kernel_ddb_driver.py" \
    --serial-port "$SERIAL_PORT" --qmp-port "$QMP_PORT" \
    --break-source "$BREAK_SOURCE" \
    --kernel-address "$KERNEL_READ_ADDRESS" \
    --log "$UART_LOG" \
    --snapshot-ready-file "$SNAPSHOT_READY" \
    --snapshot-release-file "$SNAPSHOT_RELEASE" \
    --timeout 90 &
driver_pid=$!

GDB_COMMANDS=(
    -ex "target remote 127.0.0.1:$GDB_PORT"
    -ex "break kernel_ddb_breakpoint_test_checkpoint"
    -ex "continue"
    -ex "set *(char *)&kernel_ddb_memory_fault_test_enabled = 1"
    -ex "set *(char *)&kernel_ddb_backtrace_test_enabled = 1"
    -ex "set *(char *)&kernel_ddb_wait_test_enabled = 1"
    -ex "set *(char *)&diagnostic_trace_test_enabled = 1"
    -ex "disable 1"
)
if [ "$BREAK_SOURCE" = software ]; then
    GDB_COMMANDS+=(
        -ex "set *(char *)&kernel_ddb_breakpoint_test_enabled = 1"
    )
fi
gdb-multiarch -q -batch "$ELF" "${GDB_COMMANDS[@]}" \
    -ex "detach" >/dev/null

for _wait in $(seq 1 300); do
    [ -e "$SNAPSHOT_READY" ] && break
    kill -0 "$driver_pid" 2>/dev/null || break
    sleep 0.1
done
if [ ! -e "$SNAPSHOT_READY" ]; then
    echo "FAIL kernel/qemu ddb: DDB snapshot was not ready for GDB" >&2
    exit 1
fi
cat >"$GDB_REPLACED_TEST" <<'GDB'
python
_tk_eval_before_replaced_test = _tk_eval
_tk_replaced_test_publication_reads = 0
def _tk_eval_replaced_test(expression):
    global _tk_replaced_test_publication_reads
    value = _tk_eval_before_replaced_test(expression)
    if expression == "ddb_snapshot_published_sequence":
        _tk_replaced_test_publication_reads += 1
        if _tk_replaced_test_publication_reads == 2:
            gdb.execute(
                "set ddb_snapshot_published_sequence = "
                "ddb_snapshot_published_sequence + 1")
            value = _tk_eval_before_replaced_test(expression)
    return value
_tk_eval = _tk_eval_replaced_test
end
takibi-kernel 1
python
_tk_eval = _tk_eval_before_replaced_test
end
GDB
gdb-multiarch -q -batch "$ELF" \
    -ex "target remote 127.0.0.1:$GDB_PORT" \
    -ex "interrupt" \
    -ex "source $REPO_ROOT/scripts/kernel_debug_metadata.gdb" \
    -ex "takibi-debug-metadata $REPO_ROOT/_build/kernel-debug-metadata.json" \
    -ex "source $REPO_ROOT/scripts/kernel_state.gdb" \
    -ex "takibi-kernel 1" \
    -ex "set logging file $GDB_INVALID_LOG" \
    -ex "set logging overwrite on" \
    -ex "set logging redirect on" \
    -ex "set logging enabled on" \
    -ex 'set $saved_published = ddb_snapshot_published_sequence' \
    -ex "source $GDB_REPLACED_TEST" \
    -ex 'set ddb_snapshot_published_sequence = $saved_published' \
    -ex 'set ddb_snapshot_published_sequence = 0' \
    -ex "takibi-kernel 1" \
    -ex 'set ddb_snapshot_published_sequence = ddb_snapshot.sequence + 1' \
    -ex "takibi-kernel 1" \
    -ex 'set ddb_snapshot_published_sequence = $saved_published' \
    -ex 'set $saved_root_live = ddb_snapshot.root_live' \
    -ex 'set ddb_snapshot.root_live = 2' \
    -ex "takibi-kernel 1" \
    -ex 'set ddb_snapshot.root_live = $saved_root_live' \
    -ex 'set $saved_truncated = ddb_snapshot.process_truncated' \
    -ex 'set ddb_snapshot.process_truncated = 1' \
    -ex "takibi-kernel 999999" \
    -ex 'set ddb_snapshot.process_truncated = $saved_truncated' \
    -ex "set logging enabled off" \
    -ex "detach" >"$GDB_VIEW_LOG" 2>&1
if ! grep -q '^takibi-kernel: ddb status=replaced ' "$GDB_INVALID_LOG" ||
        ! grep -q '^takibi-kernel: ddb status=unpublished$' "$GDB_INVALID_LOG" ||
        ! grep -q '^takibi-kernel: ddb status=in-progress ' "$GDB_INVALID_LOG" ||
        ! grep -q '^takibi-kernel: ddb status=invalid .*root_live=2$' "$GDB_INVALID_LOG" ||
        ! grep -q '^takibi-kernel: selected pid=999999 status=not-captured snapshot-truncated$' "$GDB_INVALID_LOG"; then
    echo "FAIL kernel/qemu ddb: invalid snapshot states were not refused explicitly" >&2
    sed 's/^/  /' "$GDB_INVALID_LOG" >&2 || true
    exit 1
fi
touch "$SNAPSHOT_RELEASE"
wait "$driver_pid"
python3 "$REPO_ROOT/scripts/validate_kernel_gdb_state.py" \
    --uart-log "$UART_LOG" --gdb-log "$GDB_VIEW_LOG"

# GitHub issue #529: two claims, and they are different claims. The first two
# patterns are the REAL snapshot's derivation -- whatever this boot's
# processes were doing, the header and the summary must be there and must
# name their states rather than print numbers. The rest is `waittest`, which
# renders issue #524's own topology from records the debugger wrote: a
# grandparent and a parent both blocked collecting a child, and the child the
# current, running process waiting for a network event. That chain is the
# thing the view exists to present, and reproducing the stall to see it is
# exactly what this replaces.

# GitHub issue #531: `console tx=queued` is the resume putting back the state
# the stand-down found. Asserted here because nothing else on this lane can
# see it -- the boot's own `console: tx spin` measurement is printed before
# DDB is ever entered, so a console left spinning after `continue` costs
# 78.9 us/byte for the rest of the run and fails nothing. Both break sources
# enter well after kernel_log_tx_activate(), so `queued` is the only correct
# answer here; `spinning` would mean the resume stopped restoring, or that
# the BREAK landed before the console was armed, and either is worth a
# failure.
expected_entry=irq
expected_source=33
if [ "$BREAK_SOURCE" = software ]; then
    expected_entry=brk
    expected_source=21579
fi

if ! grep -q '^ddb: interrupt-safe UART debugger$' "$UART_LOG" ||
        ! grep -q '^ddb: world-stop complete mask=0x0000000000000002$' "$UART_LOG" ||
        ! grep -Eq '^ddb: break seq=[1-9][0-9]* cpu=[0-9]+ elr=0x[0-9a-f]+ sp_el0=0x[0-9a-f]+$' "$UART_LOG" ||
        ! grep -q '^ddb: x0=0x' "$UART_LOG" ||
        ! grep -q '^ddb: sp_el0=0x' "$UART_LOG" ||
        ! grep -Eq "^ddb: intr cpu=[0-9]+ entry=$expected_entry source=$expected_source live_daif=0x[0-9a-f]+ saved_daif=0x[0-9a-f]+$" "$UART_LOG" ||
        ! grep -Eq '^ddb: intr esr=(0x[0-9a-f]+|unavailable) far=(0x[0-9a-f]+|unavailable)$' "$UART_LOG" ||
        ! grep -Eq '^ddb: sched enabled=[01] pending=[01] current=[0-9]+ ready=[0-9]+ running=[0-9]+ blocked=[0-9]+ exited=[0-9]+ truncated=[01]$' "$UART_LOG" ||
        ! grep -Eq '^ddb: current pid=[0-9]+ parent=[0-9]+ state=[0-9]+ wait=[0-9]+$' "$UART_LOG" ||
        ! grep -Eq '^ddb: vm pid=[0-9]+ root=[0-9]+ live=[01] asid=[0-9]+ l1=0x[0-9a-f]+$' "$UART_LOG" ||
        ! grep -Eq '^ddb: fds pid=[0-9]+ slots=[0-9]+$' "$UART_LOG" ||
        ! grep -Eq '^ddb: ps count=[1-9][0-9]* truncated=[01]$' "$UART_LOG" ||
        ! grep -Eq '^ddb: ps pid=1 ppid=0 state=[0-9]+ wait=[0-9]+ root=0 sp=0x[0-9a-f]+$' "$UART_LOG" ||
        ! grep -Eq '^ddb: proc pid=1 ppid=0 state=[0-9]+ wait=[0-9]+ root=0 sp=0x[0-9a-f]+$' "$UART_LOG" ||
        [ "$(grep -Ec '^ddb: bt source=(cpu cpu=[0-9]+|saved) pid=[0-9]+ stack=0x[0-9a-f]+\.\.0x[0-9a-f]+$' "$UART_LOG")" -lt 2 ] ||
        [ "$(grep -Ec '^ddb: bt frame=0 pc=0x[0-9a-f]+ boundary=(exception|user|assembly|assembly-bridge)$' "$UART_LOG")" -lt 2 ] ||
        ! grep -Eq '^ddb: bt (complete frames=[1-9][0-9]*|stop=(assembly-boundary|depth-limit|invalid-return-pc|nonmonotonic-frame|out-of-range) fp=0x[0-9a-f]+)$' "$UART_LOG" ||
        ! grep -q '^ddb: usage: bt \[PID\]$' "$UART_LOG" ||
        ! grep -q '^ddb: bt pid not captured$' "$UART_LOG" ||
        ! grep -q '^ddb: bt stop=unsupported-pc fp=0x' "$UART_LOG" ||
        ! grep -q '^ddb: bt stop=misaligned-pc fp=0x' "$UART_LOG" ||
        ! grep -q '^ddb: bt stop=misaligned-frame fp=0x0000000000000003$' "$UART_LOG" ||
        ! grep -q '^ddb: bt stop=out-of-range fp=0x' "$UART_LOG" ||
        ! grep -q '^ddb: bt stop=depth-limit fp=0x' "$UART_LOG" ||
        ! grep -q '^ddb: bt test invalid saved contexts rejected$' "$UART_LOG" ||
        ! grep -q '^ddb: trace count=' "$UART_LOG" ||
        ! grep -q '^ddb: events cpu=0 count=' "$UART_LOG" ||
        ! grep -Eq "^ddb: xk address=0x0*$KERNEL_READ_ADDRESS count=2$" "$UART_LOG" ||
        [ "$(grep -c '^ddb: xk byte address=0x.* value=0x' "$UART_LOG")" -lt 2 ] ||
        [ "$(grep -c '^ddb: usage: xk|xp HEX_ADDRESS \[COUNT_1_TO_64\]$' "$UART_LOG")" -ne 2 ] ||
        ! grep -q '^ddb: xk denied (not ordinary kernel RAM) address=0x0000001000000000 count=1$' "$UART_LOG" ||
        ! grep -q '^ddb: xk fault address=0x0000000800000000$' "$UART_LOG" ||
        ! grep -Eq "^ddb: xp physical=0x0*$KERNEL_READ_ADDRESS count=2$" "$UART_LOG" ||
        [ "$(grep -c '^ddb: xp byte physical=0x.* value=0x' "$UART_LOG")" -lt 2 ] ||
        ! grep -q '^ddb: xp denied (not ordinary physical RAM) address=0x0000001000000000 count=1$' "$UART_LOG" ||
        ! grep -q '^ddb: xu pid=1 root=0 address=0x0000000080000000 count=2$' "$UART_LOG" ||
        [ "$(grep -c '^ddb: xu byte address=0x000000008000000[01] physical=0x[0-9a-f]* value=0x[0-9a-f]*$' "$UART_LOG")" -lt 2 ] ||
        ! grep -q '^ddb: xu pid=1 root=0 address=0x0000000080000fff count=2$' "$UART_LOG" ||
        ! grep -q '^ddb: xu byte address=0x0000000080000fff physical=0x' "$UART_LOG" ||
        ! grep -q '^ddb: xu byte address=0x0000000080001000 physical=0x' "$UART_LOG" ||
        [ "$(grep -c '^ddb: usage: xu PID HEX_ADDRESS \[COUNT_1_TO_64\]$' "$UART_LOG")" -ne 2 ] ||
        ! grep -q '^ddb: xu pid not captured$' "$UART_LOG" ||
        ! grep -q '^ddb: xu unmapped address=0x0000000070000000$' "$UART_LOG" ||
        ! grep -q '^commands: oops regs intr sched current vm fds ps wait proc PID bt \[PID\] trace events xk ADDRESS \[COUNT\] xp PHYSICAL \[COUNT\] xu PID ADDRESS \[COUNT\] help continue$' "$UART_LOG" ||
        ! grep -Eq '^ddb: wait current=[0-9]+ state=[a-z-]+ reason=[a-z-]+ awaited=[01]$' "$UART_LOG" ||
        ! grep -Eq '^ddb: wait edges=[0-9]+ blocked=[0-9]+ unknown=[0-9]+ truncated=[01]$' "$UART_LOG" ||
        ! grep -q '^ddb: wait current=3 state=running reason=net-rx awaited=1$' "$UART_LOG" ||
        ! grep -q '^ddb: wait pid=1 state=blocked waits-for child pid=2 state=blocked$' "$UART_LOG" ||
        ! grep -q '^ddb: wait pid=2 state=blocked waits-for child pid=3 state=running$' "$UART_LOG" ||
        ! grep -q '^ddb: wait pid=3 state=running waits-for event=net-rx$' "$UART_LOG" ||
        ! grep -q '^ddb: wait pid=9 state=blocked waits-for child unknown$' "$UART_LOG" ||
        ! grep -q '^ddb: wait pid=10 state=blocked waits-for event=uart-rx$' "$UART_LOG" ||
        ! grep -q '^ddb: wait pid=11 state=blocked waits-for event=deadline$' "$UART_LOG" ||
        ! grep -q '^ddb: wait pid=12 state=blocked waits-for event=signal$' "$UART_LOG" ||
        ! grep -q '^ddb: wait pid=13 state=blocked waits-for unknown$' "$UART_LOG" ||
        ! grep -q '^ddb: wait edges=6 blocked=7 unknown=2 truncated=1$' "$UART_LOG" ||
        ! grep -q '^ddb: continuing$' "$UART_LOG" ||
        ! grep -q '^ddb: console tx=queued$' "$UART_LOG" ||
        ! grep -q '^init: ash bootstrap$' "$UART_LOG"; then
    echo "FAIL kernel/qemu ddb: BREAK inspection did not resume boot" >&2
    sed 's/^/  /' "$UART_LOG" >&2 || true
    exit 1
fi

if [ "$BREAK_SOURCE" = uart ] &&
        { ! grep -q '^ddb: bt stop=user-boundary fp=0x' "$UART_LOG" ||
          ! grep -Eq '^ddb: event seq=1 cpu=0 id=0x0000000000000201 a=0x000000000000000a b=0x0*[1-9a-f][0-9a-f]* c=0x0000000000000000 d=0x0000000000000001$' "$UART_LOG" ||
          ! grep -q '^ddb: event seq=2 cpu=0 id=0x0000000000000101 a=0x' "$UART_LOG"; }; then
    echo "FAIL kernel/qemu ddb: interleaved UART wake/BREAK events missing" >&2
    sed 's/^/  /' "$UART_LOG" >&2 || true
    exit 1
fi

# The software-BRK walk's claims live in one file, because they say nothing
# about which machine ran them: scripts/ddb_software_brk_checks.py is what
# the RPi5 board lane asks too. It adds two questions this lane used to skip
# -- that every compiler frame is inside the linker-owned generated-text
# range, and that the walk does not end at a user boundary -- and those two
# are why the board lane no longer runs inside kernelcheck-rpi5.
if [ "$BREAK_SOURCE" = software ]; then
    generated_start="0x$(llvm-nm-19 "$ELF" |
        awk '$3=="kernel_generated_text_start" && !seen{print $1; seen = 1 }')"
    generated_end="0x$(llvm-nm-19 "$ELF" |
        awk '$3=="kernel_generated_text_end" && !seen{print $1; seen = 1 }')"
    if [ -z "${generated_start#0x}" ] || [ -z "${generated_end#0x}" ]; then
        echo "FAIL kernel/qemu ddb: compiler-generated text bounds absent from $ELF" >&2
        exit 1
    fi
    if ! python3 "$REPO_ROOT/scripts/ddb_software_brk_checks.py" \
            --log "$UART_LOG" \
            --generated-start "$generated_start" \
            --generated-end "$generated_end" \
            --label "kernel/qemu ddb"; then
        sed 's/^/  /' "$UART_LOG" >&2 || true
        exit 1
    fi
fi

echo "PASS kernel/qemu ddb: $BREAK_SOURCE BREAK inspected and resumed"
