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
if ! "$REPO_ROOT/scripts/rpi5_jtag_load.sh" "$ELF" >"$LOADER_LOG" 2>&1; then
    echo "FAIL kernel/rpi5: load failed (see $LOADER_LOG)" >&2
    exit 1
fi

sleep 3
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
