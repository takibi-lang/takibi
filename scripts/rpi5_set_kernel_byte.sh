#!/usr/bin/env bash
# Set one named byte in the kernel already loaded by the calling hardware test.
#
# OpenOCD writes memory by making the selected core do the access, so the core
# must be stopped in EL1 before it touches a kernel address. Both active cores
# may now be running EL0 code. Catch core 0 at rpi5_irq_dispatch_inner with a
# temporary hardware breakpoint; its periodic timer takes it there without an
# external timing race, rather than depending on which exception level an
# asynchronous halt happens to hit.
# A halt in EL0 fails like this:
#
#   bcm2712.cpu0 halted in AArch64 state due to debug-request, mode: EL0T
#   Error: Opcode 0x38001401, DSCR.ERR=1, DSCR.EL=1
#
# The write stays a CPU-side write, so it is coherent with both cores in a way
# that a physical access through the DAP would not be. The read-back and the
# OpenOCD error scan below are both required: OpenOCD 0.12 returns status zero
# after DSCR.ERR, which previously turned a failed write into a later and
# misleading "unknown command" from DDB.
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
irq_address="0x$(llvm-nm-19 "$ELF" | awk '$3 == "rpi5_irq_dispatch_inner" && !seen { print $1; seen = 1 }')"
if [ -z "${irq_address#0x}" ]; then
    echo "error: rpi5_irq_dispatch_inner not found in $ELF" >&2
    exit 1
fi
speed_args=()
if [ -n "${RPI5_SWD_SPEED:-}" ]; then
    speed_args=(-c "adapter speed $RPI5_SWD_SPEED")
fi
log="$(mktemp)"
cleanup() {
    rm -f "$log"
}
trap cleanup EXIT INT TERM HUP
status=0
timeout --foreground 20 openocd \
    -f interface/cmsis-dap.cfg -f "$BCM2712_CFG" "${speed_args[@]}" \
    -c init -c 'targets bcm2712.cpu0' -c halt \
    -c "bp $irq_address 4 hw" -c resume -c 'wait_halt 5000' \
    -c "mwb $address $VALUE" -c "mdb $address 1" \
    -c "rbp $irq_address" -c resume -c shutdown >"$log" 2>&1 || status=$?
cat "$log"
if [ "$status" -ne 0 ] || grep -Eq '(^| )(Error|error):|DSCR\.ERR|timed out' "$log"; then
    echo "error: OpenOCD could not set $SYMBOL" >&2
    exit 1
fi
expected_hex="$(printf '%02x' "$VALUE")"
address_hex="$(printf '%x' "$address")"
if ! grep -Eiq "0*${address_hex}: +${expected_hex}([[:space:]]|$)" "$log"; then
    echo "error: OpenOCD read-back did not confirm $SYMBOL=$VALUE" >&2
    exit 1
fi
