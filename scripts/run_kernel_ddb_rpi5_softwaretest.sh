#!/usr/bin/env bash
# Physical-RPi5 deliberate-BRK regression: halt at the checkpoint before its
# test byte is read, arm it, inspect the compiler-owned frame chain through
# DDB, then resume the same boot.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SERIAL_DEV="${RPI5_SERIAL_DEV:-$($REPO_ROOT/scripts/rpi5_uart_dev.sh)}"
ELF="$REPO_ROOT/kernel/build/rpi5/kernel.elf"
ARTIFACT_DIR="${RPI5_DDB_SOFTWARE_ARTIFACT_DIR:-$REPO_ROOT/_build/kernel-ddb-rpi5-software}"
UART_LOG="$ARTIFACT_DIR/uart.log"
RESET_LOG="$ARTIFACT_DIR/reset.log"
LOADER_LOG="$ARTIFACT_DIR/loader.log"

mkdir -p "$ARTIFACT_DIR"
exec 9>"$ARTIFACT_DIR/runner.lock"
if ! flock -n 9; then
    echo "FAIL kernel/rpi5 ddb: another runner owns $ARTIFACT_DIR" >&2
    exit 1
fi
. "$REPO_ROOT/scripts/resource_lease.sh"
resource_lease_acquire rpi5 "kernelcheck-ddb-rpi5-software" || exit 1

if [ ! -e "$SERIAL_DEV" ]; then
    echo "error: RPi5 UART device not found: $SERIAL_DEV" >&2
    exit 1
fi
if [ ! -f "$ELF" ]; then
    echo "error: kernel ELF not found: $ELF" >&2
    exit 1
fi
if ! python3 -c 'import serial' >/dev/null 2>&1; then
    echo "error: pyserial is required" >&2
    exit 1
fi

generated_start="0x$(llvm-nm-19 "$ELF" |
    awk '$3=="kernel_generated_text_start"{print $1; exit}')"
generated_end="0x$(llvm-nm-19 "$ELF" |
    awk '$3=="kernel_generated_text_end"{print $1; exit}')"
if [ -z "${generated_start#0x}" ] || [ -z "${generated_end#0x}" ]; then
    echo "error: compiler-generated text bounds absent from $ELF" >&2
    exit 1
fi

stty -F "$SERIAL_DEV" 115200 raw -echo
echo "[kernel/rpi5 ddb] resetting board"
if ! "$REPO_ROOT/scripts/rpi5_jtag_reset.sh" \
        --resident-image-unchanged >"$RESET_LOG" 2>&1; then
    echo "FAIL kernel/rpi5 ddb: reset failed (see $RESET_LOG)" >&2
    resource_lease_board_failed
    exit 1
fi
timeout 1 cat "$SERIAL_DEV" >/dev/null 2>&1 || true

python3 "$REPO_ROOT/scripts/run_kernel_ddb_rpi5_software_driver.py" \
    --port "$SERIAL_DEV" --log "$UART_LOG" \
    --generated-start "$generated_start" --generated-end "$generated_end" &
driver_pid=$!
cleanup() {
    status=$?
    if kill -0 "$driver_pid" 2>/dev/null; then
        kill "$driver_pid" 2>/dev/null || true
    fi
    wait "$driver_pid" 2>/dev/null || true
    if [ "$status" -ne 0 ]; then
        bash "$REPO_ROOT/scripts/archive_kernel_failure.sh" "$ARTIFACT_DIR" \
            "$REPO_ROOT/_build/kernel-ddb-rpi5-software-failures" \
            "exit status $status" || true
    fi
}
trap cleanup EXIT INT TERM HUP

sleep 0.2
echo "[kernel/rpi5 ddb] loading checkpointed kernel over SWD"
if ! RPI5_ARM_KERNEL_DDB_BREAKPOINT=1 \
        "$REPO_ROOT/scripts/rpi5_jtag_load.sh" "$ELF" \
        >"$LOADER_LOG" 2>&1; then
    echo "FAIL kernel/rpi5 ddb: load failed (see $LOADER_LOG)" >&2
    resource_lease_board_failed
    exit 1
fi
resource_lease_board_ok

wait "$driver_pid"
trap - EXIT INT TERM HUP
