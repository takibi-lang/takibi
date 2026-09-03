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
ARTIFACT_DIR="${KERNEL_RPI5_SHELL_ARTIFACT_DIR:-$REPO_ROOT/_build/kernel-shell-rpi5}"
TRANSCRIPT_OVERRIDE="${KERNEL_SHELL_TRANSCRIPT:-}"

# See run_kernel_shell_qemu.sh: Make's normal -Oline setting captures this
# long-lived recipe's standard streams. The shell must instead attach directly
# to the invoking terminal so miniterm can display ash and receive keystrokes.
if { [ ! -t 0 ] || [ ! -t 1 ]; }; then
    if [ ! -r /dev/tty ] || [ ! -w /dev/tty ]; then
        echo "error: kernelsh-rpi5 requires an interactive terminal" >&2
        exit 1
    fi
    exec </dev/tty >/dev/tty 2>&1
fi

if ! python3 -c 'import serial' >/dev/null 2>&1; then
    echo "error: pyserial is required; install it with: sudo apt-get install python3-serial" >&2
    exit 1
fi
# The board is shared by every clone of this repository; take its lease before
# touching the device. An interactive session holds it until the console exits.
. "$REPO_ROOT/scripts/hardware_lease.sh"
hardware_lease_acquire rpi5 "kernelsh-rpi5" || exit 1
if [ -z "$SERIAL_DEV" ] || [ ! -e "$SERIAL_DEV" ]; then
    echo "error: RPi5 UART device not found: '$SERIAL_DEV'" >&2
    exit 1
fi

mkdir -p "$ARTIFACT_DIR"
if [ -n "$TRANSCRIPT_OVERRIDE" ]; then
    TRANSCRIPT="$TRANSCRIPT_OVERRIDE"
    mkdir -p "$(dirname "$TRANSCRIPT")"
    if [ -e "$TRANSCRIPT" ]; then
        echo "error: refusing to overwrite UART transcript: $TRANSCRIPT" >&2
        exit 1
    fi
else
    TRANSCRIPT="$ARTIFACT_DIR/uart-transcript.log"
    rm -f "$TRANSCRIPT"
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
NETWORK_PEER_LOG="${RPI5_SHELL_NETWORK_LOG:-$ARTIFACT_DIR/network-peer.log}"
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
export KERNEL_SHELL_TRANSCRIPT="$TRANSCRIPT"
cleanup() {
    if [ -n "$NETWORK_PEER_PID" ]; then
        kill "$NETWORK_PEER_PID" 2>/dev/null || true
        wait "$NETWORK_PEER_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM HUP
python3 "$REPO_ROOT/scripts/run_kernel_shell_console.py" "$SERIAL_DEV" 115200
