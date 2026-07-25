#!/usr/bin/env bash
# Raspberry Pi 5 hardware integration test runner -- called from repo root via:
# make hwcheck-rpi5
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SERIAL_DEV="${RPI5_SERIAL_DEV:-$("$REPO_ROOT/scripts/rpi5_uart_dev.sh")}"
ELF="$REPO_ROOT/examples/start/kernel_rpi5.elf"
POLL_INTERVAL=0.05
CAPTURE_MAX_SECS=5
STABLE_POLLS_NEEDED=6

if [ -z "$SERIAL_DEV" ] || [ ! -e "$SERIAL_DEV" ]; then
    echo "error: could not resolve the Raspberry Pi 5 UART device (found: '$SERIAL_DEV')" >&2
    echo "is the Debug Probe UART cable connected to GPIO14/15?" >&2
    exit 1
fi

stty -F "$SERIAL_DEV" 115200 raw -echo
work_dir=$(mktemp -d)
uart_log="$work_dir/uart.log"
loader_log="$work_dir/loader.log"
expected="$work_dir/expected.log"
reader_pid=""

cleanup() {
    if [ -n "$reader_pid" ]; then
        kill "$reader_pid" 2>/dev/null || true
        wait "$reader_pid" 2>/dev/null || true
    fi
    rm -rf "$work_dir"
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

printf 'foo(5)=1\r\nbar(3,4)=0\r\nbar(1,10)=1\r\n' > "$expected"
: > "$uart_log"
cat "$SERIAL_DEV" > "$uart_log" 2>/dev/null &
reader_pid=$!

# Attach the reader before injection: start.tkb prints immediately after PCIe
# enumeration, and opening the tty afterward can lose the beginning.
sleep 0.2
if ! "$REPO_ROOT/scripts/rpi5_jtag_load.sh" "$ELF" > "$loader_log" 2>&1; then
    cat "$loader_log" >&2
    echo "FAIL: RPi5 start (SWD injection failed)" >&2
    exit 1
fi

max_polls=$(awk -v m="$CAPTURE_MAX_SECS" -v i="$POLL_INTERVAL" 'BEGIN{printf "%d", m/i}')
last_size=-1
stable=0
seen_any=0
for ((poll = 0; poll < max_polls; poll++)); do
    sleep "$POLL_INTERVAL"
    size=$(stat -c%s "$uart_log" 2>/dev/null || echo 0)
    [ "$size" -gt 0 ] && seen_any=1
    if [ "$seen_any" -eq 1 ] && [ "$size" -eq "$last_size" ]; then
        stable=$((stable + 1))
        [ "$stable" -ge "$STABLE_POLLS_NEEDED" ] && break
    else
        stable=0
    fi
    last_size=$size
done

kill "$reader_pid" 2>/dev/null || true
wait "$reader_pid" 2>/dev/null || true
reader_pid=""

if cmp -s "$expected" "$uart_log"; then
    echo "PASS: RPi5 start (SWD injection + RP1 UART exact output)"
    exit 0
fi

echo "FAIL: RPi5 start UART output mismatch" >&2
echo "expected:" >&2
od -An -tx1c "$expected" >&2
echo "actual:" >&2
od -An -tx1c "$uart_log" >&2
echo "loader log:" >&2
cat "$loader_log" >&2
exit 1
