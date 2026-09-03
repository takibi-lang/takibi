#!/usr/bin/env bash
# Automated BusyBox ash integration over the shared pyserial UART driver.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ASH_DIR="$REPO_ROOT/kernel/tests/common/ash"
ELF="${KERNEL_QEMU_ASH_ELF:-$REPO_ROOT/kernel/build/qemu/kernel.elf}"
RUN_LABEL="kernel/${KERNEL_QEMU_ASH_LABEL:-qemu}"
EXT2_IMAGE="$REPO_ROOT/kernel/build/user/ext2.img"
ARTIFACT_DIR="${KERNEL_QEMU_ASH_ARTIFACT_DIR:-$REPO_ROOT/_build/kernel-hwtest-qemu-ash}"
QEMU_EXT2_IMAGE="$ARTIFACT_DIR/ext2.img"
SERIAL_PORT="${KERNEL_QEMU_ASH_SERIAL_PORT:-17774}"
NETDEV_LOCAL_PORT="${KERNEL_QEMU_ASH_NETDEV_LOCAL_PORT:-17775}"
NETDEV_REMOTE_PORT="${KERNEL_QEMU_ASH_NETDEV_REMOTE_PORT:-17776}"
TIMEOUT_SECS="${KERNEL_QEMU_ASH_TIMEOUT:-90}"

if [ ! -f "$ELF" ] || [ ! -f "$EXT2_IMAGE" ]; then
    echo "error: kernel build products are missing" >&2
    exit 1
fi

mkdir -p "$ARTIFACT_DIR"
cp "$EXT2_IMAGE" "$QEMU_EXT2_IMAGE"

# GitHub issue #407: refuse to start if somebody already owns the ports
# this lane is about to use, and say so in those words. A peer that cannot
# bind used to surface as "no UART output captured -- kernel did not
# boot", which names the kernel for something it was never asked about.
# An orphan of THIS lane -- a qemu-system whose own command line carries
# this port, left behind by an interrupted run -- is reaped; anything else
# is reported and left alone.
. "$REPO_ROOT/scripts/qemu_session_ports.sh"
qemu_session_shift_ports SERIAL_PORT NETDEV_LOCAL_PORT NETDEV_REMOTE_PORT
python3 "$REPO_ROOT/scripts/qemu_port_guard.py" "$RUN_LABEL" \
    "tcp:$SERIAL_PORT" "udp:$NETDEV_LOCAL_PORT" "udp:$NETDEV_REMOTE_PORT" || exit 1

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

echo "[$RUN_LABEL] starting automated ash UART test"
qemu-system-aarch64 \
    -machine virt -cpu cortex-a53 -smp 2 -m 1024 -display none -monitor none \
    -serial "tcp:127.0.0.1:$SERIAL_PORT,server=on,wait=off" \
    -global virtio-mmio.force-legacy=on \
    -drive "file=$QEMU_EXT2_IMAGE,if=none,format=raw,id=vd0" \
    -device virtio-blk-device,drive=vd0 \
    -netdev "dgram,id=net0,local.type=inet,local.host=127.0.0.1,local.port=$NETDEV_LOCAL_PORT,remote.type=inet,remote.host=127.0.0.1,remote.port=$NETDEV_REMOTE_PORT" \
    -device virtio-net-device,netdev=net0,mac=02:00:20:00:00:02,csum=off,guest_csum=off,gso=off,guest_tso4=off,guest_tso6=off,guest_ufo=off,guest_uso4=off,guest_uso6=off,mrg_rxbuf=off,ctrl_vq=off,mq=off,indirect_desc=off,event_idx=off \
    -kernel "$ELF" \
    >"${KERNEL_QEMU_ASH_LOG:-/tmp/takibi-kernel-qemu-ash.log}" 2>&1 &
QEMU_PID=$!

python3 -u "$REPO_ROOT/scripts/kernel_net_test.py" "$NETDEV_LOCAL_PORT" "$NETDEV_REMOTE_PORT" --fast \
    >"${KERNEL_QEMU_ASH_NETWORK_LOG:-/tmp/takibi-kernel-qemu-ash-network.log}" 2>&1 &
PEER_PID=$!

python3 "$REPO_ROOT/scripts/run_kernel_uart_driver.py" \
    --port "socket://127.0.0.1:$SERIAL_PORT" \
    --log "${KERNEL_QEMU_ASH_UART_LOG:-$ARTIFACT_DIR/uart.log}" \
    --stdin "$ASH_DIR/ash.stdin" --expected "$ASH_DIR/ash.expected" \
    --timeout "$TIMEOUT_SECS" --ash-only --validate-ash
echo "PASS $RUN_LABEL ash TCP integration"
