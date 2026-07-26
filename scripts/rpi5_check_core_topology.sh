#!/usr/bin/env bash
# Real-hardware MPIDR_EL1 core-topology check for GitHub issue #163 --
# reads MPIDR_EL1 independently on all four bcm2712.cpuN OpenOCD targets
# and reports which core is running takibi code vs. still parked in
# Trusted Firmware-A's own EL3 idle loop. Opt-in diagnostic, not part of
# make hwcheck-rpi5: it momentarily redirects a HALTED core's own PC into
# a tiny scratch-RAM probe (examples/common_rpi5/smp_probe.S) and single-
# steps through it, then restores the ORIGINAL PC before resuming --
# never touches TF-A's own code/state, only reads a read-only ID
# register (MPIDR_EL1 has no side effects). This is exactly the
# technique that found examples/common_rpi5/startup.S's real core-
# selection bug (GitHub issue #163): BCM2712's MPIDR_EL1 sets the MT bit
# and numbers cores in Aff1 (bits[15:8]), not Aff0 (bits[7:0], always 0
# on every core here) -- unlike BCM2837, which RPi3's own startup.S
# correctly reads via plain Aff0.
#
# Usage: scripts/rpi5_check_core_topology.sh
# Requires: real RPi5 + Debug Probe attached, board already running
# ANY takibi payload on cpu0 (e.g. after `make hwcheck-rpi5` or a manual
# `scripts/rpi5_jtag_load.sh`) or sitting in examples/common_rpi5/
# jtag_stub.S's own spin loop -- either way, cpu0 must already be at a
# LOW, EL2H, takibi-controlled PC for this script's own safety
# reasoning to hold. Does not itself inject a payload onto cpu0.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BCM2712_CFG="$REPO_ROOT/examples/common_rpi5/bcm2712.cfg"
PROBE_S="$REPO_ROOT/examples/common_rpi5/smp_probe.S"
PROBE_LD="$REPO_ROOT/examples/common_rpi5/smp_probe.ld"
PROBE_ADDR=0x00090000

OPENOCD_ARGS=(
    -f interface/cmsis-dap.cfg
    -f "$BCM2712_CFG"
)

work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT

llvm-mc-19 --triple=aarch64-none-elf --filetype=obj "$PROBE_S" -o "$work_dir/smp_probe.o"
ld.lld-19 -T "$PROBE_LD" "$work_dir/smp_probe.o" -o "$work_dir/smp_probe.elf"

echo "Loading MPIDR_EL1 probe (examples/common_rpi5/smp_probe.S) at $PROBE_ADDR via bcm2712.cpu3..."
openocd "${OPENOCD_ARGS[@]}" \
    -c 'init' \
    -c 'targets bcm2712.cpu3' \
    -c 'halt' \
    -c "load_image $work_dir/smp_probe.elf 0 elf" \
    -c 'shutdown' > "$work_dir/load.log" 2>&1
if ! grep -q 'downloaded' "$work_dir/load.log"; then
    echo "error: probe load failed -- log follows" >&2
    cat "$work_dir/load.log" >&2
    exit 1
fi

echo
printf '%-6s %-8s %-18s %-18s %s\n' "core" "mode" "pc (before)" "mpidr_el1" "note"
for core in 0 1 2 3; do
    log="$work_dir/cpu$core.log"
    openocd "${OPENOCD_ARGS[@]}" \
        -c 'init' \
        -c "targets bcm2712.cpu$core" \
        -c 'halt' \
        -c 'reg pc' \
        -c "reg pc $PROBE_ADDR" \
        -c 'step' \
        -c 'reg x0' \
        -c "reg pc" \
        -c "reg pc" \
        -c 'shutdown' > "$log" 2>&1 || true

    # NOT `grep -m1` against the whole log: `init` reports every SMP
    # target's own status while enumerating the ROM table (one full
    # "bcm2712.cpuN halted ..., current mode: ELx" line per core), so
    # the file contains one such line per core before this core's own --
    # match only the line that starts with THIS core's own name.
    mode=$(grep -oE "^bcm2712\.cpu$core halted.*current mode: EL[0-9][A-Za-z]" "$log" | head -1 | grep -oE 'EL[0-9][A-Za-z]$')
    orig_pc=$(grep -oE '^pc \(/64\): 0x[0-9a-f]+' "$log" | head -1 | awk '{print $3}')
    mpidr=$(grep -oE '^x0 \(/64\): 0x[0-9a-f]+' "$log" | head -1 | awk '{print $3}')

    # Restore the original PC and resume -- leave every core exactly as
    # found, whether it was our own takibi code (cpu0) or still parked
    # in TF-A's own EL3 idle loop (the common case for cpu1-3 today).
    openocd "${OPENOCD_ARGS[@]}" \
        -c 'init' \
        -c "targets bcm2712.cpu$core" \
        -c 'halt' \
        -c "reg pc $orig_pc" \
        -c 'resume' \
        -c 'shutdown' >> "$log" 2>&1

    aff1=$(( (mpidr >> 8) & 3 ))
    note=""
    if [ "$mode" = "EL2H" ]; then
        note="running takibi code"
    else
        note="parked in TF-A (never reached _start)"
    fi
    printf '%-6s %-8s %-18s %-18s aff1=%s -- %s\n' "cpu$core" "$mode" "$orig_pc" "$mpidr" "$aff1" "$note"
done

echo
echo "Done. Every core's original PC was restored and resumed -- no persistent state changed."
