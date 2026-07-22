#!/usr/bin/env bash
# STM32 Ethernet hardware integration tests -- RAM-execution variant,
# called from repo root via: make hwcheck-stm32-net
#
# Supersedes the original run_hwtest_net.sh (deleted -- git history has
# it), which flashed each example over st-flash. Same OpenOCD
# load-into-AXI-SRAM1-and-poke-SP/PC/VTOR technique as
# scripts/run_hwtest_ram.sh (see that file and examples/common_stm32/
# startup_ram.S for the full mechanism) -- no Flash write happens here
# either.
#
# The one thing genuinely new here, not just "the same trick applied to
# more examples": these 5 examples' DMA descriptor rings and packet
# buffers live in AXI SRAM1 with NO MPU non-cacheable window, so the
# region is genuinely cacheable and examples/common_stm32/eth.tkb's
# existing dma_prepare_tx/dma_prepare_rx/dma_finish_rx calls are, for the
# first time, actually load-bearing rather than operating on memory where
# they were previously architectural no-ops. This is exactly why these
# tests matter here: they exercise real DMA traffic (RX/TX descriptor
# completion, real frame payloads) over a real wire, which UART-diff tests
# never could -- see HISTORY.md's RAM-execution entries for the full
# reasoning and the code-reading pass that preceded running this for real.
#
# http_server is tested TWICE, deliberately (see run_net_hw_test_flash
# below): once via RAM execution like every other example here, and once
# via a genuine `st-flash write` + `st-flash reset` of its Flash build --
# the same non-debugger-mediated sequence `make stm32-http-server` itself
# performs. examples/http_server is the one STM32 example that still ships
# a Flash build at all (see the Makefile's STM32_RAM_EXAMPLES comment for
# why), specifically so a demo unit can boot standalone from power-on with
# no debugger attached -- and that Flash-execution boot path (the real
# hardware SP/PC vector fetch from address 0x0, not a debugger poking
# registers after `reset halt`) is otherwise completely unexercised by any
# automated test in this repository, since every other example dropped
# its Flash build entirely.
#
# Separate from scripts/run_hwtest_ram.sh (make hwcheck-stm32): these tests need
# a raw AF_PACKET socket (CAP_NET_RAW, i.e. sudo) and a physical Ethernet
# cable wired directly from the STM32F746G-DISCOVERY board to this
# machine's NIC, not just the USB/SWD connection every other hwcheck-stm32 test
# needs. PASS/FAIL is judged by each Python test script's exit code (they
# print their own per-case detail lines), not a UART capture/diff.
#
# NOT part of `make check`/`make hwcheck-stm32`: unlike those, this can't run on
# an arbitrary clone of this repo with just a board plugged in over USB --
# it needs the Ethernet cable actually wired to this machine and
# CAP_NET_RAW.
#
# http_server_sdcard (GitHub issue #97) additionally needs no human to
# ever touch the SD card: before that test runs, this script shells out to
# scripts/provision_http_server_sdcard.sh, which provisions the card with
# a real mtools-built FAT12 image via examples/http_server_sdcard_install/
# http_server_sdcard_install.tkb -- shared with `make stm32-http-server-
# sdcard` (see that script's own header comment), not duplicated here.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
: "${STM32_SERIAL_DEV:?STM32_SERIAL_DEV is required; run 'make hwcheck-stm32-net' or set it explicitly}"
SERIAL_DEV="$STM32_SERIAL_DEV"
OPENOCD_BOARD_CFG="board/stm32f746g-disco.cfg"
FLASH_ADDR=0x08000000
HWTEST_ARTIFACT_ROOT="${STM32_NET_HWTEST_ARTIFACT_DIR:-$REPO_ROOT/_build/hwtest-stm32-net}"
mkdir -p "$HWTEST_ARTIFACT_ROOT"
exec > >(tee "$HWTEST_ARTIFACT_ROOT/run.log") 2>&1

# shellcheck source=scripts/test_artifacts.sh
source "$REPO_ROOT/scripts/test_artifacts.sh"

stty -F "$SERIAL_DEV" 115200 raw -echo
ACTIVE_UART_PID=""
start_uart_capture() {
    local artifact_dir="$1" filename="${2:-uart.log}"
    timeout 0.25 cat "$SERIAL_DEV" > /dev/null 2>&1 || true
    cat "$SERIAL_DEV" > "$artifact_dir/$filename" &
    ACTIVE_UART_PID=$!
}
stop_uart_capture() {
    if [ -n "$ACTIVE_UART_PID" ]; then
        kill "$ACTIVE_UART_PID" 2>/dev/null || true
        wait "$ACTIVE_UART_PID" 2>/dev/null || true
        ACTIVE_UART_PID=""
    fi
}
trap stop_uart_capture EXIT
trap 'stop_uart_capture; exit 130' INT TERM HUP
PASS=0
FAIL=0
FAILED_TESTS=()
NET_L2_ONLY="${NET_L2_ONLY:-0}"

# shellcheck source=scripts/stm32_hw_claim.sh
source "$(dirname "$0")/stm32_hw_claim.sh"
claim_stm32_hardware "$SERIAL_DEV"

if [ -t 1 ]; then
    GRN='\033[32m' RED='\033[31m' RST='\033[0m'
else
    GRN='' RED='' RST=''
fi

if ! st-info --probe > /dev/null 2>&1; then
    echo "error: st-info --probe failed -- is the ST-LINK debug interface accessible?" >&2
    exit 1
fi

# ram_load_and_run ELF
#
# Identical technique and identical reasoning for `reset halt` (never
# `reset init`) as scripts/run_hwtest_ram.sh's function of the same name
# -- see that file's comment for the full explanation. Duplicated rather
# than sourced from a shared file, matching this test suite's existing
# convention of each runner being self-contained.
ram_load_and_run() {
    local elf="$1" log="$2"
    if openocd -f "$OPENOCD_BOARD_CFG" \
        -c "init" \
        -c "reset halt" \
        -c "load_image $elf 0 elf" \
        -c "set vec0 [mrw 0x20010000]" \
        -c "set vec1 [mrw 0x20010004]" \
        -c "set pcval [expr {\$vec1 & ~1}]" \
        -c "reg sp \$vec0" \
        -c "reg pc \$pcval" \
        -c "resume" \
        -c "shutdown" > "$log" 2>&1
    then
        return 0
    else
        echo "openocd RAM load failed:" >&2
        sed 's/^/       /' "$log" >&2
        return 1
    fi
}

# run_net_hw_test NAME ELF TEST_SCRIPT
#
# Loads ELF into AXI SRAM1 and starts it, then runs TEST_SCRIPT (a
# raw-socket Python test against the physical link, e.g.
# scripts/eth_net_echo_test.py) via sudo. No fixed post-load sleep: these
# test scripts already resend on every retry (same pattern as
# scripts/virtio_net_test.py), which already covers PHY-autonegotiation
# latency without a hardcoded wait.
run_net_hw_test() {
    local name="$1" elf="$2" test_script="$3"
    local artifact_dir

    prepare_artifact_dir "$HWTEST_ARTIFACT_ROOT" "$name"
    artifact_dir="$ARTIFACT_DIR"
    start_uart_capture "$artifact_dir"
    if ! ram_load_and_run "$elf" "$artifact_dir/loader.log"; then
        stop_uart_capture
        printf "${RED}FAIL${RST}  %s  (openocd RAM load failed)\n" "$name"
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$name")
        return
    fi

    echo "-- $name --"
    if sudo python3 "$test_script" > >(tee "$artifact_dir/host.log") 2>&1; then
        stop_uart_capture
        printf "${GRN}PASS${RST}  %s\n" "$name"
        PASS=$((PASS + 1))
    else
        stop_uart_capture
        printf "${RED}FAIL${RST}  %s\n" "$name"
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$name")
    fi
}

# run_net_hw_test_flash NAME BIN TEST_SCRIPT
#
# Counterpart of run_net_hw_test for examples/http_server's Flash build
# specifically: a genuine `st-flash write` + `st-flash reset` (matching
# `make stm32-http-server`'s own sequence exactly, including
# --connect-under-reset for both steps), not the OpenOCD RAM-load
# technique -- see this file's header comment for why this one example
# needs its own real Flash boot exercised by an automated test, not just
# the RAM-execution path every other test here uses.
run_net_hw_test_flash() {
    local name="$1" bin="$2" test_script="$3"
    local artifact_dir tmp_flash_log
    prepare_artifact_dir "$HWTEST_ARTIFACT_ROOT" "$name"
    artifact_dir="$ARTIFACT_DIR"
    tmp_flash_log="$artifact_dir/flash-write.log"

    if ! st-flash --connect-under-reset write "$bin" "$FLASH_ADDR" > "$tmp_flash_log" 2>&1; then
        printf "${RED}FAIL${RST}  %s  (st-flash write failed)\n" "$name"
        sed 's/^/       /' "$tmp_flash_log"
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$name")
        return
    fi
    start_uart_capture "$artifact_dir"
    if ! st-flash --connect-under-reset reset > "$artifact_dir/flash-reset.log" 2>&1; then
        stop_uart_capture
        printf "${RED}FAIL${RST}  %s  (st-flash reset failed)\n" "$name"
        sed 's/^/       /' "$artifact_dir/flash-reset.log"
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$name")
        return
    fi

    echo "-- $name --"
    if sudo python3 "$test_script" > >(tee "$artifact_dir/host.log") 2>&1; then
        stop_uart_capture
        printf "${GRN}PASS${RST}  %s\n" "$name"
        PASS=$((PASS + 1))
    else
        stop_uart_capture
        printf "${RED}FAIL${RST}  %s\n" "$name"
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$name")
    fi
}

echo "Running STM32 Ethernet hardware integration tests (RAM execution)..."
echo ""

if [ "$NET_L2_ONLY" = 1 ]; then
    run_net_hw_test "net_echo (stm32/ram)" examples/net_echo/kernel_stm32_ram.elf scripts/eth_net_echo_test.py
    run_net_hw_test "arp_reply (stm32/ram)" examples/arp_reply/kernel_stm32_ram.elf scripts/eth_arp_reply_test.py
    run_net_hw_test "icmp_echo (stm32/ram)" examples/icmp_echo/kernel_stm32_ram.elf scripts/eth_icmp_echo_test.py
    echo ""
    echo "STM32 Ethernet L2 hardware tests: $PASS passed, $FAIL failed"
    [ "$FAIL" -eq 0 ] || exit 1
    exit 0
fi
run_net_hw_test "tcp_echo (stm32/ram)" examples/tcp_echo/kernel_stm32_ram.elf scripts/eth_tcp_echo_test.py
run_net_hw_test "http_server (stm32/ram)" examples/http_server/kernel_stm32_ram.elf scripts/eth_http_server_test.py

# http_server only: also exercise the real Flash boot path (see this
# file's header comment and run_net_hw_test_flash's comment for why this
# is deliberately NOT redundant with the RAM test just above).
run_net_hw_test_flash "http_server (stm32/flash)" examples/http_server/kernel_stm32.bin scripts/eth_http_server_test.py

# http_server_sdcard (GitHub issue #97): provisions the real SD card with
# a genuine mtools-built FAT12 image (no human touches the card), then
# runs http_server_sdcard.tkb and verifies over HTTP that the served page
# really is the SD card's own file content. See
# examples/http_server_sdcard/http_server_sdcard.tkb's header comment for
# the milestone (--forbid-trap deliberately off for now).
sdcard_content_dir="examples/sdcard_content"
sdcard_name="http_server_sdcard (stm32/ram)"
prepare_artifact_dir "$HWTEST_ARTIFACT_ROOT" "$sdcard_name"
sdcard_artifact_dir="$ARTIFACT_DIR"
sdcard_provision_log="$sdcard_artifact_dir/provision.log"
if ! bash scripts/provision_http_server_sdcard.sh \
        examples/http_server_sdcard_install/kernel_stm32_ram.elf \
        "$sdcard_content_dir" > "$sdcard_provision_log" 2>&1; then
    printf "${RED}FAIL${RST}  %s  (SD card provisioning failed)\n" "$sdcard_name"
    sed 's/^/       /' "$sdcard_provision_log"
    FAIL=$((FAIL + 1))
    FAILED_TESTS+=("$sdcard_name")
else
    start_uart_capture "$sdcard_artifact_dir"
    if ! ram_load_and_run examples/http_server_sdcard/kernel_stm32_ram.elf "$sdcard_artifact_dir/loader.log"; then
        stop_uart_capture
        printf "${RED}FAIL${RST}  %s  (openocd RAM load failed)\n" "$sdcard_name"
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$sdcard_name")
    else
        # SDCARD_CONTENT_DIR must be passed on sudo's OWN command line (not
        # just exported in this shell) -- sudo's default env_reset strips
        # ordinary environment variables that aren't in env_keep, confirmed
        # empirically before writing this.
        echo "-- $sdcard_name --"
        if sudo SDCARD_CONTENT_DIR="$sdcard_content_dir" \
                python3 scripts/eth_http_server_sdcard_test.py \
                > >(tee "$sdcard_artifact_dir/host.log") 2>&1; then
            stop_uart_capture
            printf "${GRN}PASS${RST}  %s\n" "$sdcard_name"
            PASS=$((PASS + 1))
        else
            stop_uart_capture
            printf "${RED}FAIL${RST}  %s\n" "$sdcard_name"
            FAIL=$((FAIL + 1))
            FAILED_TESTS+=("$sdcard_name")
        fi
    fi
fi

sdcard_rtos_name="http_server_sdcard_rtos (stm32/ram)"
prepare_artifact_dir "$HWTEST_ARTIFACT_ROOT" "$sdcard_rtos_name"
sdcard_rtos_artifact_dir="$ARTIFACT_DIR"
start_uart_capture "$sdcard_rtos_artifact_dir"
if ! ram_load_and_run examples/http_server_sdcard_rtos/kernel_stm32_ram.elf "$sdcard_rtos_artifact_dir/loader.log"; then
    stop_uart_capture
    printf "${RED}FAIL${RST}  %s  (openocd RAM load failed)\n" "$sdcard_rtos_name"
    FAIL=$((FAIL + 1))
    FAILED_TESTS+=("$sdcard_rtos_name")
else
    echo "-- $sdcard_rtos_name --"
    if sudo SDCARD_CONTENT_DIR="$sdcard_content_dir" \
            python3 scripts/eth_http_server_sdcard_test.py \
            > >(tee "$sdcard_rtos_artifact_dir/host.log") 2>&1; then
        stop_uart_capture
        printf "${GRN}PASS${RST}  %s\n" "$sdcard_rtos_name"
        PASS=$((PASS + 1))
    else
        stop_uart_capture
        printf "${RED}FAIL${RST}  %s\n" "$sdcard_rtos_name"
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$sdcard_rtos_name")
    fi
fi

# http_server_sdcard only: also exercise the real Flash boot path (same
# reasoning as http_server's own two-test split just above). The SD card
# itself is untouched by which firmware image is running on the MCU --
# it was already provisioned once, above, via
# scripts/provision_http_server_sdcard.sh -- so this reuses that same
# content rather than re-provisioning it.
# run_net_hw_test_flash is not reused here (unlike http_server's own Flash
# test) because SDCARD_CONTENT_DIR has to be passed on sudo's own
# command line (see the comment above), which that shared helper's plain
# `sudo python3` call does not do.
sdcard_flash_name="http_server_sdcard (stm32/flash)"
prepare_artifact_dir "$HWTEST_ARTIFACT_ROOT" "$sdcard_flash_name"
sdcard_flash_artifact_dir="$ARTIFACT_DIR"
tmp_sdcard_flash_log="$sdcard_flash_artifact_dir/flash-write.log"
if ! st-flash --connect-under-reset write examples/http_server_sdcard/kernel_stm32.bin "$FLASH_ADDR" > "$tmp_sdcard_flash_log" 2>&1; then
    printf "${RED}FAIL${RST}  %s  (st-flash write failed)\n" "$sdcard_flash_name"
    sed 's/^/       /' "$tmp_sdcard_flash_log"
    FAIL=$((FAIL + 1))
    FAILED_TESTS+=("$sdcard_flash_name")
else
    start_uart_capture "$sdcard_flash_artifact_dir"
    if ! st-flash --connect-under-reset reset > "$sdcard_flash_artifact_dir/flash-reset.log" 2>&1; then
        stop_uart_capture
        printf "${RED}FAIL${RST}  %s  (st-flash reset failed)\n" "$sdcard_flash_name"
        sed 's/^/       /' "$sdcard_flash_artifact_dir/flash-reset.log"
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$sdcard_flash_name")
    else
        echo "-- $sdcard_flash_name --"
        if sudo SDCARD_CONTENT_DIR="$sdcard_content_dir" \
                python3 scripts/eth_http_server_sdcard_test.py \
                > >(tee "$sdcard_flash_artifact_dir/host.log") 2>&1; then
            stop_uart_capture
            printf "${GRN}PASS${RST}  %s\n" "$sdcard_flash_name"
            PASS=$((PASS + 1))
        else
            stop_uart_capture
            printf "${RED}FAIL${RST}  %s\n" "$sdcard_flash_name"
            FAIL=$((FAIL + 1))
            FAILED_TESTS+=("$sdcard_flash_name")
        fi
    fi
fi

# kvs_server_sdcard_rtos (GitHub issue #135 STM32 milestone): real Ethernet
# + real SD-card persistence through FAT12 + RTOS task separation, landed
# together as one milestone -- see examples/kvs_server_sdcard_rtos/
# kvs_server_sdcard_rtos.tkb's header comment. No SD provisioning step
# runs first (unlike http_server_sdcard/_rtos's FAT12 image seeding): this
# firmware creates its own table file on first boot if none exists, so
# whatever the http_server_sdcard(_rtos) sub-tests above already did to
# the card (their own FAT12 content, never a "KVSTABLEDAT" file) gives
# this test's first boot a real, non-contrived "no saved table yet" start
# every run.
#
# Run across TWO back-to-back RAM boots with NO reprovisioning between
# them -- the actual meaningful persistence proof, which the QEMU-side
# scripts/kvs_test.py has no analog for (a fresh QEMU process keeps no
# state across a restart at all): the first boot (KVS_TEST_PHASE=full,
# the script's own default) proves PUT/GET/DELETE/LIST work end to end
# over real Ethernet through the RTOS/SD-card wiring, and leaves one extra
# key durably written; the second boot (a genuine MCU reset via openocd,
# SD card physically untouched) proves that key is still readable, i.e.
# it survived a real reset, not just a RAM lifetime.
kvs_rtos_name="kvs_server_sdcard_rtos (stm32/ram)"
prepare_artifact_dir "$HWTEST_ARTIFACT_ROOT" "$kvs_rtos_name"
kvs_rtos_artifact_dir="$ARTIFACT_DIR"
start_uart_capture "$kvs_rtos_artifact_dir" uart-boot1.log
if ! ram_load_and_run examples/kvs_server_sdcard_rtos/kernel_stm32_ram.elf "$kvs_rtos_artifact_dir/loader-boot1.log"; then
    stop_uart_capture
    printf "${RED}FAIL${RST}  %s  (openocd RAM load failed, boot 1)\n" "$kvs_rtos_name"
    FAIL=$((FAIL + 1))
    FAILED_TESTS+=("$kvs_rtos_name")
else
    echo "-- $kvs_rtos_name --"
    if ! sudo python3 scripts/eth_kvs_server_stm32_test.py \
            > >(tee "$kvs_rtos_artifact_dir/host-boot1.log") 2>&1; then
        stop_uart_capture
        printf "${RED}FAIL${RST}  %s  (protocol test failed, boot 1)\n" "$kvs_rtos_name"
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$kvs_rtos_name")
    else
        stop_uart_capture
        start_uart_capture "$kvs_rtos_artifact_dir" uart-boot2.log
        if ! ram_load_and_run examples/kvs_server_sdcard_rtos/kernel_stm32_ram.elf "$kvs_rtos_artifact_dir/loader-boot2.log"; then
            stop_uart_capture
            printf "${RED}FAIL${RST}  %s  (openocd RAM load failed, boot 2)\n" "$kvs_rtos_name"
            FAIL=$((FAIL + 1))
            FAILED_TESTS+=("$kvs_rtos_name")
        else
            echo "-- $kvs_rtos_name (persistence-survives-reset check) --"
            if sudo KVS_TEST_PHASE=verify_persistence python3 scripts/eth_kvs_server_stm32_test.py \
                    > >(tee "$kvs_rtos_artifact_dir/host-boot2.log") 2>&1; then
                stop_uart_capture
                printf "${GRN}PASS${RST}  %s\n" "$kvs_rtos_name"
                PASS=$((PASS + 1))
            else
                stop_uart_capture
                printf "${RED}FAIL${RST}  %s\n" "$kvs_rtos_name"
                FAIL=$((FAIL + 1))
                FAILED_TESTS+=("$kvs_rtos_name")
            fi
        fi
    fi
fi

# Add new Ethernet hardware tests here as they're ported.

echo ""
if [ "$FAIL" -eq 0 ]; then
    printf "${GRN}All $PASS Ethernet hardware test(s) passed.${RST}\n"
else
    printf "${RED}$FAIL Ethernet hardware test(s) failed${RST} ($PASS passed).\n"
    printf "${RED}Failed:${RST}"
    for t in "${FAILED_TESTS[@]}"; do
        printf "  %s" "$t"
    done
    printf "\n"
fi

[ "$FAIL" -eq 0 ]
