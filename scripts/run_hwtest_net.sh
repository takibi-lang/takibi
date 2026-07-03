#!/usr/bin/env bash
# STM32 Ethernet hardware integration tests -- called from repo root via:
# make hwcheck-net
#
# Separate from scripts/run_hwtest.sh (make hwcheck): these tests need a raw
# AF_PACKET socket (CAP_NET_RAW, i.e. sudo) and a physical Ethernet cable
# wired directly from the STM32F746G-DISCOVERY board to this machine's NIC,
# not just the USB/SWD connection every other hwcheck test needs. PASS/FAIL
# is judged by each Python test script's exit code (they print their own
# per-case detail lines), not a UART capture/diff like run_hwtest.sh.
#
# NOT part of `make check`/`make hwcheck`: unlike those, this can't run on an
# arbitrary clone of this repo with just a board plugged in over USB -- it
# needs the Ethernet cable actually wired to this machine and CAP_NET_RAW.
set -euo pipefail

FLASH_ADDR=0x08000000
PASS=0
FAIL=0
FAILED_TESTS=()

if [ -t 1 ]; then
    GRN='\033[32m' RED='\033[31m' RST='\033[0m'
else
    GRN='' RED='' RST=''
fi

if ! st-info --probe > /dev/null 2>&1; then
    echo "error: st-info --probe failed -- is the ST-LINK debug interface accessible?" >&2
    exit 1
fi

# run_net_hw_test NAME BIN TEST_SCRIPT
#
# Flashes BIN, resets the board, and runs TEST_SCRIPT (a raw-socket Python
# test against the physical link, e.g. scripts/eth_net_echo_test.py) via
# sudo. No fixed post-reset sleep: these test scripts already resend on every
# retry (same pattern as scripts/virtio_net_test.py), which already covers
# boot/PHY-autonegotiation latency without a hardcoded wait.
run_net_hw_test() {
    local name="$1" bin="$2" test_script="$3"
    local tmp_flash_log
    tmp_flash_log=$(mktemp)

    if ! st-flash write "$bin" "$FLASH_ADDR" > "$tmp_flash_log" 2>&1; then
        printf "${RED}FAIL${RST}  %s  (st-flash write failed)\n" "$name"
        sed 's/^/       /' "$tmp_flash_log"
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$name")
        rm -f "$tmp_flash_log"
        return
    fi
    st-flash reset > /dev/null 2>&1

    echo "-- $name --"
    if sudo python3 "$test_script"; then
        printf "${GRN}PASS${RST}  %s\n" "$name"
        PASS=$((PASS + 1))
    else
        printf "${RED}FAIL${RST}  %s\n" "$name"
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$name")
    fi
    rm -f "$tmp_flash_log"
}

echo "Running STM32 Ethernet hardware integration tests..."
echo ""

run_net_hw_test "net_echo (stm32)" examples/net_echo/kernel_stm32.bin scripts/eth_net_echo_test.py
run_net_hw_test "arp_reply (stm32)" examples/arp_reply/kernel_stm32.bin scripts/eth_arp_reply_test.py
run_net_hw_test "icmp_echo (stm32)" examples/icmp_echo/kernel_stm32.bin scripts/eth_icmp_echo_test.py
run_net_hw_test "tcp_echo (stm32)" examples/tcp_echo/kernel_stm32.bin scripts/eth_tcp_echo_test.py
run_net_hw_test "http_server (stm32)" examples/http_server/kernel_stm32.bin scripts/eth_http_server_test.py

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
