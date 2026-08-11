#!/usr/bin/env bash
# Inject the standalone kernel and attach miniterm to the RPi5 UART.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ELF="$REPO_ROOT/kernel/build/rpi5/kernel.elf"
SERIAL_DEV="${RPI5_SERIAL_DEV:-$("$REPO_ROOT/scripts/rpi5_uart_dev.sh")}"
ETH_TEST_IFACE="${ETH_TEST_IFACE:-enp5s0}"
ETH_TEST_SUBNET="${ETH_TEST_SUBNET:-192.168.20}"
ETH_TEST_MAC="${ETH_TEST_MAC:-02:00:20:00:00:02}"
ETH_TEST_HOST_IP="${ETH_TEST_HOST_IP:-192.168.20.1}"

if ! python3 -c 'import serial' >/dev/null 2>&1; then
    echo "error: pyserial is required; install it with: sudo apt-get install python3-serial" >&2
    exit 1
fi
if [ -z "$SERIAL_DEV" ] || [ ! -e "$SERIAL_DEV" ]; then
    echo "error: RPi5 UART device not found: '$SERIAL_DEV'" >&2
    exit 1
fi

stty -F "$SERIAL_DEV" 115200 raw -echo
SHELL_LAUNCH_NS="$(date +%s%N)"
echo "[kernel/rpi5] resetting resident image before SWD load"
reset_started="$(date +%s%N)"
"$REPO_ROOT/scripts/rpi5_jtag_reset.sh" --resident-image-unchanged
reset_finished="$(date +%s%N)"
echo "[kernel/rpi5] reset completed in $(( (reset_finished - reset_started) / 1000000 )) ms"
echo "[kernel/rpi5] loading kernel over SWD"
load_started="$(date +%s%N)"
"$REPO_ROOT/scripts/rpi5_jtag_load.sh" "$ELF"
load_finished="$(date +%s%N)"
echo "[kernel/rpi5] load completed in $(( (load_finished - load_started) / 1000000 )) ms"

NETWORK_PEER_PID=""
NETWORK_PEER_LOG="${RPI5_SHELL_NETWORK_LOG:-$REPO_ROOT/_build/kernel-shell-rpi5/network-peer.log}"
if [ "${KERNEL_RPI5_SHELL_NETWORK_PEER:-1}" = 1 ]; then
    mkdir -p "$(dirname "$NETWORK_PEER_LOG")"
    : >"$NETWORK_PEER_LOG"
    echo "[kernel/rpi5] starting host-side network peer on $ETH_TEST_IFACE"
    (
        set -euo pipefail
        sudo -n ETH_TEST_IFACE="$ETH_TEST_IFACE" \
            ETH_TEST_SUBNET="$ETH_TEST_SUBNET" \
            ARP_TEST_REQUESTER_IP="$ETH_TEST_HOST_IP" \
            ARP_TEST_OTHER_FIRST=1 \
            python3 "$REPO_ROOT/scripts/eth_arp_reply_test.py"
        sudo -n ETH_TEST_IFACE="$ETH_TEST_IFACE" \
            ETH_TEST_SUBNET="$ETH_TEST_SUBNET" \
            ETH_TEST_MAC="$ETH_TEST_MAC" \
            ICMP_TEST_NEGATIVE_FIRST=1 \
            python3 "$REPO_ROOT/scripts/eth_icmp_echo_test.py"
        sudo -n ETH_TEST_IFACE="$ETH_TEST_IFACE" \
            ETH_TEST_SUBNET="$ETH_TEST_SUBNET" \
            ETH_TEST_MAC="$ETH_TEST_MAC" \
            python3 "$REPO_ROOT/scripts/eth_tcp_echo_test.py"
    ) >"$NETWORK_PEER_LOG" 2>&1 &
    NETWORK_PEER_PID=$!
fi
echo "[kernel/rpi5] starting UART console on $SERIAL_DEV"
# Keep miniterm in the foreground: pyserial's Console() needs fd 0 to remain
# the real terminal. A background miniterm inherits /dev/null as stdin under
# non-interactive shells such as make and fails with ENOTTY. The kernel waits
# in ash's UART read path, so starting the console after SWD injection does
# not lose the interactive session.
export KERNEL_SHELL_PLATFORM=rpi5
export KERNEL_SHELL_LAUNCH_NS="$SHELL_LAUNCH_NS"
cleanup() {
    if [ -n "$NETWORK_PEER_PID" ]; then
        kill "$NETWORK_PEER_PID" 2>/dev/null || true
        wait "$NETWORK_PEER_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM HUP
python3 "$REPO_ROOT/scripts/run_kernel_shell_console.py" "$SERIAL_DEV" 115200
