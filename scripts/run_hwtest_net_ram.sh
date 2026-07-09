#!/usr/bin/env bash
# STM32 Ethernet hardware integration tests -- RAM-execution variant,
# called from repo root via: make hwcheck-net
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
# Separate from scripts/run_hwtest_ram.sh (make hwcheck): these tests need
# a raw AF_PACKET socket (CAP_NET_RAW, i.e. sudo) and a physical Ethernet
# cable wired directly from the STM32F746G-DISCOVERY board to this
# machine's NIC, not just the USB/SWD connection every other hwcheck test
# needs. PASS/FAIL is judged by each Python test script's exit code (they
# print their own per-case detail lines), not a UART capture/diff.
#
# NOT part of `make check`/`make hwcheck`: unlike those, this can't run on
# an arbitrary clone of this repo with just a board plugged in over USB --
# it needs the Ethernet cable actually wired to this machine and
# CAP_NET_RAW.
set -euo pipefail

: "${STM32_SERIAL_DEV:?STM32_SERIAL_DEV is required; run 'make hwcheck-net' or set it explicitly}"
SERIAL_DEV="$STM32_SERIAL_DEV"
OPENOCD_BOARD_CFG="board/stm32f746g-disco.cfg"
FLASH_ADDR=0x08000000
PASS=0
FAIL=0
FAILED_TESTS=()

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
    local elf="$1" log
    log=$(mktemp)
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
        rm -f "$log"
        return 0
    else
        echo "openocd RAM load failed:" >&2
        sed 's/^/       /' "$log" >&2
        rm -f "$log"
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

    if ! ram_load_and_run "$elf"; then
        printf "${RED}FAIL${RST}  %s  (openocd RAM load failed)\n" "$name"
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$name")
        return
    fi

    echo "-- $name --"
    if sudo python3 "$test_script"; then
        printf "${GRN}PASS${RST}  %s\n" "$name"
        PASS=$((PASS + 1))
    else
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
    local tmp_flash_log
    tmp_flash_log=$(mktemp)

    if ! st-flash --connect-under-reset write "$bin" "$FLASH_ADDR" > "$tmp_flash_log" 2>&1; then
        printf "${RED}FAIL${RST}  %s  (st-flash write failed)\n" "$name"
        sed 's/^/       /' "$tmp_flash_log"
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$name")
        rm -f "$tmp_flash_log"
        return
    fi
    if ! st-flash --connect-under-reset reset > "$tmp_flash_log" 2>&1; then
        printf "${RED}FAIL${RST}  %s  (st-flash reset failed)\n" "$name"
        sed 's/^/       /' "$tmp_flash_log"
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$name")
        rm -f "$tmp_flash_log"
        return
    fi
    rm -f "$tmp_flash_log"

    echo "-- $name --"
    if sudo python3 "$test_script"; then
        printf "${GRN}PASS${RST}  %s\n" "$name"
        PASS=$((PASS + 1))
    else
        printf "${RED}FAIL${RST}  %s\n" "$name"
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$name")
    fi
}

echo "Running STM32 Ethernet hardware integration tests (RAM execution)..."
echo ""

run_net_hw_test "net_echo (stm32/ram)" examples/net_echo/kernel_stm32_ram.elf scripts/eth_net_echo_test.py
run_net_hw_test "arp_reply (stm32/ram)" examples/arp_reply/kernel_stm32_ram.elf scripts/eth_arp_reply_test.py
run_net_hw_test "icmp_echo (stm32/ram)" examples/icmp_echo/kernel_stm32_ram.elf scripts/eth_icmp_echo_test.py
run_net_hw_test "tcp_echo (stm32/ram)" examples/tcp_echo/kernel_stm32_ram.elf scripts/eth_tcp_echo_test.py
run_net_hw_test "http_server (stm32/ram)" examples/http_server/kernel_stm32_ram.elf scripts/eth_http_server_test.py

# http_server only: also exercise the real Flash boot path (see this
# file's header comment and run_net_hw_test_flash's comment for why this
# is deliberately NOT redundant with the RAM test just above).
run_net_hw_test_flash "http_server (stm32/flash)" examples/http_server/kernel_stm32.bin scripts/eth_http_server_test.py

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
