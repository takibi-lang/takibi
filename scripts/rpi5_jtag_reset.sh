#!/usr/bin/env bash
# Reboots the RPi5 board via a PSCI SYSTEM_RESET SMC call issued from a
# tiny 2-instruction trampoline injected over SWD.
#
# REPLACES an earlier version that used OpenOCD's generic `reset halt`,
# which failed with "bcm2712.cpu0: how to reset?" when actually tried
# (2026-07-25): the official Debug Probe's SWD wiring does not carry the
# SoC's nSRST signal, and kernel/platform/rpi5/jtag/bcm2712.cfg defines no
# BCM2712-specific reset handler, so OpenOCD's SRST-based `reset` has
# nothing to drive. PSCI SYSTEM_RESET sidesteps this entirely: BCM2712's
# own device tree declares PSCI with method "smc", and TF-A (already
# confirmed present -- see scripts/rpi5_jtag_load.sh's own EL2-handoff
# research) implements the standard ARM PSCI firmware interface at EL3
# regardless of which lower EL issues the call, so an `smc` from our
# EL2H stub/payload reaches it the same way Linux's own `reboot` does.
# Confirmed working for CPU-local restarts (2026-07-25): reconnects
# within a few seconds (sometimes briefly passing through a mid-boot state
# around PC 0x9c before settling), landing back in whatever
# kernel_2712.img was ALREADY resident. Genuinely reboots the CPU/core
# complex, unlike a plain debug halt.
#
# CORRECTED, same day: an earlier version of this comment claimed this
# also reliably reloads a DIFFERENT kernel_2712.img after swapping the
# SD card's file -- that was WRONG. Confirmed the hard way: swapped
# kernel_2712.img from Linux back to jtag_stub.img on the SD card (file
# size on disk verified 8 bytes), ran this script, and it landed back in
# Linux again (PC at a canonical high VA), not the stub -- meaning this
# reset path does NOT reliably re-read the SD card's current file the way
# a real power cycle does; it appears to replay whatever kernel image is
# already resident (DRAM-cached, or the firmware/EEPROM's own boot
# staging skips a fresh SD read on this kind of warm reset). Use this
# script freely to re-run the SAME kernel_2712.img (e.g. between
# `rp1_pcie_smoke` iterations while it stays the stub) -- but after
# swapping the SD card's file to something DIFFERENT, a real physical
# power cycle is still required.
#
# The script therefore requires an explicit --resident-image-unchanged
# assertion. SWD cannot observe whether the SD-card file changed while the
# firmware keeps running an older resident image. The resident image may be
# the known spin stub or an earlier Takibi payload: both are safe to replace
# because the same low-PC/EL2H discriminator used by rpi5_jtag_load.sh rules
# out a live Raspberry Pi OS kernel. After changing the SD payload itself,
# physically power-cycle first.
#
# WARNING: like RPi3's watchdog-based reset, this really does reboot the
# whole SoC -- do not run this against a board you intend to keep a live
# Raspberry Pi OS session on (see scripts/rpi5_jtag_load.sh's own header
# comment on why "halted at EL2H" alone cannot rule that out on this
# board, due to VHE).
set -euo pipefail

if [ "$#" -ne 1 ] || [ "$1" != "--resident-image-unchanged" ]; then
    echo "error: warm reset cannot guarantee reload of a changed kernel_2712.img" >&2
    echo "error: physically power-cycle after any SD payload change; otherwise rerun with" >&2
    echo "       --resident-image-unchanged to assert that the resident SD image is unchanged" >&2
    exit 2
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BCM2712_CFG="$REPO_ROOT/kernel/platform/rpi5/jtag/bcm2712.cfg"
OPENOCD_TIMEOUT="${RPI5_OPENOCD_TIMEOUT:-10}"
RESET_MAX_ATTEMPTS="${RPI5_RESET_MAX_ATTEMPTS:-20}"
RESET_RETRY_SECONDS="${RPI5_RESET_RETRY_SECONDS:-1}"
RESET_PREFLIGHT_MAX_ATTEMPTS="${RPI5_RESET_PREFLIGHT_MAX_ATTEMPTS:-20}"

OPENOCD_ARGS=(
    -f interface/cmsis-dap.cfg
    -f "$BCM2712_CFG"
)
OPENOCD_SPEED_ARGS=()
if [ -n "${RPI5_SWD_SPEED:-}" ]; then
    OPENOCD_SPEED_ARGS=(-c "adapter speed $RPI5_SWD_SPEED")
fi

# PSCI SYSTEM_RESET (function ID 0x84000009) via `smc #0` (encoding
# 0xd4000003), immediately followed by `b .` (0x14000000) as a landing
# pad in case the SMC ever returns instead of actually resetting.
# Injected at a fixed, always-unused RAM address (0x00180000 -- between
# the firmware DTB copied at 0x00100000 and link.ld's 0x200000) rather
# than requiring a real ELF load. `reg x0` sets the PSCI function ID
# argument directly; OpenOCD's own SWD session is expected to drop the
# instant the SMC actually reboots the SoC, so its exit status is
# deliberately ignored, same reasoning as RPi3's watchdog-reset script.
#
# The trampoline and cache helper are written through cpu0 after the preflight
# has proved that it is in privileged, identity-mapped Takibi code. OpenOCD
# 0.12's bcm2712 MEM-AP target reports successful low-RAM writes without
# changing RAM on this board, so it cannot safely install executable helpers.
# Arbitrary peer cores remain unsuitable memory contexts because they may be
# in EL0 or carry a sticky debug abort.
# Preserve cpu0's current privileged EL while executing the trampoline.
# Forcing an EL1 kernel's debug-restored PSTATE to EL2H does not recreate a
# valid EL2 exception context: after the four-core kernel ran, its SMC landed
# at VBAR_EL2+0x200 instead of reaching TF-A. A read-only preflight below
# accepts only Takibi's low-PC EL1H/EL2H states and supplies the matching
# masked PSTATE value.
# The injected address is identity-mapped by every Takibi EL2 table, so this
# is valid whether the interrupted payload had its EL2 MMU enabled or not.
RESET_ADDR=0x00180000
CACHE_PUBLISH_ADDR=0x00180100
PSCI_SYSTEM_RESET=0x84000009
RPI5_SAFE_PC_MAX_HEX="0000000002000000"
EL1_VECTORS="0x$(llvm-nm-19 "$REPO_ROOT/kernel/build/rpi5/kernel.elf" |
    awk '$3=="el1_vectors"{print $1}')"
if [ -z "${EL1_VECTORS#0x}" ]; then
    echo "error: cannot locate el1_vectors in the built RPi5 kernel" >&2
    exit 1
fi
EL1_LOWER_IRQ=$(printf '0x%x' $((EL1_VECTORS + 0x480)))

# These are the two stop PCs of the installed SD stub's final WFE loop.
# Check its live instruction words and captured FDT before certifying reset.
RESET_REGISTERS='
proc takibi_register {name} {
    if {![regexp {(0x[0-9a-fA-F]+)} [reg $name] token]} {
        error "cannot read reset register $name"
    }
    return [expr {$token + 0}]
}
proc takibi_arm_reset {site cpsr} {
    reg cpsr $cpsr
    reg x0 0x84000009
    reg pc $site
    if {[takibi_register pc] != $site || [takibi_register cpsr] != $cpsr ||
        [takibi_register x0] != 0x84000009} {
        error "reset register readback mismatch; refused before resume"
    }
    echo "takibi-reset: armed"
}'

PREFLIGHT_LOG=$(mktemp)
preflight_ok=false
preflight_pc=""
preflight_mode=""
for preflight_attempt in $(seq 1 "$RESET_PREFLIGHT_MAX_ATTEMPTS"); do
    if timeout --foreground "$OPENOCD_TIMEOUT" openocd "${OPENOCD_ARGS[@]}" "${OPENOCD_SPEED_ARGS[@]}" \
        -c 'init' \
        -c 'targets bcm2712.cpu0' \
        -c 'halt' \
        -c 'reg pc' \
        -c 'shutdown' > "$PREFLIGHT_LOG" 2>&1
    then
        preflight_pc=$(awk '/^pc \(/{print $3}' "$PREFLIGHT_LOG" | head -1)
        preflight_mode=$(grep -oE 'current mode: EL[0-9][A-Za-z]' "$PREFLIGHT_LOG" | tail -1 | awk '{print $3}')
        preflight_pc_hex="${preflight_pc#0x}"
        preflight_pc_hex="$(printf '%s' "$preflight_pc_hex" | tr 'A-F' 'a-f')"
        if { [ "$preflight_mode" = "EL1H" ] ||
                [ "$preflight_mode" = "EL2H" ]; } &&
                [ "${#preflight_pc_hex}" -eq 16 ] &&
                [[ "$preflight_pc_hex" < "$RPI5_SAFE_PC_MAX_HEX" ]]; then
            preflight_ok=true
            break
        fi
        if [ "$preflight_mode" = "EL0T" ]; then
            # Polling almost always catches a busy userspace process back at
            # EL0. Stop deterministically at the next lower-EL IRQ entry.
            if timeout --foreground "$OPENOCD_TIMEOUT" openocd "${OPENOCD_ARGS[@]}" "${OPENOCD_SPEED_ARGS[@]}" \
                -c 'init' \
                -c 'targets bcm2712.cpu0' \
                -c "bp $EL1_LOWER_IRQ 4 hw" \
                -c 'resume' \
                -c 'wait_halt 30000' \
                -c 'reg pc' \
                -c "rbp $EL1_LOWER_IRQ" \
                -c 'shutdown' > "$PREFLIGHT_LOG" 2>&1
            then
                preflight_pc=$(awk '/^pc \(/{print $3}' "$PREFLIGHT_LOG" | tail -1)
                preflight_mode=$(grep -oE 'current mode: EL[0-9][A-Za-z]' "$PREFLIGHT_LOG" | tail -1 | awk '{print $3}')
                preflight_pc_hex="${preflight_pc#0x}"
                if [ "$preflight_mode" = "EL1H" ] &&
                        [ "${#preflight_pc_hex}" -eq 16 ] &&
                        [[ "$preflight_pc_hex" < "$RPI5_SAFE_PC_MAX_HEX" ]]; then
                    preflight_ok=true
                    break
                fi
            fi
        fi
    fi
    timeout --foreground "$OPENOCD_TIMEOUT" openocd "${OPENOCD_ARGS[@]}" "${OPENOCD_SPEED_ARGS[@]}" \
        -c 'init' -c 'targets bcm2712.cpu0' -c 'resume' -c 'shutdown' \
        > /dev/null 2>&1 || true
    sleep 0.05
done
rm -f "$PREFLIGHT_LOG"
if [ "$preflight_ok" != true ]; then
    echo "warning: cpu0 did not return to privileged low-address Takibi code after" \
         "$RESET_PREFLIGHT_MAX_ATTEMPTS attempts (last PC=${preflight_pc:-unknown}" \
         "mode=${preflight_mode:-unknown}); refusing reset" >&2
    exit 1
fi
if [ "$preflight_mode" = "EL1H" ]; then RESET_CPSR=0x3c5; else RESET_CPSR=0x3c9; fi

# GitHub issue #1197: an EL1H preflight means a Takibi kernel with its EL1
# MMU on. Since #1032 that kernel maps everything outside its text
# writable and execute-never (SCTLR_EL1.WXN), so the trampoline written at
# RESET_ADDR is fetched from an XN page: the core took an instruction abort
# into the kernel's DDB instead of resetting, the verify loop below accepted
# that still-running kernel, and the loader then wrote its image into the
# read-only text and aborted (dscr 0x03047d53). Only a power cycle got back
# to the stub. The kernel's own text is the one executable range, and every
# kernel has a PSCI `smc #0` in it, so jump to that instruction instead. The
# resident kernel may be any earlier build, so find the word in RAM rather
# than in today's ELF. An EL2H stub runs with its MMU off and keeps the
# written trampoline.
RESET_FIND_SMC=(-c "set takibi_smc $RESET_ADDR")
if [ "$preflight_mode" = "EL1H" ]; then
    RESET_FIND_SMC=(
        -c 'set takibi_smc 0
            if {[catch {
                for {set base 0x200000} {$base < 0x400000 && $takibi_smc == 0} {incr base 0x10000} {
                    set i 0
                    foreach w [read_memory $base 32 0x4000] {
                        if {$w == 0xd4000003} { set takibi_smc [expr {$base + 4 * $i}]; break }
                        incr i
                    }
                }
            } detail]} {
                echo "takibi-reset: primary scan failed before arm: $detail"
            } elseif {$takibi_smc == 0} {
                echo "takibi-reset: primary scan failed before arm: no smc #0 in resident kernel text"
            } else {
                echo [format "takibi-reset: smc #0 at 0x%x" $takibi_smc]
            }'
    )
fi

# A peer must have a readable virtual mapping of the exact linked startup
# and PSCI code. The primary retains its resident-text scan for older images.
# An unrecognized, unreadable or non-EL1H peer stays untouched.
reset_from_verified_peer() {
    local elf="$REPO_ROOT/kernel/build/rpi5/kernel.elf" anchors entry_limit
    entry_limit=$(llvm-nm-19 "$elf" | awk '$3=="kernel_text_end"{print "0x"$1}')
    if [ -z "$entry_limit" ]; then return 1; fi
    if ! anchors=$(llvm-objdump-19 -d --disassemble-symbols=_start,rpi5_psci_cpu_on "$elf" | awk '
        /<_start>:$/ { part = 1; next }
        /<rpi5_psci_cpu_on>:$/ { part = 2; next }
        /^[[:xdigit:]]+ </ { part = 0 }
        $1 ~ /^[[:xdigit:]]+:$/ && $2 ~ /^[[:xdigit:]]+$/ && length($2) == 8 {
            if (part == 1 && first_count < 7) {
                if (first_count == 0) first_addr = substr($1, 1, length($1) - 1)
                first_count++
                first = first " 0x" $2
            }
            if (part == 2) {
                if (second_count == 0) second_addr = substr($1, 1, length($1) - 1)
                second_count++
                second = second " 0x" $2
                if ($2 == "d4000003") {
                    site = substr($1, 1, length($1) - 1)
                    sites++
                }
            }
        }
        END {
            if (first_count != 7 || second_count < 8 || sites != 1) exit 1
            printf "set anchors {0x%s {%s} 0x%s {%s}}; set reset_site 0x%s", first_addr, first, second_addr, second, site
        }'); then return 1; fi
    timeout --foreground "${RPI5_RESET_SESSION_TIMEOUT:-90}" openocd "${OPENOCD_ARGS[@]}" "${OPENOCD_SPEED_ARGS[@]}"         -c "$RESET_REGISTERS" -c "$anchors" -c "set text_end $entry_limit" -c init         -c 'foreach core {1 2 3} {
                targets bcm2712.cpu$core
                if {[catch {halt 2500}]} { continue }
                set matched 0
                if {![catch {
                    set pc [takibi_register pc]
                    set cpsr [takibi_register cpsr]
                    set matched [expr {($cpsr & 15) == 5 && $pc >= 0x200000 && $pc < $text_end}]
                    foreach {address expected} $anchors {
                        if {!$matched} { break }
                        set actual [read_memory $address 32 [llength $expected]]
                        if {[llength $actual] != [llength $expected]} { set matched 0; break }
                        foreach a $actual b $expected {
                            if {$a != $b} { set matched 0; break }
                        }
                    }
                }] && $matched} {
                    echo "takibi-reset: CPU$core carries the exact linked Takibi reset code"
                    takibi_arm_reset $reset_site [expr {$cpsr | 0x3c0}]
                    resume
                    break
                }
                resume
            }' -c shutdown
}

# EL1 resolves a resident executable instruction. Keep scratch writes in
# the MMU-off stub path so a broken EL1 map cannot abort before its scan.
RESET_TRAMPOLINES=()
if [ "$preflight_mode" = EL2H ]; then
    RESET_TRAMPOLINES=(
        -c "mww $RESET_ADDR 0xd4000003"
        -c "mww $((RESET_ADDR + 4)) 0x14000000"
        -c "mww $CACHE_PUBLISH_ADDR 0xd50b7e20"
        -c "mww $((CACHE_PUBLISH_ADDR + 4)) 0x91010000"
        -c "mww $((CACHE_PUBLISH_ADDR + 8)) 0xeb01001f"
        -c "mww $((CACHE_PUBLISH_ADDR + 12)) 0x54ffffa3"
        -c "mww $((CACHE_PUBLISH_ADDR + 16)) 0xd5033f9f"
        -c "mww $((CACHE_PUBLISH_ADDR + 20)) 0xd508751f"
        -c "mww $((CACHE_PUBLISH_ADDR + 24)) 0xd5033f9f"
        -c "mww $((CACHE_PUBLISH_ADDR + 28)) 0xd5033fdf"
        -c "mww $((CACHE_PUBLISH_ADDR + 32)) 0x14000000"
        -c 'set reset_words [read_memory 0x180000 32 2]
            if {[llength $reset_words] != 2 || [lindex $reset_words 0] != 0xd4000003 ||
                [lindex $reset_words 1] != 0x14000000} {
                error "reset trampoline readback mismatch"
            }'
    )
fi

# A disconnect after arming can be the reset itself. A failed scan can try a
# peer, but an unknown failure or timeout before arming grants no retry.
RESET_LOG=$(mktemp)
reset_status=0
timeout --foreground "${RPI5_RESET_SESSION_TIMEOUT:-90}" openocd "${OPENOCD_ARGS[@]}" "${OPENOCD_SPEED_ARGS[@]}" \
    -c "$RESET_REGISTERS" \
    -c 'init' \
    -c 'targets bcm2712.cpu0' \
    -c 'halt' \
    "${RESET_TRAMPOLINES[@]}" \
    "${RESET_FIND_SMC[@]}" \
    -c "if {\$takibi_smc != 0} { takibi_arm_reset \$takibi_smc $RESET_CPSR }" \
    -c 'resume' -c 'shutdown' > "$RESET_LOG" 2>&1 || reset_status=$?
if ! grep -qx 'takibi-reset: armed' "$RESET_LOG" &&
        [ "$preflight_mode" = EL1H ] &&
        grep -q '^takibi-reset: primary scan failed before arm:' "$RESET_LOG"; then
    reset_from_verified_peer >>"$RESET_LOG" 2>&1 || reset_status=$?
fi
if ! grep -qx 'takibi-reset: armed' "$RESET_LOG"; then
    echo "error: SWD PSCI reset was not armed (OpenOCD status $reset_status); power-cycle the RPi5 if no resident Takibi core is readable" >&2
    cat "$RESET_LOG" >&2
    rm -f "$RESET_LOG"
    exit 1
fi
grep '^takibi-reset:' "$RESET_LOG"
rm -f "$RESET_LOG"

# Full SD-card boot (EEPROM -> TF-A -> config.txt -> kernel_2712.img)
# takes noticeably longer than the reset itself. A successful SWD reconnect
# only says the core is visible. Poll for the installed MMU-off SD stub,
# resuming CPU0 after every observation. A resident EL1 image can be the
# unchanged pre-reset kernel and never certifies this reset workflow.
VERIFY_LOG=$(mktemp)
attempt=0
verified=false
halted_pc=""
current_mode=""
mmu_state=""
while [ "$attempt" -lt "$RESET_MAX_ATTEMPTS" ]; do
    attempt=$((attempt + 1))
    if timeout --foreground "$OPENOCD_TIMEOUT" openocd "${OPENOCD_ARGS[@]}" "${OPENOCD_SPEED_ARGS[@]}" \
        -c "$RESET_REGISTERS" \
        -c 'init' \
        -c 'targets bcm2712.cpu0' \
        -c 'halt' \
        -c 'reg pc' \
        -c 'set pc [takibi_register pc]
            if {([takibi_register cpsr] & 15) == 9 && ($pc == 0x800e0 || $pc == 0x800e4)} {
                if {![catch {read_memory 0x800e0 32 2} spin] &&
                    [llength $spin] == 2 && [lindex $spin 0] == 0xd503205f &&
                    [lindex $spin 1] == 0x17ffffff &&
                    ![catch {read_memory 0x100000 32 1} dtb] &&
                    [llength $dtb] == 1 && [lindex $dtb 0] == 0xedfe0dd0} {
                    echo "takibi-reset: installed SD stub signature"
                }
            }' \
        -c 'resume' \
        -c 'shutdown' > "$VERIFY_LOG" 2>&1
    then
        halted_pc=$(awk '/^pc \(/{print $3}' "$VERIFY_LOG" | head -1)
        current_mode=$(grep -oE 'current mode: EL[0-9][A-Za-z]' "$VERIFY_LOG" | tail -1 | awk '{print $3}')
        mmu_state=$(grep -oE 'MMU: (enabled|disabled)' "$VERIFY_LOG" | tail -1 | awk '{print $2}')
        halted_pc_hex="${halted_pc#0x}"
        halted_pc_hex="$(printf '%s' "$halted_pc_hex" | tr 'A-F' 'a-f')"
        if [ "$current_mode" = EL2H ] && [ "$mmu_state" = disabled ] &&
                { [ "$halted_pc_hex" = 00000000000800e0 ] ||
                  [ "$halted_pc_hex" = 00000000000800e4 ]; } &&
                grep -qx 'takibi-reset: installed SD stub signature' "$VERIFY_LOG"; then
            verified=true
            break
        fi
    fi
    sleep "$RESET_RETRY_SECONDS"
done
rm -f "$VERIFY_LOG"

if [ "$verified" = true ]; then
    echo "reset confirmed: installed Takibi SD stub (PC=$halted_pc mode=$current_mode MMU=$mmu_state)"
else
    echo "warning: no verified MMU-off SD stub after $RESET_MAX_ATTEMPTS attempts (last PC=${halted_pc:-unknown} mode=${current_mode:-unknown} MMU=${mmu_state:-unknown})" >&2
    echo "A resident EL1 image does not certify reset. Power-cycle the RPi5 if the SD stub does not return." >&2
    exit 1
fi
