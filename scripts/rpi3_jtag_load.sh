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
# Safety check: this script refuses to inject unless the halted core is
# at EL2H. This is the actual invariant that matters -- not "is PC
# inside jtag_stub.S's tiny address range", and NOT MMU state (an
# earlier version of this check used MMU-off as the signal, back when
# nothing here ever turned the MMU on -- see examples/common_rpi3/
# mmu.S's header comment for why every payload now enables the MMU, an
# unaligned-access fix that makes the old "MMU off" signal self-
# contradictory: our own payloads leave the core with MMU ON now, same
# as Raspbian). A live Raspbian boot always halts at EL1H (Linux always
# runs the kernel at EL1 -- confirmed empirically), while
# examples/common_rpi3/jtag_stub.S's spin loop AND every bare-metal
# payload this script itself has ever injected run at EL2H (the GPU
# firmware/ARM Trusted Firmware hands off at EL2, and nothing here ever
# changes exception level). That means catching a PREVIOUS run's own
# injected payload -- still parked in its own halt loop, not the stub --
# is exactly as safe to overwrite as catching the stub itself, so only
# ONE power cycle is needed per Raspbian boot, not one per injection:
# run this script (or scripts/run_hwtest_rpi3.sh, which calls it once
# per example) as many times in a row as needed afterward.
set -euo pipefail

ELF="${1:-examples/start/kernel_rpi3.elf}"

if [ ! -f "$ELF" ]; then
    echo "error: $ELF not found -- build it first (make $ELF)" >&2
    exit 1
fi

entry_pc="0x$(llvm-readelf-19 -h "$ELF" | awk '/Entry point address/{sub(/^0x/,"",$NF); print $NF}')"
stack_top="0x$(llvm-nm-19 "$ELF" | awk '$3=="stack_top"{print $1}')"
smp_core1_stack_top="0x$(llvm-nm-19 "$ELF" | awk '$3=="smp_core1_stack_top"{print $1}')"
smp_secondary_entry="0x$(llvm-nm-19 "$ELF" | awk '$3=="rpi3_secondary_start"{print $1}')"

if [ -z "${entry_pc#0x}" ] || [ -z "${stack_top#0x}" ]; then
    echo "error: could not read entry point / stack_top from $ELF" >&2
    exit 1
fi

echo "target ELF:  $ELF"
echo "entry PC:    $entry_pc"
echo "initial SP:  $stack_top"

SMP_CORES="${RPI3_SMP_CORES:-0}"
if [ "$SMP_CORES" != "0" ] && [ "$SMP_CORES" != "2" ] && [ "$SMP_CORES" != "4" ]; then
    echo "error: RPI3_SMP_CORES must be 0, 2, or 4" >&2
    exit 1
fi
if [ "$SMP_CORES" != "0" ] && { [ -z "${smp_core1_stack_top#0x}" ] || [ -z "${smp_secondary_entry#0x}" ]; }; then
    echo "error: SMP load requested but its core-1 entry/stack symbols are absent from $ELF" >&2
    exit 1
fi

OPENOCD_ARGS=(
    -f interface/ftdi/olimex-arm-usb-tiny-h.cfg
    -c 'transport select jtag'
    -f target/bcm2837.cfg
    -c 'adapter speed 1000'
)

# Pass 1: halt, read PC + current exception level, resume immediately -- read-only, so
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
current_mode=$(grep -oE 'current mode: EL[0-9][A-Za-z]' "$CHECK_LOG" | head -1 | awk '{print $3}')
rm -f "$CHECK_LOG"

if [ -z "$current_mode" ]; then
    echo "error: could not parse current exception level from openocd output -- log follows" >&2
    cat "$CHECK_LOG" >&2
    exit 1
fi

if [ "$current_mode" != "EL2H" ]; then
    echo "error: halted core is at $current_mode, not EL2H (PC=$halted_pc)" \
         "-- this is almost certainly still-running Raspbian (Linux" \
         "always runs at EL1), not a bare-metal payload. Refusing to" \
         "inject (would corrupt the running OS). If kernel8.img on the" \
         "SD card is already examples/common_rpi3/jtag_stub.img, run" \
         "scripts/rpi3_jtag_reset.sh (a full chip reset over JTAG, no" \
         "physical access needed); otherwise flash it first (see" \
         "scripts/rpi3_prepare_sdcard.sh) and power-cycle the board." \
         "(The board was left running exactly as found -- this check" \
         "only read/resumed, it never wrote anything.)" >&2
    exit 1
fi
echo "halted core is at EL2H (PC=$halted_pc) -- safe to inject"

# Pass 2: only reached once the check above confirms a clean catch. Halts
# core 0, loads the real payload, points PC/SP at its entry, and resumes it.
# For the opt-in two-core fixture, core 0 gets 200ms to build the shared page
# tables and reach its mailbox wait before core 1 is redirected from the
# persistent JTAG stub to the same _start entry.
LOG=$(mktemp)
LOAD_COMMANDS=(
    -c 'init'
    -c 'targets bcm2837.cpu0'
    -c 'halt'
    -c "load_image $ELF 0 elf"
    -c "reg sp $stack_top"
    -c "reg pc $entry_pc"
    -c 'resume'
)
if [ "$SMP_CORES" = "2" ]; then
    LOAD_COMMANDS+=(
        -c 'sleep 200'
        -c 'targets bcm2837.cpu1'
        -c 'halt'
        -c "reg sp $smp_core1_stack_top"
        -c "reg pc $smp_secondary_entry"
        -c 'resume'
    )
fi
if [ "$SMP_CORES" = "4" ]; then
    LOAD_COMMANDS+=(-c 'sleep 200')
    for core_id in 1 2 3; do
        core_stack_symbol="smp_core${core_id}_stack_top"
        core_stack="0x$(llvm-nm-19 "$ELF" | awk -v symbol="$core_stack_symbol" '$3==symbol{print $1}')"
        if [ -z "${core_stack#0x}" ]; then
            echo "error: SMP load requested but $core_stack_symbol is absent from $ELF" >&2
            exit 1
        fi
        LOAD_COMMANDS+=(
            -c "targets bcm2837.cpu$core_id"
            -c 'halt'
            -c "reg sp $core_stack"
            -c "reg pc $smp_secondary_entry"
            -c 'resume'
        )
    done
fi
LOAD_COMMANDS+=(-c 'shutdown')

if ! openocd "${OPENOCD_ARGS[@]}" "${LOAD_COMMANDS[@]}" > "$LOG" 2>&1
then
    echo "error: openocd failed during injection -- log follows" >&2
    cat "$LOG" >&2
    rm -f "$LOG"
    exit 1
fi

echo "injected $ELF and resumed (PC=$entry_pc SP=$stack_top)"
cat "$LOG"
rm -f "$LOG"
