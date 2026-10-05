#!/usr/bin/env bash
# Own the shared board for the complete six-boot comparison, including resets.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
. "$ROOT/scripts/resource_lease.sh"
resource_lease_acquire rpi5 "pool-retention-comparison"
UART="${RPI5_SERIAL_DEV:-$("$ROOT/scripts/rpi5_uart_dev.sh")}"
if [ ! -e "$UART" ]; then
    echo "error: RPi5 UART device not found: $UART" >&2
    exit 1
fi
status=0
python3 "$ROOT/kernel/benchmarks/pool_retention/run_rpi5.py" --serial "$UART" "$@" || status=$?
if [ "$status" = 10 ]; then
    resource_lease_board_failed
elif [ "$status" = 0 ]; then
    resource_lease_board_ok
fi
exit "$status"
