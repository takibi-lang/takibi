#!/usr/bin/env bash
# Set one named byte in the kernel already loaded by the calling hardware test.
#
# Written through core 1, not core 0. OpenOCD writes memory by halting a core
# and making it do the access, so the core has to be somewhere that can see a
# kernel address -- and core 0 is wherever the workload left it. That used to
# be inside the kernel almost always, because a daemon waiting in accept(2)
# held EL1 for its whole timeout; GitHub issue #469 made that wait yield, so
# core 0 is now usually running EL0 code and the write faults:
#
#   bcm2712.cpu0 halted in AArch64 state due to debug-request, mode: EL0T
#   Error: Opcode 0x38001401, DSCR.ERR=1, DSCR.EL=1
#
# Core 1 reaches EL1, proves it can see the shared page table, and parks
# there for the rest of the boot (kernel_secondary_boot_probe). It is
# therefore always in the kernel, always has the mapping, and is doing
# nothing that halting it can disturb. The write stays a CPU-side write, so
# it is coherent with core 0 the way a `phys` access through the DAP would
# not be.
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
    -c init -c 'targets bcm2712.cpu1' -c halt \
    -c "mwb $address $VALUE" -c resume -c shutdown
