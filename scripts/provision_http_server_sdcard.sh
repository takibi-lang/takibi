#!/usr/bin/env bash
# Provisions examples/http_server_sdcard's real SD card with a genuine
# mtools-built FAT12 image containing INDEX.TXT, via
# examples/http_server_sdcard_install/http_server_sdcard_install.tkb --
# so no human ever needs to touch the card. Shared by both
# `make hwcheck-net` (scripts/run_hwtest_net_ram.sh) and
# `make stm32-http-server-sdcard` (Makefile), factored out here instead of
# duplicated between them: both need byte-for-byte the same fiddly
# two-breakpoint OpenOCD sequence (see http_server_sdcard_install.tkb's
# own header comment for why it's shaped this way).
#
# Usage: provision_http_server_sdcard.sh [INSTALLER_ELF] [EXPECTED_TEXT]
#   INSTALLER_ELF  defaults to examples/http_server_sdcard_install/kernel_stm32_ram.elf
#   EXPECTED_TEXT  defaults to a generic demo message; a caller that will
#                  later verify the HTTP response (e.g.
#                  scripts/eth_http_server_sdcard_test.py) can override it
#                  to whatever it checks against.
#
# On success: prints a confirmation and exits 0.
# On failure: prints a specific diagnostic to stderr and exits 1 --
# distinguishing "no card inserted" (disk_initialize failed inside the
# installer) from "a write genuinely failed" (card present but bad) from
# "openocd/debug link itself failed" (board/ST-LINK problem), read back
# via OpenOCD's `mrw` against install_result at the same halt the harness
# already synchronizes on -- not by scraping UART text, and not left to
# show up later as a mysterious 404 from the HTTP server.
set -euo pipefail

INSTALLER_ELF="${1:-examples/http_server_sdcard_install/kernel_stm32_ram.elf}"
EXPECTED_TEXT="${2:-Hello from a real SD card, served over HTTP!}"

OPENOCD_BOARD_CFG="board/stm32f746g-disco.cfg"

if [ ! -e "$INSTALLER_ELF" ]; then
    echo "error: $INSTALLER_ELF not found -- run 'make stm32build' first" >&2
    exit 1
fi

if ! command -v mformat > /dev/null 2>&1 || ! command -v mcopy > /dev/null 2>&1; then
    echo "error: mtools (mformat/mcopy) not found -- required to build the FAT12 image" >&2
    exit 1
fi

if ! st-info --probe > /dev/null 2>&1; then
    echo "error: st-info --probe failed -- is the ST-LINK debug interface accessible?" >&2
    exit 1
fi

tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

seed_img="$tmp_dir/seed.img"
printf '%s' "$EXPECTED_TEXT" > "$tmp_dir/index.txt"
mformat -C -i "$seed_img" -t 2 -h 2 -n 32 -c 1 -r 1 -L 1 :: > /dev/null
mcopy -i "$seed_img" "$tmp_dir/index.txt" ::INDEX.TXT

staging_addr="0x$(llvm-nm-19 "$INSTALLER_ELF" | awk '$3=="staging"{print $1}')"
app_main_addr="0x$(llvm-nm-19 "$INSTALLER_ELF" | awk '$3=="app_main"{print $1}')"
done_addr="0x$(llvm-nm-19 "$INSTALLER_ELF" | awk '$3=="install_done"{print $1}')"
result_addr="0x$(llvm-nm-19 "$INSTALLER_ELF" | awk '$3=="install_result"{print $1}')"

log=$(mktemp)
if ! openocd -f "$OPENOCD_BOARD_CFG" \
    -c "init" \
    -c "reset halt" \
    -c "load_image $INSTALLER_ELF 0 elf" \
    -c "set vec0 [mrw 0x20010000]" \
    -c "set vec1 [mrw 0x20010004]" \
    -c "set pcval [expr {\$vec1 & ~1}]" \
    -c "reg sp \$vec0" \
    -c "reg pc \$pcval" \
    -c "bp $app_main_addr 2 hw" \
    -c "resume" \
    -c "wait_halt 5000" \
    -c "load_image $seed_img $staging_addr" \
    -c "rbp $app_main_addr" \
    -c "bp $done_addr 2 hw" \
    -c "resume" \
    -c "wait_halt 20000" \
    -c "echo INSTALL_RESULT:[mrw $result_addr]" \
    -c "rbp $done_addr" \
    -c "shutdown" > "$log" 2>&1
then
    echo "error: openocd failed while provisioning the SD card:" >&2
    sed 's/^/       /' "$log" >&2
    exit 1
fi

# mrw prints its value in hex (e.g. "0x1"), not decimal. Guard against an
# empty match (result_hex not found in the log at all) before handing it
# to $(( )) -- an empty arithmetic expression is a bash syntax error, not
# something that should crash this script instead of reporting cleanly
# through the case statement's fallback branch below.
result_hex=$(grep -oP 'INSTALL_RESULT:\K0x[0-9a-fA-F]+' "$log" | tail -1)
result=${result_hex:+$((result_hex))}

case "$result" in
    1)
        echo "SD card provisioned: INDEX.TXT written."
        ;;
    2)
        echo "error: SD card not detected (disk_initialize failed) -- is a card inserted in the STM32F746G-DISCOVERY's microSD slot?" >&2
        exit 1
        ;;
    3)
        echo "error: SD card write failed -- a card is present but at least one sector write did not succeed" >&2
        exit 1
        ;;
    *)
        echo "error: unexpected/missing install result (got '${result:-<none>}') -- openocd log follows:" >&2
        sed 's/^/       /' "$log" >&2
        exit 1
        ;;
esac
