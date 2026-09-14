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
# NEW discriminator: current mode is EL1H or EL2H AND halted PC is below
# RPI5_SAFE_PC_MAX
# (32MB, 0x02000000). Every takibi payload here (jtag_stub.S at 0x80000,
# every examples/*/kernel_rpi5.elf at 0x200000, see link.ld) executes
# from a fixed LOW physical address with the EL2 stage 1 MMU either off or
# identity-mapped -- comfortably under 32MB with over 100x headroom for
# growth. A warm reset may replay the resident Takibi payload at EL1 instead
# of returning to the EL2 SD stub. A live, fully-booted Raspberry Pi OS
# kernel, by contrast, runs
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
warm_entry_pc="0x$(llvm-nm-19 "$ELF" | awk '$3=="kernel_warm_el1_entry"{print $1}')"
warm_secondary_pc="0x$(llvm-nm-19 "$ELF" | awk '$3=="kernel_secondary_warm_el1_entry"{print $1}')"
kernel_file_end="0x$(llvm-nm-19 "$ELF" | awk '$3=="kernel_file_end"{print $1}')"
secondary_boot_call_pc="0x$(llvm-nm-19 "$ELF" | awk '$3=="kernel_secondary_boot_cpu_on"{print $1}')"
stack_top="0x$(llvm-nm-19 "$ELF" | awk '$3=="stack_top"{print $1}')"
SMP_CORES="${RPI5_SMP_CORES:-0}"
if [ "$SMP_CORES" != "0" ] && [ "$SMP_CORES" != "2" ]; then
    echo "error: RPI5_SMP_CORES must be 0 or 2" >&2
    exit 1
fi
smp_trampoline=""
if [ "$SMP_CORES" = "2" ]; then
    smp_trampoline="0x$(llvm-nm-19 "$ELF" | awk '$3=="rpi5_el3_secondary_trampoline"{print $1}')"
    if [ -z "${smp_trampoline#0x}" ]; then
        echo "error: two-core load requested but rpi5_el3_secondary_trampoline is absent" >&2
        exit 1
    fi
fi
ddb_breakpoint_test_address=""
ddb_breakpoint_checkpoint_address=""
if [ "${RPI5_ARM_KERNEL_DDB_BREAKPOINT:-0}" = "1" ]; then
    ddb_breakpoint_test_address="0x$(llvm-nm-19 "$ELF" |
        awk '$3=="kernel_ddb_breakpoint_test_enabled" && !seen{print $1; seen = 1 }')"
    ddb_breakpoint_checkpoint_address="0x$(llvm-nm-19 "$ELF" |
        awk '$3=="kernel_ddb_breakpoint_test_checkpoint" && !seen{print $1; seen = 1 }')"
    if [ -z "${ddb_breakpoint_test_address#0x}" ] ||
            [ -z "${ddb_breakpoint_checkpoint_address#0x}" ]; then
        echo "error: DDB breakpoint test symbols absent from $ELF" >&2
        exit 1
    fi
elif [ "${RPI5_ARM_KERNEL_DDB_BREAKPOINT:-0}" != "0" ]; then
    echo "error: RPI5_ARM_KERNEL_DDB_BREAKPOINT must be 0 or 1" >&2
    exit 1
fi
# GitHub issue #534: the integration boot whose DDB half breaks in while a
# peer console record is held. Its checkpoint is kernel_boot_prologue, not
# the DDB one: entry.S has zeroed BSS and turned cpu0's MMU on by then, and
# the loader returns long before the RP1 GEM answers its one boot ARP. Halting
# at the later DDB checkpoint held the loader past that window, and the
# integration's ARP test failed against a kernel that had already given up.
peer_console_ddb_test_address=""
peer_console_ddb_checkpoint_address=""
if [ "${RPI5_ARM_PEER_CONSOLE_DDB:-0}" = "1" ]; then
    peer_console_ddb_test_address="0x$(llvm-nm-19 "$ELF" |
        awk '$3=="kernel_ddb_peer_console_test_enabled" && !seen{print $1; seen = 1 }')"
    peer_console_ddb_checkpoint_address="0x$(llvm-nm-19 "$ELF" |
        awk '$3=="kernel_boot_prologue" && !seen{print $1; seen = 1 }')"
    if [ -z "${peer_console_ddb_test_address#0x}" ] ||
            [ -z "${peer_console_ddb_checkpoint_address#0x}" ]; then
        echo "error: peer console DDB test symbols absent from $ELF" >&2
        exit 1
    fi
elif [ "${RPI5_ARM_PEER_CONSOLE_DDB:-0}" != "0" ]; then
    echo "error: RPI5_ARM_PEER_CONSOLE_DDB must be 0 or 1" >&2
    exit 1
fi

if [ -z "${entry_pc#0x}" ] || [ -z "${warm_entry_pc#0x}" ] ||
        [ -z "${warm_secondary_pc#0x}" ] ||
        [ -z "${kernel_file_end#0x}" ] ||
        [ -z "${secondary_boot_call_pc#0x}" ] ||
        [ -z "${stack_top#0x}" ]; then
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
OPENOCD_SPEED_ARGS=()
if [ -n "${RPI5_SWD_SPEED:-}" ]; then
    OPENOCD_SPEED_ARGS=(-c "adapter speed $RPI5_SWD_SPEED")
    echo "SWD adapter speed override: ${RPI5_SWD_SPEED} kHz"
fi

# Pass 1: halt, read PC + current exception level, resume immediately --
# read-only, same reasoning as rpi3_jtag_load.sh's own check pass.
CHECK_LOG=$(mktemp)
if ! openocd "${OPENOCD_ARGS[@]}" "${OPENOCD_SPEED_ARGS[@]}" \
    -c 'init' \
    -c 'targets bcm2712.cpu0' \
    -c 'halt' \
    -c 'reg pc' \
    -c 'mdw 0x00100000 1' \
    -c 'resume' \
    -c 'shutdown' > "$CHECK_LOG" 2>&1
then
    echo "error: openocd failed during PC/EL check -- log follows" >&2
    cat "$CHECK_LOG" >&2
    rm -f "$CHECK_LOG"
    exit 1
fi

halted_pc=$(awk '/^pc \(/{print $3}' "$CHECK_LOG" | head -1)
current_mode=$(grep -oE 'current mode: EL[0-9][A-Za-z]' "$CHECK_LOG" | tail -1 | awk '{print $3}')
mmu_state=$(grep -oE 'MMU: (enabled|disabled)' "$CHECK_LOG" | tail -1 | awk '{print $2}')
dtb_magic=$(awk '/^0x00100000: /{print $2}' "$CHECK_LOG" | head -1)

if [ -z "$current_mode" ] || [ -z "$mmu_state" ] || [ -z "$dtb_magic" ]; then
    echo "error: could not parse current exception level / MMU state from openocd output -- log follows" >&2
    cat "$CHECK_LOG" >&2
    rm -f "$CHECK_LOG"
    exit 1
fi
if [ "$dtb_magic" != "edfe0dd0" ]; then
    echo "error: SD spin stub did not capture a valid firmware DTB at 0x00100000" >&2
    echo "       (read 0x${dtb_magic}; rebuild and install examples/common_rpi5/jtag_stub.img," >&2
    echo "       then power-cycle the board before injecting Takibi)" >&2
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

if { [ "$current_mode" != "EL1H" ] &&
        [ "$current_mode" != "EL2H" ]; } ||
        [[ "$halted_pc_hex" > "$RPI5_SAFE_PC_MAX_HEX" ||
           "$halted_pc_hex" == "$RPI5_SAFE_PC_MAX_HEX" ]]; then
    printf 'error: halted core is at %s with PC=%s (MMU %s) -- this looks\n' \
         "$current_mode" "$halted_pc" "$mmu_state" >&2
    printf 'like a genuinely running Raspberry Pi OS, not our own\n' >&2
    printf 'stub/payload (every takibi RPi5 payload runs from a fixed low\n' >&2
    printf 'physical address below 0x%s -- see this scripts own header\n' \
         "$RPI5_SAFE_PC_MAX_HEX" >&2
    printf 'comment). Refusing to inject (would corrupt the running OS). If\n' >&2
    printf 'kernel_2712.img on the SD card is already\n' >&2
    printf 'examples/common_rpi5/jtag_stub.img, run\n' >&2
    printf 'scripts/rpi5_jtag_reset.sh --resident-image-unchanged; otherwise flash it first and\n' >&2
    printf 'power-cycle the board. (The board was left running exactly as\n' >&2
    printf 'found -- this check only read/resumed, it never wrote anything.)\n' >&2
    exit 1
fi
echo "halted core is at $current_mode with PC=$halted_pc (< 0x$RPI5_SAFE_PC_MAX_HEX, MMU $mmu_state) -- safe to inject"

# Pick a privileged secondary as the memory-access context. A completed
# single-core payload made cpu0's debug state unsuitable for load_image, which
# is why this path historically used cpu3. Four-core scheduling invalidated
# the fixed choice: cpu3 may now be caught in EL0, whose translation context
# makes OpenOCD abort the write. Fresh firmware secondaries are at EL3; an
# idle Takibi secondary is at EL1. Both are usable, so inspect rather than
# assume. Keep cpu0 solely as the execution core and safety authority above.
INJECT_CORE=""
WARM_REPLAY=false
if [ "$current_mode" = "EL1H" ]; then WARM_REPLAY=true; fi
launch_pc="$entry_pc"
if [ "$WARM_REPLAY" = true ]; then launch_pc="$warm_entry_pc"; fi
if [ "$WARM_REPLAY" = false ]; then
    INJECT_CORE=3
    INJECT_MODE=EL3H
fi
for core in 3 2 1; do
    if [ "$WARM_REPLAY" = false ]; then break; fi
    CORE_LOG=$(mktemp)
    if openocd "${OPENOCD_ARGS[@]}" "${OPENOCD_SPEED_ARGS[@]}" \
        -c 'init' \
        -c "targets bcm2712.cpu$core" \
        -c 'halt' \
        -c 'reg pc' \
        -c 'shutdown' > "$CORE_LOG" 2>&1
    then
        core_mode=$(grep -oE 'current mode: EL[0-9][A-Za-z]' "$CORE_LOG" | tail -1 | awk '{print $3}')
        core_pc=$(awk '/^pc \(/{print $3}' "$CORE_LOG" | tail -1)
        core_pc_hex="${core_pc#0x}"
        core_pc_hex="$(printf '%s' "$core_pc_hex" | tr 'A-F' 'a-f')"
        if { [ "$core_mode" = "EL1H" ] || [ "$core_mode" = "EL2H" ] ||
                [ "$core_mode" = "EL3H" ] || [ "$core_mode" = "EL3T" ]; } &&
                { [ "$WARM_REPLAY" = false ] || [ "$core_mode" = "EL1H" ] ||
                    [ "$core_mode" = "EL2H" ]; } &&
                [ "${#core_pc_hex}" -eq 16 ] &&
                [[ "$core_pc_hex" < "$RPI5_SAFE_PC_MAX_HEX" ]]; then
            INJECT_CORE="$core"
            INJECT_MODE="$core_mode"
            rm -f "$CORE_LOG"
            break
        fi
    fi
    openocd "${OPENOCD_ARGS[@]}" "${OPENOCD_SPEED_ARGS[@]}" \
        -c 'init' -c "targets bcm2712.cpu$core" -c 'resume' \
        -c 'shutdown' > /dev/null 2>&1 || true
    rm -f "$CORE_LOG"
done
if [ -z "$INJECT_CORE" ]; then
    echo "error: no privileged low-PC secondary is available for SWD injection" >&2
    exit 1
fi
echo "using cpu$INJECT_CORE at $INJECT_MODE as the SWD memory-access context"

# A warm reset can replay the previous Takibi kernel, including secondaries
# already running its EL0 processes. Halt every non-writer secondary before
# replacing its instructions. Sampling waits for an EL0 core's next timer IRQ
# to return it to privileged Takibi code; changing PSTATE across exception
# levels in debug state is architecturally invalid on this target. The cores
# remain halted until cpu0 has restarted and is waiting for their handshake.
if [ "$WARM_REPLAY" = true ]; then
    for core in 1 2 3; do
        if [ "$core" = "$INJECT_CORE" ]; then continue; fi
        parked=false
        for attempt in $(seq 1 20); do
            CORE_LOG=$(mktemp)
            if openocd "${OPENOCD_ARGS[@]}" "${OPENOCD_SPEED_ARGS[@]}" \
                -c 'init' -c "targets bcm2712.cpu$core" -c 'halt' \
                -c 'reg pc' -c 'shutdown' > "$CORE_LOG" 2>&1
            then
                core_mode=$(grep -oE 'current mode: EL[0-9][A-Za-z]' "$CORE_LOG" | tail -1 | awk '{print $3}')
                core_pc=$(awk '/^pc \(/{print $3}' "$CORE_LOG" | tail -1)
                core_pc_hex="${core_pc#0x}"
                if { [ "$core_mode" = "EL1H" ] || [ "$core_mode" = "EL2H" ]; } &&
                        [ "${#core_pc_hex}" -eq 16 ] &&
                        [[ "$core_pc_hex" < "$RPI5_SAFE_PC_MAX_HEX" ]]; then
                    parked=true
                else
                    openocd "${OPENOCD_ARGS[@]}" "${OPENOCD_SPEED_ARGS[@]}" \
                        -c 'init' -c "targets bcm2712.cpu$core" -c 'resume' \
                        -c 'shutdown' > /dev/null 2>&1 || true
                fi
            fi
            rm -f "$CORE_LOG"
            if [ "$parked" = true ]; then break; fi
            sleep 0.05
        done
        if [ "$parked" != true ]; then
            echo "error: cpu$core never returned to privileged Takibi code for warm-load quiescence" >&2
            exit 1
        fi
    done
fi

# Pass 2: load shared physical RAM through the selected core, then set and
# resume cpu0.
LOG=$(mktemp)
LOAD_COMMANDS=(
    -c 'init'
    -c 'targets bcm2712.cpu0'
    -c 'halt'
    -c "targets bcm2712.cpu$INJECT_CORE"
    -c 'halt'
    -c "load_image $ELF 0 elf"
)
if [ "$WARM_REPLAY" = true ]; then
    # load_image writes through the selected core and can leave its old cache
    # lines resident. The cache-maintenance routine therefore lives outside
    # the replaced image. rpi5_jtag_reset.sh installs the stable helper before
    # resetting; the warm reset preserves this RAM while returning the cores
    # to a state from which the loader can call it.
    cache_publish_pc=0x00180100
    cache_publish_done_pc=0x00180120
    LOAD_COMMANDS+=(
        -c "bp $cache_publish_done_pc 4 hw"
        -c 'reg x0 0x00200000'
        -c "reg x1 $kernel_file_end"
        -c "reg pc $cache_publish_pc"
        -c 'resume'
        -c 'wait_halt 30000'
        -c "rbp $cache_publish_done_pc"
    )
fi
LOAD_COMMANDS+=(
    -c 'targets bcm2712.cpu0'
    -c "reg sp $stack_top"
    -c 'reg x0 0x00100000'
    -c 'reg x1 0'
    -c 'reg x2 0'
    -c 'reg x3 0'
    -c "reg pc $launch_pc"
)
# BSS zeroing happens after cpu0 starts, so a byte written immediately after
# load_image would be erased. Stop at a checkpoint first, then write through
# the selected secondary before releasing cpu0 again. The peer console
# checkpoint is earlier in boot than the DDB one, so it is taken first.
if [ -n "$peer_console_ddb_test_address" ]; then
    LOAD_COMMANDS+=(
        -c "bp $peer_console_ddb_checkpoint_address 4 hw"
        -c 'resume'
        -c 'wait_halt 30000'
        -c "targets bcm2712.cpu$INJECT_CORE"
        -c "mwb $peer_console_ddb_test_address 1"
        -c 'targets bcm2712.cpu0'
        -c "rbp $peer_console_ddb_checkpoint_address"
    )
fi
if [ -n "$ddb_breakpoint_test_address" ]; then
    LOAD_COMMANDS+=(
        -c "bp $ddb_breakpoint_checkpoint_address 4 hw"
        -c 'resume'
        -c 'wait_halt 30000'
        -c "targets bcm2712.cpu$INJECT_CORE"
        -c "mwb $ddb_breakpoint_test_address 1"
        -c 'targets bcm2712.cpu0'
        -c "rbp $ddb_breakpoint_checkpoint_address"
    )
fi
if [ "$WARM_REPLAY" = true ]; then
    LOAD_COMMANDS+=(
        -c "bp $secondary_boot_call_pc 4 hw"
        -c 'targets bcm2712.cpu0'
        -c 'resume'
        -c 'wait_halt 30000'
        -c "rbp $secondary_boot_call_pc"
    )
    for core in 1 2 3; do
        LOAD_COMMANDS+=(
            -c "targets bcm2712.cpu$core"
            -c 'halt'
            -c "reg x0 $((0x190 + core))"
            -c "reg pc $warm_secondary_pc"
            -c 'resume'
        )
    done
    LOAD_COMMANDS+=(-c 'targets bcm2712.cpu0' -c 'resume')
elif [ "$INJECT_CORE" != "0" ]; then
    LOAD_COMMANDS+=(
        -c "targets bcm2712.cpu$INJECT_CORE"
        -c 'resume'
        -c 'targets bcm2712.cpu0'
    )
else
    LOAD_COMMANDS+=(-c 'targets bcm2712.cpu0')
fi
if [ "$WARM_REPLAY" = false ]; then LOAD_COMMANDS+=(-c 'resume'); fi
if [ "$SMP_CORES" = "2" ]; then
    LOAD_COMMANDS+=(
        -c 'sleep 200'
        -c 'targets bcm2712.cpu1'
        -c 'halt'
        -c "reg pc $smp_trampoline"
        -c 'resume'
    )
fi
LOAD_COMMANDS+=(-c 'shutdown')
if ! openocd "${OPENOCD_ARGS[@]}" "${OPENOCD_SPEED_ARGS[@]}" "${LOAD_COMMANDS[@]}" > "$LOG" 2>&1
then
    echo "error: openocd failed during injection -- log follows" >&2
    cat "$LOG" >&2
    rm -f "$LOG"
    exit 1
fi

echo "injected $ELF and resumed (PC=$launch_pc SP=$stack_top)"
cat "$LOG"
rm -f "$LOG"
