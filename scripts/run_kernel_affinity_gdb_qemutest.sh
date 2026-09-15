#!/usr/bin/env bash
# GitHub issue #9: the migration gate, watched from outside the kernel. The
# boot and network peer are the ash lane's. A gdb script types /bin/affinity
# into the first interactive shell. The probe pins itself to CPU 1 and asks
# for uname, which is outside the peer-safety table. gdb must see the gate
# fire on CPU 1 for that uname, then core 0 dispatch it again. The reasoning
# is in scripts/kernel_affinity_gdb_check.py.
set -euo pipefail

# `set -e` aborts with no context, and a lane's setup prints nothing on
# success. Name the line, the command and the status.
trap 'takibi_status=$?; echo "[$(basename "$0")] aborted at line $LINENO with exit $takibi_status: $BASH_COMMAND" >&2' ERR

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ELF="${KERNEL_QEMU_AFFINITY_GDB_ELF:-$REPO_ROOT/kernel/build/qemu/kernel.elf}"
. "$REPO_ROOT/scripts/kernel_elf_freshness.sh"
kernel_elf_refuse_stale "$ELF" || exit 1
EXT2_IMAGE="$REPO_ROOT/kernel/build/user/ext2.img"
ARTIFACT_DIR="${KERNEL_QEMU_AFFINITY_GDB_ARTIFACT_DIR:-$REPO_ROOT/_build/kernel-affinity-gdb-qemu}"
QEMU_EXT2_IMAGE="$ARTIFACT_DIR/ext2.img"
SERIAL_PORT="${KERNEL_QEMU_AFFINITY_GDB_SERIAL_PORT:-18717}"
GDB_PORT="${KERNEL_QEMU_AFFINITY_GDB_GDB_PORT:-18718}"
NETDEV_LOCAL_PORT="${KERNEL_QEMU_AFFINITY_GDB_NETDEV_LOCAL_PORT:-18719}"
NETDEV_REMOTE_PORT="${KERNEL_QEMU_AFFINITY_GDB_NETDEV_REMOTE_PORT:-18720}"
INIT_LISTENER="$ARTIFACT_DIR/init.listener"
NETWORK_READY="$ARTIFACT_DIR/network.ready"
VERDICT="$ARTIFACT_DIR/verdict"

if [ ! -f "$EXT2_IMAGE" ]; then
    echo "error: kernel build products are missing" >&2
    exit 1
fi
if ! command -v gdb-multiarch >/dev/null 2>&1; then
    echo "error: gdb-multiarch is required for kernelcheck-affinity-gdb-qemu" >&2
    exit 1
fi

mkdir -p "$ARTIFACT_DIR"
rm -f "$INIT_LISTENER" "$NETWORK_READY" "$VERDICT"
cp "$EXT2_IMAGE" "$QEMU_EXT2_IMAGE"

. "$REPO_ROOT/scripts/qemu_session_ports.sh"
qemu_session_shift_ports SERIAL_PORT GDB_PORT NETDEV_LOCAL_PORT NETDEV_REMOTE_PORT
python3 "$REPO_ROOT/scripts/qemu_port_guard.py" "kernel/qemu affinity-gdb" \
    "tcp:$SERIAL_PORT" "tcp:$GDB_PORT" "udp:$NETDEV_LOCAL_PORT" "udp:$NETDEV_REMOTE_PORT" || exit 1

QEMU_PID=""
PEER_PID=""
cleanup() {
    if [ -n "$QEMU_PID" ]; then
        kill "$QEMU_PID" 2>/dev/null || true
        wait "$QEMU_PID" 2>/dev/null || true
    fi
    if [ -n "$PEER_PID" ]; then
        kill "$PEER_PID" 2>/dev/null || true
        wait "$PEER_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM HUP

qemu-system-aarch64 \
    -machine virt -cpu cortex-a53 -smp 2 -m 1024 -display none -monitor none \
    -serial "tcp:127.0.0.1:$SERIAL_PORT,server=on,wait=on" \
    -gdb "tcp:127.0.0.1:$GDB_PORT" \
    -global virtio-mmio.force-legacy=on \
    -drive "file=$QEMU_EXT2_IMAGE,if=none,format=raw,id=vd0" \
    -device virtio-blk-device,drive=vd0 \
    -netdev "dgram,id=net0,local.type=inet,local.host=127.0.0.1,local.port=$NETDEV_LOCAL_PORT,remote.type=inet,remote.host=127.0.0.1,remote.port=$NETDEV_REMOTE_PORT" \
    -device virtio-net-device,netdev=net0,mac=02:00:20:00:00:02,csum=off,guest_csum=off,gso=off,guest_tso4=off,guest_tso6=off,guest_ufo=off,guest_uso4=off,guest_uso6=off,mrg_rxbuf=off,ctrl_vq=off,mq=off,indirect_desc=off,event_idx=off \
    -kernel "$ELF" >"$ARTIFACT_DIR/qemu.log" 2>&1 &
QEMU_PID=$!

python3 -u "$REPO_ROOT/scripts/kernel_net_test.py" "$NETDEV_LOCAL_PORT" "$NETDEV_REMOTE_PORT" --fast \
    --init-ready-file "$INIT_LISTENER" \
    --network-ready-file "$NETWORK_READY" \
    >"$ARTIFACT_DIR/net-peer.log" 2>&1 &
PEER_PID=$!

AFFINITY_GDB_SERIAL_PORT="$SERIAL_PORT" AFFINITY_GDB_GDB_PORT="$GDB_PORT" \
AFFINITY_GDB_UART_LOG="$ARTIFACT_DIR/uart.log" AFFINITY_GDB_VERDICT="$VERDICT" \
AFFINITY_GDB_INIT_LISTENER="$INIT_LISTENER" AFFINITY_GDB_NETWORK_READY="$NETWORK_READY" \
AFFINITY_GDB_BOOT_TIMEOUT="${KERNEL_QEMU_TIMEOUT:-120}" \
    gdb-multiarch -q -batch "$ELF" -x "$REPO_ROOT/scripts/kernel_affinity_gdb_check.py" \
    >"$ARTIFACT_DIR/gdb.log" 2>&1 || true

if [ ! -f "$VERDICT" ]; then
    echo "FAIL kernel/qemu affinity-gdb: the gdb check wrote no verdict; see $ARTIFACT_DIR/gdb.log" >&2
    exit 1
fi
cat "$VERDICT"
grep -q '^PASS ' "$VERDICT"
