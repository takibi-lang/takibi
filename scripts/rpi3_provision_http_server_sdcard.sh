#!/usr/bin/env bash
# Provisions examples/http_server_sdcard's real USB Mass Storage drive
# (Raspberry Pi 3B counterpart of scripts/provision_http_server_sdcard.sh)
# with a genuine mtools-built FAT12 image populated from
# examples/sdcard_content/, via examples/http_server_sdcard_install/
# http_server_sdcard_install.tkb -- so no human ever needs to touch the
# drive. See that file's own header comment for the fiddly
# two-breakpoint OpenOCD sequence this mirrors byte-for-byte, adapted
# for this board's own JTAG probe/target config and injection-safety
# check (scripts/rpi3_jtag_load.sh's EL2H check -- reused here rather
# than re-derived, since a still-running-Raspbian board is exactly as
# dangerous to write into during provisioning as during a normal
# example injection).
#
# Usage: rpi3_provision_http_server_sdcard.sh [INSTALLER_ELF] [CONTENT_DIR]
#   INSTALLER_ELF  defaults to examples/http_server_sdcard_install/kernel_rpi3.elf
#   CONTENT_DIR    defaults to examples/sdcard_content and is copied into
#                  the FAT12 root directory. Keep filenames 8.3-compatible.
#
# On success: prints a confirmation and exits 0.
# On failure: prints a specific diagnostic to stderr and exits 1 --
# distinguishing "no drive attached" (disk_initialize failed inside the
# installer) from "a write genuinely failed" (drive present but bad) from
# "JTAG itself failed", read back via OpenOCD's `mdw` against
# install_result at the same halt the harness already synchronizes on --
# not by scraping UART text, and not left to show up later as a
# mysterious 404 from the HTTP server. STM32's own
# scripts/provision_http_server_sdcard.sh uses `mrw` (returns the value
# inline for `echo`) instead -- confirmed on real hardware that this
# board's OpenOCD/target config does not expose `mrw` ("invalid command
# name") even though the underlying read works fine via `mdw`, which
# prints "0xADDR: XXXXXXXX" instead of returning a value, hence the
# different parsing below.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

INSTALLER_ELF="${1:-$REPO_ROOT/examples/http_server_sdcard_install/kernel_rpi3.elf}"
CONTENT_DIR="${2:-$REPO_ROOT/examples/sdcard_content}"

if [ ! -e "$INSTALLER_ELF" ]; then
    echo "error: $INSTALLER_ELF not found -- run 'make examples/http_server_sdcard_install/kernel_rpi3.elf' first" >&2
    exit 1
fi

if [ ! -d "$CONTENT_DIR" ]; then
    echo "error: $CONTENT_DIR not found -- SD card content directory is required" >&2
    exit 1
fi

if ! command -v mformat > /dev/null 2>&1 || ! command -v mcopy > /dev/null 2>&1; then
    echo "error: mtools (mformat/mcopy) not found -- required to build the FAT12 image" >&2
    exit 1
fi

tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

seed_img="$tmp_dir/seed.img"
mformat -C -i "$seed_img" -t 2 -h 2 -n 32 -c 1 -r 1 -L 1 :: > /dev/null
copied=0
while IFS= read -r -d '' file; do
    base=$(basename "$file")
    case "$base" in
        *[!A-Za-z0-9._-]* | *.*.* | .* | "")
            echo "error: unsupported SD card content filename: $base" >&2
            exit 1
            ;;
    esac
    stem=${base%.*}
    ext=${base##*.}
    if [ "$stem" = "$base" ]; then
        ext=""
    fi
    if [ "${#stem}" -gt 8 ] || [ "${#ext}" -gt 3 ]; then
        echo "error: SD card content filename is not 8.3-compatible: $base" >&2
        exit 1
    fi
    mcopy -i "$seed_img" "$file" "::$base"
    copied=$((copied + 1))
done < <(find "$CONTENT_DIR" -maxdepth 1 -type f -print0 | sort -z)

if [ "$copied" -eq 0 ]; then
    echo "error: $CONTENT_DIR contains no files to copy" >&2
    exit 1
fi

entry_pc="0x$(llvm-readelf-19 -h "$INSTALLER_ELF" | awk '/Entry point address/{sub(/^0x/,"",$NF); print $NF}')"
stack_top="0x$(llvm-nm-19 "$INSTALLER_ELF" | awk '$3=="stack_top"{print $1}')"
staging_addr="0x$(llvm-nm-19 "$INSTALLER_ELF" | awk '$3=="staging"{print $1}')"
app_main_addr="0x$(llvm-nm-19 "$INSTALLER_ELF" | awk '$3=="app_main"{print $1}')"
done_addr="0x$(llvm-nm-19 "$INSTALLER_ELF" | awk '$3=="install_done"{print $1}')"
result_addr="0x$(llvm-nm-19 "$INSTALLER_ELF" | awk '$3=="install_result"{print $1}')"

for sym_val in "$entry_pc:entry point" "$stack_top:stack_top" "$staging_addr:staging" \
               "$app_main_addr:app_main" "$done_addr:install_done" "$result_addr:install_result"; do
    val="${sym_val%%:*}"
    if [ -z "${val#0x}" ]; then
        echo "error: could not read ${sym_val#*:} from $INSTALLER_ELF" >&2
        exit 1
    fi
done

OPENOCD_ARGS=(
    -f interface/ftdi/olimex-arm-usb-tiny-h.cfg
    -c 'transport select jtag'
    -f target/bcm2837.cfg
    -c 'adapter speed 1000'
)

# Pass 1: same read-only EL2H safety check as scripts/rpi3_jtag_load.sh
# (see that script's own header comment for the full rationale) -- this
# provisioning path writes to RAM and the drive just like a normal
# example injection, so it needs the identical guard against catching a
# still-running Raspbian core.
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
current_mode=$(grep -oE 'current mode: EL[0-9][A-Za-z]' "$CHECK_LOG" | head -1 | awk '{print $3}')
if [ "$current_mode" != "EL2H" ]; then
    echo "error: halted core is at ${current_mode:-<unknown>}, not EL2H -- this is almost" \
         "certainly still-running Raspbian, not the JTAG stub. Refusing to provision" \
         "(would corrupt the running OS). See examples/common_rpi3/AGENTS.md /" \
         "scripts/rpi3_jtag_reset.sh." >&2
    rm -f "$CHECK_LOG"
    exit 1
fi
rm -f "$CHECK_LOG"

log=$(mktemp)
if ! openocd "${OPENOCD_ARGS[@]}" \
    -c 'init' \
    -c 'targets bcm2837.cpu0' \
    -c 'halt' \
    -c "load_image $INSTALLER_ELF 0 elf" \
    -c "reg sp $stack_top" \
    -c "reg pc $entry_pc" \
    -c "bp $app_main_addr 4 hw" \
    -c "resume" \
    -c "wait_halt 5000" \
    -c "load_image $seed_img $staging_addr" \
    -c "rbp $app_main_addr" \
    -c "bp $done_addr 4 hw" \
    -c "resume" \
    -c "wait_halt 30000" \
    -c "mdw $result_addr" \
    -c "rbp $done_addr" \
    -c "shutdown" > "$log" 2>&1
then
    echo "error: openocd failed while provisioning the USB drive:" >&2
    sed 's/^/       /' "$log" >&2
    exit 1
fi

# mdw prints "0xADDR: VALUE" with ADDR zero-padded to 32 bits (8 hex
# digits), not the full 64-bit width llvm-nm's own $result_addr uses --
# match on the value alone, since this is the only mdw output in the log.
result_hex=$(grep -oP '^0x[0-9a-fA-F]+: \K[0-9a-fA-F]+' "$log" | tail -1)
result=${result_hex:+$((16#$result_hex))}

case "$result" in
    1)
        echo "USB drive provisioned from $CONTENT_DIR ($copied file(s))."
        ;;
    2)
        echo "error: USB drive not detected (disk_initialize failed) -- is a drive attached to one of the board's USB-A ports?" >&2
        exit 1
        ;;
    3)
        echo "error: USB drive write failed -- a drive is present but at least one sector write did not succeed" >&2
        exit 1
        ;;
    *)
        echo "error: unexpected/missing install result (got '${result:-<none>}') -- openocd log follows:" >&2
        sed 's/^/       /' "$log" >&2
        exit 1
        ;;
esac
