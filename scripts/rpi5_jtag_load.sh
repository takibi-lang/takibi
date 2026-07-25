#!/usr/bin/env bash
# Injects a bare-metal ELF into a Raspberry Pi 5 (BCM2712) over SWD, using
# the official Raspberry Pi Debug Probe (CMSIS-DAP) -- see
# examples/common_rpi5/AGENTS.md for the full rationale. Adapted from
# scripts/rpi3_jtag_load.sh; the two real differences from RPi3 are: (1)
# transport is SWD via a CMSIS-DAP interface, not JTAG via a generic FTDI
# adapter, and (2) the target config (examples/common_rpi5/bcm2712.cfg) is
# vendored in this repo, since upstream OpenOCD 0.12.0 does not ship one.
#
# Safety check, REDESIGNED for GitHub issue #165 (adding an RPi5 MMU path,
# examples/common_rpi5/mmu.S) -- the PREVIOUS "must be at EL2H with the
# MMU disabled" check (see git history) stopped being valid the moment
# our own payloads started calling mmu_init: every legitimate takibi
# kernel now runs with the MMU on too, so "MMU disabled" could no longer
# distinguish "ours" from "a live OS" without also refusing our own code.
#
# That EL2H+MMU-disabled check was itself already a correction of an
# earlier RPi3-style "must be at EL2H" check: a live, real-hardware
# connectivity test (2026-07-25) halted this board and found it sitting at
# EL2H with MMU/D-cache/I-cache all enabled and PC at a canonical
# high-kernel-VA address (0xffffd0...) -- i.e. genuinely running
# Raspberry Pi OS, not our stub. RPi3's own "EL2H means safe" assumption
# relied on Linux always dropping to EL1 (true on BCM2837/Cortex-A53,
# ARMv8.0), but BCM2712's Cortex-A76 is ARMv8.1+ and supports VHE
# (Virtualization Host Extensions): a VHE-enabled Linux kernel runs its
# WHOLE normal kernel at EL2H (HCR_EL2.E2H=1) rather than dropping to EL1
# at all. EL2H alone therefore does not distinguish live Raspberry Pi OS
# from our own code on this board -- that finding is still true and still
# part of this check.
#
# NEW discriminator: current mode == EL2H AND halted PC < RPI5_SAFE_PC_MAX
# (32MB, 0x02000000). Every takibi payload here (jtag_stub.S at 0x80000,
# every examples/*/kernel_rpi5.elf at 0x200000, see link.ld) executes
# from a fixed LOW physical address with the EL2 stage 1 MMU either off or
# identity-mapped -- comfortably under 32MB with over 100x headroom for
# growth. A live, fully-booted Raspberry Pi OS kernel, by contrast, runs
# from a canonical HIGH virtual address once its own MMU is up (confirmed
# empirically: 0xffffd0... above) -- nowhere near this range regardless of
# EL/MMU state, so this check no longer needs to care whether OUR MMU
# happens to be on. Deliberately does NOT depend on jtag_stub.S itself
# (no SD-card reflash required to deploy this change): PC range plus EL2H
# is sufficient using only information this script already reads.
#
# Known narrow gap, accepted rather than solved here: if OpenOCD's halt
# lands during genuine Raspberry Pi OS's own very early boot (before its
# MMU is up, while its own kernel Image still sits at a low physical
# load address and before it drops from EL2H to EL1), a low PC read alone
# cannot distinguish that from our own code either. This is a narrow race
# window compared to the realistic scenario this check exists for (the
# board sitting fully booted, e.g. at a login prompt), consistent with
# this project's existing incremental-safety approach -- MMU state is
# still logged below for diagnosis even though it no longer gates the
# decision.
set -euo pipefail

# Fixed-width (16 hex digit, zero-padded) hex string, matching OpenOCD's
# own "pc (/64): 0x----------------" format exactly -- compared with
# bash's [[ > ]] STRING comparison below, never arithmetic. A canonical
# high kernel VA (e.g. 0xffffd06fcf296448, the real value this check
# exists to catch -- see header comment) has its top bit set, which
# bash's $(( )) parses as a NEGATIVE signed 64-bit integer: confirmed by
# direct test that an arithmetic "-ge" comparison against that value
# evaluates false (wraps negative, so it reads as LESS than the safe
# threshold) and would have WRONGLY ACCEPTED an injection into a live
# kernel -- the exact failure this whole check exists to prevent. Two
# zero-padded, equal-length hex strings sort in the same order as their
# numeric magnitude, so plain string comparison sidesteps the overflow
# entirely without needing bignum arithmetic.
RPI5_SAFE_PC_MAX_HEX="0000000002000000"

ELF="${1:-examples/start/kernel_rpi5.elf}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BCM2712_CFG="$REPO_ROOT/examples/common_rpi5/bcm2712.cfg"

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
    -f interface/cmsis-dap.cfg
    -f "$BCM2712_CFG"
)

# Pass 1: halt, read PC + current exception level, resume immediately --
# read-only, same reasoning as rpi3_jtag_load.sh's own check pass.
CHECK_LOG=$(mktemp)
if ! openocd "${OPENOCD_ARGS[@]}" \
    -c 'init' \
    -c 'halt' \
    -c 'reg pc' \
    -c 'resume' \
    -c 'shutdown' > "$CHECK_LOG" 2>&1
then
    echo "error: openocd failed during PC/EL check -- log follows" >&2
    cat "$CHECK_LOG" >&2
    rm -f "$CHECK_LOG"
    exit 1
fi

halted_pc=$(awk '/^pc \(/{print $3}' "$CHECK_LOG" | head -1)
current_mode=$(grep -oE 'current mode: EL[0-9][A-Za-z]' "$CHECK_LOG" | head -1 | awk '{print $3}')
mmu_state=$(grep -oE 'MMU: (enabled|disabled)' "$CHECK_LOG" | head -1 | awk '{print $2}')

if [ -z "$current_mode" ] || [ -z "$mmu_state" ]; then
    echo "error: could not parse current exception level / MMU state from openocd output -- log follows" >&2
    cat "$CHECK_LOG" >&2
    rm -f "$CHECK_LOG"
    exit 1
fi
rm -f "$CHECK_LOG"

# Strip the 0x prefix and lowercase; OpenOCD's "pc (/64):" line is always
# a zero-padded 16-hex-digit value (confirmed across every real capture
# this script and its test session produced), matching
# RPI5_SAFE_PC_MAX_HEX's own width exactly -- required for the string
# comparison below to be a valid magnitude comparison (see that
# variable's own comment on why this is NOT done via arithmetic).
halted_pc_hex="${halted_pc#0x}"
halted_pc_hex="$(printf '%s' "$halted_pc_hex" | tr 'A-F' 'a-f')"
if [ "${#halted_pc_hex}" -ne 16 ]; then
    echo "error: unexpected PC format from openocd (want 16 hex digits): $halted_pc" >&2
    exit 1
fi

if [ "$current_mode" != "EL2H" ] || [[ "$halted_pc_hex" > "$RPI5_SAFE_PC_MAX_HEX" || "$halted_pc_hex" == "$RPI5_SAFE_PC_MAX_HEX" ]]; then
    printf 'error: halted core is at %s with PC=%s (MMU %s) -- this looks\n' \
         "$current_mode" "$halted_pc" "$mmu_state" >&2
    printf 'like a genuinely running Raspberry Pi OS, not our own\n' >&2
    printf 'stub/payload (every takibi RPi5 payload runs from a fixed low\n' >&2
    printf 'physical address below 0x%s -- see this scripts own header\n' \
         "$RPI5_SAFE_PC_MAX_HEX" >&2
    printf 'comment). Refusing to inject (would corrupt the running OS). If\n' >&2
    printf 'kernel_2712.img on the SD card is already\n' >&2
    printf 'examples/common_rpi5/jtag_stub.img, run\n' >&2
    printf 'scripts/rpi5_jtag_reset.sh; otherwise flash it first and\n' >&2
    printf 'power-cycle the board. (The board was left running exactly as\n' >&2
    printf 'found -- this check only read/resumed, it never wrote anything.)\n' >&2
    exit 1
fi
echo "halted core is at EL2H with PC=$halted_pc (< 0x$RPI5_SAFE_PC_MAX_HEX, MMU $mmu_state) -- safe to inject"

# Pass 2: only reached once the check above confirms a clean catch. Load the
# shared physical RAM through cpu3's debug context, then set/resume cpu0. A
# completed payload leaves cpu0 parked at .Lhalt, where this OpenOCD/aarch64
# combination can subsequently report a sticky debug abort when load_image
# itself uses cpu0. The other core reaches the same RAM without that stale
# cpu0 debug state; execution still starts exclusively on cpu0.
LOG=$(mktemp)
if ! openocd "${OPENOCD_ARGS[@]}" \
    -c 'init' \
    -c 'targets bcm2712.cpu0' \
    -c 'halt' \
    -c 'targets bcm2712.cpu3' \
    -c 'halt' \
    -c "load_image $ELF 0 elf" \
    -c 'targets bcm2712.cpu0' \
    -c "reg sp $stack_top" \
    -c "reg pc $entry_pc" \
    -c 'resume' \
    -c 'targets bcm2712.cpu3' \
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
