#!/usr/bin/env bash
# Set one named byte in the kernel already loaded by the calling hardware test.
set -euo pipefail

ELF="$1"
SYMBOL="$2"
VALUE="$3"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BCM2712_CFG="$REPO_ROOT/examples/common_rpi5/bcm2712.cfg"
address="0x$(llvm-nm-19 "$ELF" | awk -v symbol="$SYMBOL" '$3 == symbol { print $1 }')"
if [ -z "${address#0x}" ]; then
    echo "error: symbol not found in $ELF: $SYMBOL" >&2
    exit 1
fi
speed_args=()
if [ -n "${RPI5_SWD_SPEED:-}" ]; then
    speed_args=(-c "adapter speed $RPI5_SWD_SPEED")
fi
timeout --foreground 20 openocd \
    -f interface/cmsis-dap.cfg -f "$BCM2712_CFG" "${speed_args[@]}" \
    -c init -c 'targets bcm2712.cpu0' -c halt \
    -c "mwb $address $VALUE" -c resume -c shutdown
