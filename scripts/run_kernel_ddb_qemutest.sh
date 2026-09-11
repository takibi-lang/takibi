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
# shellcheck source=scripts/kernel_elf_freshness.sh
. "$REPO_ROOT/scripts/kernel_elf_freshness.sh"
kernel_elf_refuse_stale "$ELF" || exit 1
EXT2_IMAGE="$REPO_ROOT/kernel/build/user/ext2.img"
ARTIFACT_DIR="${KERNEL_QEMU_DDB_ARTIFACT_DIR:-$REPO_ROOT/_build/kernel-ddb-qemu}"
SERIAL_PORT="${KERNEL_QEMU_DDB_SERIAL_PORT:-18701}"
QMP_PORT="${KERNEL_QEMU_DDB_QMP_PORT:-18702}"
GDB_PORT="${KERNEL_QEMU_DDB_GDB_PORT:-18703}"
NETDEV_LOCAL_PORT="${KERNEL_QEMU_DDB_NETDEV_LOCAL_PORT:-18704}"
NETDEV_REMOTE_PORT="${KERNEL_QEMU_DDB_NETDEV_REMOTE_PORT:-18705}"
BREAK_SOURCE="${KERNEL_QEMU_DDB_BREAK_SOURCE:-uart}"
UART_LOG="$ARTIFACT_DIR/uart.log"
GDB_VIEW_LOG="$ARTIFACT_DIR/kernel-state-gdb.log"
GDB_INVALID_LOG="$ARTIFACT_DIR/kernel-state-invalid-gdb.log"
GDB_REPLACED_TEST="$ARTIFACT_DIR/kernel-state-replaced-test.gdb"
SNAPSHOT_READY="$ARTIFACT_DIR/snapshot.ready"
SNAPSHOT_RELEASE="$ARTIFACT_DIR/snapshot.release"
QEMU_EXT2_IMAGE="$ARTIFACT_DIR/ext2.img"
NETWORK_READY="$ARTIFACT_DIR/network.ready"
FOREGROUND_LISTENER="$ARTIFACT_DIR/foreground-httpd.listener"
INIT_LISTENER="$ARTIFACT_DIR/init.listener"
PEER_LOG="$ARTIFACT_DIR/net-peer.log"
TIMEOUT_SECS="${KERNEL_QEMU_DDB_TIMEOUT:-180}"
KERNEL_READ_ADDRESS="$(llvm-nm-19 "$ELF" | awk '$3 == "kernel_ddb_breakpoint_test_enabled" && !seen { print $1; seen = 1 }')"
if [ -z "$KERNEL_READ_ADDRESS" ]; then
    echo "kernel DDB read-test symbol not found" >&2
    exit 1
fi

mkdir -p "$ARTIFACT_DIR"
rm -f "$SNAPSHOT_READY" "$SNAPSHOT_RELEASE" "$NETWORK_READY" \
    "$FOREGROUND_LISTENER" "$INIT_LISTENER"
cp "$EXT2_IMAGE" "$QEMU_EXT2_IMAGE"
. "$REPO_ROOT/scripts/qemu_session_ports.sh"
qemu_session_shift_ports SERIAL_PORT QMP_PORT GDB_PORT NETDEV_LOCAL_PORT \
    NETDEV_REMOTE_PORT
python3 "$REPO_ROOT/scripts/qemu_port_guard.py" "kernel/qemu ddb" \
    "tcp:$SERIAL_PORT" "tcp:$QMP_PORT" "tcp:$GDB_PORT" \
    "udp:$NETDEV_LOCAL_PORT" "udp:$NETDEV_REMOTE_PORT" || exit 1

qemu-system-aarch64 \
    -machine virt -cpu cortex-a53 -smp 2 -m 1024 -display none \
    -qmp "tcp:127.0.0.1:$QMP_PORT,server=on,wait=off" \
    -gdb "tcp:127.0.0.1:$GDB_PORT" -S \
    -chardev "socket,id=debug_uart,host=127.0.0.1,port=$SERIAL_PORT,server=on,wait=off" \
    -serial chardev:debug_uart \
    -global virtio-mmio.force-legacy=on \
    -drive "file=$QEMU_EXT2_IMAGE,if=none,format=raw,id=vd0" \
    -device virtio-blk-device,drive=vd0 \
    -netdev "dgram,id=net0,local.type=inet,local.host=127.0.0.1,local.port=$NETDEV_LOCAL_PORT,remote.type=inet,remote.host=127.0.0.1,remote.port=$NETDEV_REMOTE_PORT" \
    -device virtio-net-device,netdev=net0,mac=02:00:20:00:00:02,csum=off,guest_csum=off,gso=off,guest_tso4=off,guest_tso6=off,guest_ufo=off,guest_uso4=off,guest_uso6=off,mrg_rxbuf=off,ctrl_vq=off,mq=off,indirect_desc=off,event_idx=off \
    -kernel "$ELF" >"$ARTIFACT_DIR/qemu.log" 2>&1 &
qemu_pid=$!
driver_pid=""
peer_pid=""
cleanup() {
    if [ -n "$driver_pid" ]; then kill "$driver_pid" 2>/dev/null || true; fi
    if [ -n "$peer_pid" ]; then kill "$peer_pid" 2>/dev/null || true; fi
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
    --network-ready-file "$NETWORK_READY" \
    --foreground-listener-file "$FOREGROUND_LISTENER" \
    --init-listener-file "$INIT_LISTENER" \
    --timeout "$TIMEOUT_SECS" &
driver_pid=$!

KERNEL_QEMU_TIMEOUT="$TIMEOUT_SECS" \
python3 -u "$REPO_ROOT/scripts/kernel_net_test.py" \
    "$NETDEV_LOCAL_PORT" "$NETDEV_REMOTE_PORT" \
    --daemon-ready-file "$FOREGROUND_LISTENER" \
    --init-ready-file "$INIT_LISTENER" \
    --network-ready-file "$NETWORK_READY" >"$PEER_LOG" 2>&1 &
peer_pid=$!

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

# The UART BREAK path now reaches the live migration phase rather than the
# first shell prompt. Give it the driver's full boot budget; the indirect-file
# fixture alone can consume most of the former 30-second snapshot wait on a
# loaded host.
for _wait in $(seq 1 "$((TIMEOUT_SECS * 10))"); do
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

# GitHub issue #456: whose fault it is. The guarded read's arming is per core
# now, because its writer is the one core inspecting but its READER is
# whichever core takes a data abort -- a shared word let a peer's real fault
# be answered by DDB's read, redirecting that core into a read it never made.
# These four say what "answerable" requires: armed, the right exception class,
# and the right address, each of which alone has looked like a match.

# GitHub issue #505: a CPU that is not the one running the debugger.
#
# `bt cpu 1` is the peer, whose root it published as it entered the world-stop
# holding pen -- the one moment its own interrupted frame is addressable. It
# used to be unreachable: `bt PID` for a Running process answered "capture
# that cpu" and nothing could. `bt cpu 9` is the refusal, and it is a
# DIFFERENT refusal from a root that moved during the read; asserting the
# wording is asserting that the two stay distinguishable.

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
        ! grep -q '^ddb: stacks cpus=2 processes=' "$UART_LOG" ||
        ! grep -Eq '^ddb: proc pid=1 ppid=0 state=[0-9]+ wait=[0-9]+ root=0 sp=0x[0-9a-f]+$' "$UART_LOG" ||
        [ "$(grep -Ec '^ddb: bt source=(cpu cpu=[0-9]+|saved) pid=[0-9]+ stack=0x[0-9a-f]+\.\.0x[0-9a-f]+$' "$UART_LOG")" -lt 2 ] ||
        [ "$(grep -Ec '^ddb: bt frame=0 pc=0x[0-9a-f]+ boundary=(exception|user|assembly|assembly-bridge)$' "$UART_LOG")" -lt 2 ] ||
        ! grep -Eq '^ddb: bt (complete frames=[1-9][0-9]*|stop=(assembly-boundary|depth-limit|invalid-return-pc|nonmonotonic-frame|out-of-range) fp=0x[0-9a-f]+)$' "$UART_LOG" ||
        ! grep -q '^ddb: usage: bt \[PID|cpu N\]$' "$UART_LOG" ||
        ! grep -Eq '^ddb: bt source=stopped cpu=1 pid=[0-9]+ stack=0x[0-9a-f]+\.\.0x[0-9a-f]+$' "$UART_LOG" ||
        ! grep -q '^ddb: bt cpu=9 not stopped here$' "$UART_LOG" ||
        ! grep -q '^ddb: bt test stopped-root unheld verdict=not-stopped$' "$UART_LOG" ||
        ! grep -q '^ddb: bt test stopped-root publishing verdict=not-stopped$' "$UART_LOG" ||
        ! grep -q '^ddb: bt test stopped-root moved verdict=changed$' "$UART_LOG" ||
        ! grep -q '^ddb: bt test stopped-root retired verdict=not-stopped$' "$UART_LOG" ||
        ! grep -q '^ddb: bt test stopped-root settled verdict=usable$' "$UART_LOG" ||
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
        ! grep -q '^ddb: xk guarded-fault armed-match ours=yes$' "$UART_LOG" ||
        ! grep -q '^ddb: xk guarded-fault armed-other-address ours=no$' "$UART_LOG" ||
        ! grep -q '^ddb: xk guarded-fault armed-other-class ours=no$' "$UART_LOG" ||
        ! grep -q '^ddb: xk guarded-fault unarmed ours=no$' "$UART_LOG" ||
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
        ! grep -q '^commands: oops regs intr sched current vm fds ps stacks wait proc PID bt \[PID|cpu N\] trace events xk ADDRESS \[COUNT\] xp PHYSICAL \[COUNT\] xu PID ADDRESS \[COUNT\] help continue$' "$UART_LOG" ||
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
        { [ "$(grep -Ec '^ddb: stack cpu=[01] pid=[0-9]+ stack=0x[0-9a-f]+\.\.0x[0-9a-f]+ owner=(none|[01]) record=match$' "$UART_LOG")" -ne 2 ] ||
          ! grep -q '^ddb: stacks roots=2 matched=2 missing=0 duplicate-process=0 owner-mismatch=0 range-mismatch=0 duplicate-pid=0 duplicate-stack=0$' "$UART_LOG"; }; then
    echo "FAIL kernel/qemu ddb: migration stack attribution was not unique" >&2
    exit 1
fi

# The software checkpoint deliberately precedes process scheduling: both
# boot CPUs still identify PID 1, while only CPU 0 owns PID 1's process stack.
# Keep that negative control explicit so `stacks` cannot silently call this
# early topology a unique process assignment.
if [ "$BREAK_SOURCE" = software ] &&
        ! grep -q '^ddb: stacks roots=2 matched=1 missing=0 duplicate-process=0 owner-mismatch=1 range-mismatch=1 duplicate-pid=1 duplicate-stack=0$' "$UART_LOG"; then
    echo "FAIL kernel/qemu ddb: boot-time duplicate-root control missing" >&2
    exit 1
fi

if [ "$BREAK_SOURCE" = uart ] &&
        { ! grep -q '^ddb: bt stop=user-boundary fp=0x' "$UART_LOG" ||
          ! grep -Eq '^ddb: events cpu=0 count=[1-9][0-9]* damaged=0 overwritten=[1-9][0-9]*$' "$UART_LOG" ||
          ! grep -Eq '^ddb: event seq=[1-9][0-9]* cpu=0 id=0x0000000000000101 a=0x' "$UART_LOG"; }; then
    echo "FAIL kernel/qemu ddb: late UART BREAK evidence missing" >&2
    sed 's/^/  /' "$UART_LOG" >&2 || true
    exit 1
fi

if [ "$BREAK_SOURCE" = uart ] && ! python3 - "$UART_LOG" <<'PY'
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text(encoding="ascii", errors="replace")
migrated = text.find(
    "workload: busy pair migrated across both cpus with stack handoff intact\n")
stacks = text.find("ddb: stacks cpus=2 processes=")
raise SystemExit(0 if 0 <= migrated < stacks else 1)
PY
then
    echo "FAIL kernel/qemu ddb: snapshot did not follow live migration" >&2
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
