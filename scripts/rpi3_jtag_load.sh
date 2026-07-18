#!/usr/bin/env bash
# Injects a bare-metal ELF into a Raspberry Pi 3B (BCM2837) over JTAG and
# runs it -- see examples/common_rpi3/AGENTS.md for the full rationale.
#
# Unlike scripts/run_hwtest_ram.sh's `reset halt` (a real hardware reset,
# safe on STM32 because startup_ram.S's own vector table is what a fresh
# reset lands on), this board's 6-pin GPIO JTAG header (GPIO22-27) has no
# wired system reset line, so OpenOCD cannot use reset to reach a clean
# state -- only a physical power cycle can. See ram_load_and_run's
# comment in run_hwtest_ram.sh for the same "why not reset" question on
# STM32 (there reset is fine; here it is not, for the reason above).
#
# Safety check: this script refuses to inject unless the halted core's
# MMU is off. This is the actual invariant that matters -- not "is PC
# inside jtag_stub.S's tiny address range". A live Raspbian boot always
# has its MMU on (confirmed empirically: EL1H, MMU/D-Cache/I-Cache all
# "enabled"), while examples/common_rpi3/jtag_stub.S's spin loop AND
# every bare-metal payload this script itself has ever injected leave
# the core with MMU/caches off (startup.S never enables them). That
# means catching a PREVIOUS run's own injected payload -- still parked
# in its own halt loop, not the stub -- is exactly as safe to overwrite
# as catching the stub itself, so only ONE power cycle is needed per
# Raspbian boot, not one per injection: run this script (or
# scripts/run_hwtest_rpi3.sh, which calls it once per example) as many
# times in a row as needed afterward.
set -euo pipefail

ELF="${1:-examples/hello/kernel_rpi3.elf}"

if [ ! -f "$ELF" ]; then
    echo "error: $ELF not found -- build it first (make $ELF)" >&2
    exit 1
fi

entry_pc="0x$(llvm-readelf-19 -h "$ELF" | awk '/Entry point address/{sub(/^0x/,"",$NF); print $NF}')"
stack_top="0x$(llvm-nm-19 "$ELF" | awk '$3=="stack_top"{print $1}')"

if [ -z "${entry_pc#0x}" ] || [ -z "${stack_top#0x}" ]; then
    echo "error: could not read entry point / stack_top from $ELF" >&2
    exit 1
fi

echo "target ELF:  $ELF"
echo "entry PC:    $entry_pc"
echo "initial SP:  $stack_top"

OPENOCD_ARGS=(
    -f interface/ftdi/olimex-arm-usb-tiny-h.cfg
    -c 'transport select jtag'
    -f target/bcm2837.cfg
    -c 'adapter speed 1000'
)

# Pass 1: halt, read PC + MMU state, resume immediately -- read-only, so
# even if this turns out to be still-running Raspbian, it only sees a
# momentary debug stall (same as the read-only register dump this
# script's rationale comment was validated with), not a corrupted
# PC/SP. The safety decision happens in bash afterward, from this log,
# BEFORE any write ever occurs.
CHECK_LOG=$(mktemp)
if ! openocd "${OPENOCD_ARGS[@]}" \
    -c 'init' \
    -c 'halt' \
    -c 'reg pc' \
    -c 'resume' \
    -c 'shutdown' > "$CHECK_LOG" 2>&1
then
    echo "error: openocd failed during PC/MMU check -- log follows" >&2
    cat "$CHECK_LOG" >&2
    rm -f "$CHECK_LOG"
    exit 1
fi

halted_pc=$(awk '/^pc \(/{print $3}' "$CHECK_LOG" | head -1)
mmu_state=$(grep -oE 'MMU: (enabled|disabled)' "$CHECK_LOG" | head -1 | awk '{print $2}')
rm -f "$CHECK_LOG"

if [ -z "$mmu_state" ]; then
    echo "error: could not parse MMU state from openocd output -- log follows" >&2
    cat "$CHECK_LOG" >&2
    exit 1
fi

if [ "$mmu_state" != "disabled" ]; then
    echo "error: halted core has MMU $mmu_state (PC=$halted_pc) -- this is" \
         "almost certainly still-running Raspbian, not a bare-metal" \
         "payload. Refusing to inject (would corrupt the running OS)." \
         "Flash examples/common_rpi3/jtag_stub.img as kernel8.img and" \
         "power-cycle the board first. (The board was left running" \
         "exactly as found -- this check only read/resumed, it never" \
         "wrote anything.)" >&2
    exit 1
fi
echo "halted core has MMU off (PC=$halted_pc) -- safe to inject"

# Pass 2: only reached once the check above confirms a clean catch. Halts
# the (already resumed) core again, loads the real payload, points PC/SP
# at its entry, and resumes into it for real.
LOG=$(mktemp)
if ! openocd "${OPENOCD_ARGS[@]}" \
    -c 'init' \
    -c 'halt' \
    -c "load_image $ELF 0 elf" \
    -c "reg sp $stack_top" \
    -c "reg pc $entry_pc" \
    -c 'resume' \
    -c 'shutdown' > "$LOG" 2>&1
then
    echo "error: openocd failed during injection -- log follows" >&2
    cat "$LOG" >&2
    rm -f "$LOG"
    exit 1
fi

echo "injected $ELF and resumed (PC=$entry_pc SP=$stack_top)"
cat "$LOG"
rm -f "$LOG"
