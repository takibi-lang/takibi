#!/usr/bin/env bash
# Inject the standalone kernel and attach miniterm to the RPi5 UART.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ELF="$REPO_ROOT/kernel/build/rpi5/kernel.elf"
SERIAL_DEV="${RPI5_SERIAL_DEV:-$("$REPO_ROOT/scripts/rpi5_uart_dev.sh")}"

if ! python3 -c 'import serial' >/dev/null 2>&1; then
    echo "error: pyserial is required; install it with: sudo apt-get install python3-serial" >&2
    exit 1
fi
if [ -z "$SERIAL_DEV" ] || [ ! -e "$SERIAL_DEV" ]; then
    echo "error: RPi5 UART device not found: '$SERIAL_DEV'" >&2
    exit 1
fi

stty -F "$SERIAL_DEV" 115200 raw -echo
echo "[kernel/rpi5] resetting resident image before SWD load"
"$REPO_ROOT/scripts/rpi5_jtag_reset.sh" --resident-image-unchanged
echo "[kernel/rpi5] loading kernel over SWD"
"$REPO_ROOT/scripts/rpi5_jtag_load.sh" "$ELF"
echo "[kernel/rpi5] starting UART console on $SERIAL_DEV"
# Keep miniterm in the foreground: pyserial's Console() needs fd 0 to remain
# the real terminal. A background miniterm inherits /dev/null as stdin under
# non-interactive shells such as make and fails with ENOTTY. The kernel waits
# in ash's UART read path, so starting the console after SWD injection does
# not lose the interactive session.
exec python3 -m serial.tools.miniterm --raw --eol LF --echo "$SERIAL_DEV" 115200
