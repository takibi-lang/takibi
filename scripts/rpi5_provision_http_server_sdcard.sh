#!/usr/bin/env bash
# Build a small FAT12 image from examples/sdcard_content and copy it to the
# RPi5's attached USB Mass Storage device through the installer firmware.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALLER_ELF="${1:-$REPO_ROOT/examples/http_server_sdcard_install/kernel_rpi5.elf}"
CONTENT_DIR="${2:-$REPO_ROOT/examples/sdcard_content}"
BCM2712_CFG="$REPO_ROOT/examples/common_rpi5/bcm2712.cfg"

if [ ! -f "$INSTALLER_ELF" ]; then
    echo "error: $INSTALLER_ELF not found -- build it first" >&2
    exit 1
fi
if [ ! -d "$CONTENT_DIR" ]; then
    echo "error: $CONTENT_DIR not found" >&2
    exit 1
fi
if ! command -v mformat >/dev/null || ! command -v mcopy >/dev/null; then
    echo "error: mtools (mformat/mcopy) is required" >&2
    exit 1
fi

tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT
seed_img="$tmp_dir/seed.img"
mformat -C -i "$seed_img" -t 2 -h 2 -n 32 -c 1 -r 1 -L 1 :: >/dev/null

copied=0
while IFS= read -r -d '' file; do
    base=$(basename "$file")
    case "$base" in
        *[!A-Za-z0-9._-]* | *.*.* | .* | "")
            echo "error: unsupported content filename: $base" >&2
            exit 1
            ;;
    esac
    stem=${base%.*}
    ext=${base##*.}
    [ "$stem" != "$base" ] || ext=""
    if [ "${#stem}" -gt 8 ] || [ "${#ext}" -gt 3 ]; then
        echo "error: filename is not 8.3-compatible: $base" >&2
        exit 1
    fi
    mcopy -i "$seed_img" "$file" "::$base"
    copied=$((copied + 1))
done < <(find "$CONTENT_DIR" -maxdepth 1 -type f -print0 | sort -z)
[ "$copied" -gt 0 ] || { echo "error: no content files found" >&2; exit 1; }

entry_pc="0x$(llvm-readelf-19 -h "$INSTALLER_ELF" | awk '/Entry point address/{sub(/^0x/,"",$NF); print $NF}')"
stack_top="0x$(llvm-nm-19 "$INSTALLER_ELF" | awk '$3=="stack_top"{print $1}')"
staging_addr="0x$(llvm-nm-19 "$INSTALLER_ELF" | awk '$3=="staging"{print $1}')"
app_main_addr="0x$(llvm-nm-19 "$INSTALLER_ELF" | awk '$3=="app_main"{print $1}')"
done_addr="0x$(llvm-nm-19 "$INSTALLER_ELF" | awk '$3=="install_done"{print $1}')"
result_addr="0x$(llvm-nm-19 "$INSTALLER_ELF" | awk '$3=="install_result"{print $1}')"

for value in "$entry_pc" "$stack_top" "$staging_addr" "$app_main_addr" "$done_addr" "$result_addr"; do
    [ -n "${value#0x}" ] || { echo "error: installer symbol lookup failed" >&2; exit 1; }
done

# Establish the same known-safe stub state as every other RPi5 hardware test.
"$REPO_ROOT/scripts/rpi5_jtag_reset.sh" >/dev/null

log="$tmp_dir/openocd.log"
if ! openocd -f interface/cmsis-dap.cfg -f "$BCM2712_CFG" \
    -c 'init' \
    -c 'targets bcm2712.cpu0' \
    -c 'halt' \
    -c 'targets bcm2712.cpu3' \
    -c 'halt' \
    -c "load_image $INSTALLER_ELF 0 elf" \
    -c 'targets bcm2712.cpu0' \
    -c "reg sp $stack_top" \
    -c "reg pc $entry_pc" \
    -c "bp $app_main_addr 4 hw" \
    -c 'resume' \
    -c 'wait_halt 10000' \
    -c 'targets bcm2712.cpu3' \
    -c 'halt' \
    -c "load_image $seed_img $staging_addr" \
    -c 'targets bcm2712.cpu0' \
    -c "rbp $app_main_addr" \
    -c "bp $done_addr 4 hw" \
    -c 'resume' \
    -c 'wait_halt 60000' \
    -c "mdw $result_addr" \
    -c "rbp $done_addr" \
    -c 'targets bcm2712.cpu3' \
    -c 'resume' \
    -c 'shutdown' >"$log" 2>&1; then
    echo "error: OpenOCD failed while provisioning the USB drive" >&2
    sed 's/^/       /' "$log" >&2
    exit 1
fi

result_hex=$(grep -oP '^0x[0-9a-fA-F]+: \K[0-9a-fA-F]+' "$log" | tail -1)
result=${result_hex:+$((16#$result_hex))}
case "$result" in
    1) echo "USB drive provisioned from $CONTENT_DIR ($copied file(s))." ;;
    2) echo "error: USB drive not detected" >&2; exit 1 ;;
    3) echo "error: USB drive write failed" >&2; exit 1 ;;
    *) echo "error: missing installer result" >&2; sed 's/^/       /' "$log" >&2; exit 1 ;;
esac
