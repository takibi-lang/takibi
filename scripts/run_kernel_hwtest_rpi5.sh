#!/usr/bin/env bash
# Standalone-kernel RPi5 integration runner (GitHub issue #177).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SERIAL_DEV="${RPI5_SERIAL_DEV:-$($REPO_ROOT/scripts/rpi5_uart_dev.sh)}"
ELF="$REPO_ROOT/kernel/build/rpi5/kernel.elf"
VIEW_DIR="$REPO_ROOT/kernel/tests/rpi5/views"
ARTIFACT_DIR="${RPI5_KERNEL_HWTEST_ARTIFACT_DIR:-$REPO_ROOT/_build/kernel-hwtest-rpi5}"
UART_LOG="$ARTIFACT_DIR/uart.log"
RESET_LOG="$ARTIFACT_DIR/reset.log"
LOADER_LOG="$ARTIFACT_DIR/loader.log"
ARP_LOG="$ARTIFACT_DIR/arp.log"
ICMP_LOG="$ARTIFACT_DIR/icmp.log"
TCP_LOG="$ARTIFACT_DIR/tcp.log"
SOCKET_ACCEPT_LOG="$ARTIFACT_DIR/socket-accept.log"
ETH_TEST_IFACE="${ETH_TEST_IFACE:-enp5s0}"
ETH_TEST_SUBNET="${ETH_TEST_SUBNET:-192.168.20}"
ETH_TEST_MAC="${ETH_TEST_MAC:-02:00:20:00:00:02}"

mkdir -p "$ARTIFACT_DIR"
if [ ! -e "$SERIAL_DEV" ]; then
    echo "error: RPi5 UART device not found: $SERIAL_DEV" >&2
    exit 1
fi
if [ ! -f "$ELF" ]; then
    echo "error: kernel ELF not found: $ELF" >&2
    exit 1
fi

stty -F "$SERIAL_DEV" 115200 raw -echo
echo "[kernel/rpi5] resetting board"
if ! "$REPO_ROOT/scripts/rpi5_jtag_reset.sh" --resident-image-unchanged >"$RESET_LOG" 2>&1; then
    echo "FAIL kernel/rpi5: reset failed (see $RESET_LOG)" >&2
    exit 1
fi

# Peripheral FIFO contents survive SWD injection and the resident stub may
# have emitted bytes before it was reset. Drain that history before opening
# the capture used as evidence for this payload.
timeout 1 cat "$SERIAL_DEV" >/dev/null 2>&1 || true

: >"$UART_LOG"
# SWD load time grows with embedded initramfs images. Keep the reader alive
# through the entire load instead of imposing a deadline that can expire
# before the CPU is resumed; cleanup below bounds the post-load capture.
cat "$SERIAL_DEV" >"$UART_LOG" 2>/dev/null &
reader_pid=$!
cleanup() {
    kill "$reader_pid" 2>/dev/null || true
    wait "$reader_pid" 2>/dev/null || true
}
trap cleanup EXIT INT TERM HUP

sleep 0.2
load_started=$SECONDS
echo "[kernel/rpi5] loading kernel over SWD"
if ! "$REPO_ROOT/scripts/rpi5_jtag_load.sh" "$ELF" >"$LOADER_LOG" 2>&1; then
    echo "FAIL kernel/rpi5: load failed (see $LOADER_LOG)" >&2
    exit 1
fi
echo "[kernel/rpi5] kernel loaded in $((SECONDS - load_started))s; waiting for integration completion"

# The kernel holds its affine RX readiness capability while waiting for one
# real ARP request. Exercise the wire path immediately after resume; keep the
# raw-socket privilege confined to the existing protocol checker.
echo "[kernel/rpi5] checking ARP reply on $ETH_TEST_IFACE"
if ! sudo ETH_TEST_IFACE="$ETH_TEST_IFACE" ETH_TEST_SUBNET="$ETH_TEST_SUBNET" \
        ARP_TEST_OTHER_FIRST=1 \
        python3 "$REPO_ROOT/scripts/eth_arp_reply_test.py" \
        > >(tee "$ARP_LOG") 2>&1; then
    echo "FAIL kernel/rpi5: ARP integration failed (see $ARP_LOG)" >&2
    exit 1
fi
echo "[kernel/rpi5] ARP integration passed"

echo "[kernel/rpi5] checking ICMP echo reply on $ETH_TEST_IFACE"
if ! sudo ETH_TEST_IFACE="$ETH_TEST_IFACE" ETH_TEST_SUBNET="$ETH_TEST_SUBNET" \
        ETH_TEST_MAC="$ETH_TEST_MAC" ICMP_TEST_NEGATIVE_FIRST=1 \
        python3 "$REPO_ROOT/scripts/eth_icmp_echo_test.py" \
        > >(tee "$ICMP_LOG") 2>&1; then
    echo "FAIL kernel/rpi5: ICMP integration failed (see $ICMP_LOG)" >&2
    exit 1
fi
echo "[kernel/rpi5] ICMP integration passed"

echo "[kernel/rpi5] checking TCP echo lifecycle on $ETH_TEST_IFACE"
if ! sudo ETH_TEST_IFACE="$ETH_TEST_IFACE" ETH_TEST_SUBNET="$ETH_TEST_SUBNET" \
        ETH_TEST_MAC="$ETH_TEST_MAC" \
        python3 "$REPO_ROOT/scripts/eth_tcp_echo_test.py" \
        > >(tee "$TCP_LOG") 2>&1; then
    echo "FAIL kernel/rpi5: TCP integration failed (see $TCP_LOG)" >&2
    exit 1
fi
echo "[kernel/rpi5] TCP integration passed"

echo "[kernel/rpi5] checking userspace connected I/O on port 8080"
if ! sudo ETH_TEST_IFACE="$ETH_TEST_IFACE" ETH_TEST_SUBNET="$ETH_TEST_SUBNET" \
        ETH_TEST_MAC="$ETH_TEST_MAC" TCP_TEST_PORT=8080 \
        TCP_TEST_CONNECTED_IO=1 \
        python3 "$REPO_ROOT/scripts/eth_tcp_echo_test.py" \
        > >(tee "$SOCKET_ACCEPT_LOG") 2>&1; then
    echo "FAIL kernel/rpi5: userspace connected I/O failed (see $SOCKET_ACCEPT_LOG)" >&2
    exit 1
fi
echo "[kernel/rpi5] userspace connected I/O passed"

# USB Mass Storage may briefly report Not Ready after enumeration. Keep the
# single capture alive through its bounded readiness loop and ext2 checks.
# This is host-side progress only: no temporary debug UART messages are added
# to the kernel. Stop as soon as the stable final resource marker arrives,
# while retaining a deadline for a hung kernel.
capture_deadline="${RPI5_KERNEL_CAPTURE_SECONDS:-90}"
capture_elapsed=0
capture_complete=0
while [ "$capture_elapsed" -lt "$capture_deadline" ]; do
    sleep 1
    capture_elapsed=$((capture_elapsed + 1))
    if LC_ALL=C grep -aFq 'resources: pages=0' "$UART_LOG"; then
        capture_complete=1
        break
    fi
    if [ $((capture_elapsed % 5)) -eq 0 ]; then
        echo "[kernel/rpi5] running integration checks: ${capture_elapsed}s elapsed"
    fi
done
if [ "$capture_complete" -eq 1 ]; then
    echo "[kernel/rpi5] integration completion observed after ${capture_elapsed}s"
else
    echo "[kernel/rpi5] completion marker not observed before ${capture_deadline}s deadline" >&2
fi
cleanup
trap - EXIT INT TERM HUP
tr -d '\r' <"$UART_LOG" >"$UART_LOG.normalized"

# One boot, several independent views. Each filter projects the shared UART
# transcript onto one contract, whose expected file is then compared exactly.
# Adding a subsystem test does not require another reset/load cycle.
view_count=0
for filter in "$VIEW_DIR"/*.filter; do
    [ -e "$filter" ] || continue
    name="$(basename "$filter" .filter)"
    expected="$VIEW_DIR/$name.expected"
    actual="$ARTIFACT_DIR/$name.actual"
    if [ ! -f "$expected" ]; then
        echo "error: missing expected file for kernel view $name" >&2
        exit 1
    fi
    LC_ALL=C grep -E -f "$filter" "$UART_LOG.normalized" >"$actual" || true
    if ! cmp -s "$expected" "$actual"; then
        echo "FAIL kernel/rpi5 view: $name" >&2
        diff -u "$expected" "$actual" >&2 || true
        echo "artifacts: $ARTIFACT_DIR" >&2
        exit 1
    fi
    echo "PASS kernel/rpi5 view: $name"
    view_count=$((view_count + 1))
done

if [ "$view_count" -eq 0 ]; then
    echo "error: no kernel integration views found under $VIEW_DIR" >&2
    exit 1
fi

echo "PASS kernel/rpi5 ($view_count views, one boot)"
