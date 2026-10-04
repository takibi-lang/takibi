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
ARTIFACT_DIR="${KERNEL_QEMU_DDB_ARTIFACT_DIR:-${TAKIBI_LANE_ARTIFACT_ROOT:-$REPO_ROOT/_build}/kernel-ddb-qemu}"
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
# Retain address metadata before the guest starts, including failed runs.
python3 "$REPO_ROOT/scripts/validate_kernel_ddb_qemu.py" \
    --elf "$ELF" --break-source "$BREAK_SOURCE" \
    --save-metadata "$ARTIFACT_DIR/validation.json" --metadata-only
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
    --gdb-port "$GDB_PORT" --elf "$ELF" \
    --kernel-address "$KERNEL_READ_ADDRESS" \
    --log "$UART_LOG" \
    --await-timing-log "$ARTIFACT_DIR/await-timing.jsonl" \
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
else
    # Retain the peer writer; the driver arms its actual guard hold late.
    GDB_COMMANDS+=(
        -ex "set *(char *)&kernel_ddb_console_test_enabled = 1"
        -ex "source $REPO_ROOT/scripts/kernel_peer_exit_check.py"
    )
fi
KERNEL_PEER_EXIT_TIMEOUT="$TIMEOUT_SECS" \
    timeout "${GDB_BATCH_TIMEOUT:-600}" gdb-multiarch -q -batch "$ELF" "${GDB_COMMANDS[@]}" \
    -ex "detach" >"$ARTIFACT_DIR/peer-exit-gdb.log" 2>&1
if [ "$BREAK_SOURCE" = uart ]; then
    grep '^PASS kernel/qemu peer-exit:' "$ARTIFACT_DIR/peer-exit-gdb.log"
fi

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
    # The boot can stop before the driver reaches its DDB checkpoint. Keep
    # the live workload state before cleanup destroys the guest; a later
    # successful BREAK alone cannot identify which peer milestone stopped.
    timeout 10s gdb-multiarch -q -batch "$ELF" \
        -ex "target remote 127.0.0.1:$GDB_PORT" \
        -ex 'maintenance packet Qqemu.PhyMemMode:1' \
        -ex 'set print pretty on' \
        -ex 'p workload_busy_pair' \
        -ex 'p execution_state[0]' \
        -ex 'p execution_state[1]' \
        -ex 'thread apply all info registers pc sp x0 x1 x8' \
        -ex 'detach' >"$ARTIFACT_DIR/checkpoint-failure-gdb.log" 2>&1 || true
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
timeout "${GDB_BATCH_TIMEOUT:-600}" gdb-multiarch -q -batch "$ELF" \
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
    --uart-log "$UART_LOG" --gdb-log "$GDB_VIEW_LOG" --online-cpus 0,1

# Live and archived captures use one set of final UART predicates. The live
# GDB snapshot comparison above remains a separate observation.
python3 "$REPO_ROOT/scripts/validate_kernel_ddb_qemu.py" \
    --log "$UART_LOG" --metadata "$ARTIFACT_DIR/validation.json"

echo "PASS kernel/qemu ddb: $BREAK_SOURCE BREAK inspected and resumed"
