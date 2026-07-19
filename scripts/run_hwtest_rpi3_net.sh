#!/usr/bin/env bash
# Raspberry Pi 3B Ethernet hardware integration tests -- the network-
# functional counterpart to scripts/run_hwtest_rpi3.sh's UART-only
# net_echo check (which only proves net_init() succeeds, not that
# frames actually round-trip). Mirrors scripts/run_hwtest_net_ram.sh's
# STM32 shape (same reused scripts/eth_*_test.py raw-socket scripts,
# same PASS/FAIL-by-exit-code judging), with two RPi3-specific
# differences: examples/common_rpi3/AGENTS.md's own JTAG-injection load
# path (scripts/rpi3_jtag_load.sh) instead of OpenOCD's RAM-load-and-
# poke-SP/PC technique, and this devcontainer's dedicated point-to-point
# NIC for this board (enp5s0, confirmed during the USB bring-up design
# pass -- examples/common_rpi3/netconfig.tkb's OUR_IP=192.168.20.2 is
# already chosen to live on this same /24) instead of STM32's own
# enp4s0.
#
# NOT part of `make check`/`make hwcheck-rpi3`: needs a raw AF_PACKET
# socket (CAP_NET_RAW, i.e. sudo) and the Ethernet cable actually wired
# to this machine, same reasoning as run_hwtest_net_ram.sh's own
# equivalent note.
#
# Privilege separation matters here specifically because this board's
# own JTAG/UART access is USB-based too (examples/common_rpi3/AGENTS.md's
# "sudo warning" section): running scripts/rpi3_jtag_load.sh under sudo
# breaks OpenOCD's access to the JTAG probe in this devcontainer. Only
# the Python test script (which genuinely needs CAP_NET_RAW) runs under
# sudo below; the JTAG load step never does.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export ETH_TEST_IFACE="${ETH_TEST_IFACE:-enp5s0}"
# scripts/eth_arp_reply_test.py and scripts/eth_icmp_echo_test.py default
# to STM32's own subnet/MAC (examples/common_stm32/netconfig.tkb) --
# override to this board's values (examples/common_rpi3/netconfig.tkb)
# so those two tests address the right board instead of silently timing
# out against an IP/MAC nothing on this wire owns. eth_net_echo_test.py
# doesn't need either override: it addresses frames to broadcast, not a
# fixed target IP/MAC.
export ETH_TEST_SUBNET="${ETH_TEST_SUBNET:-192.168.20}"
export ETH_TEST_MAC="${ETH_TEST_MAC:-02:00:20:00:00:02}"

PASS=0
FAIL=0
FAILED_TESTS=()

if [ -t 1 ]; then
    GRN='\033[32m' RED='\033[31m' RST='\033[0m'
else
    GRN='' RED='' RST=''
fi

# run_rpi3_net_test NAME ELF TEST_SCRIPT
#
# Loads ELF over JTAG (never under sudo -- see this file's own header
# comment) and resumes it, then runs TEST_SCRIPT via sudo.
#
# Unlike scripts/run_hwtest_net_ram.sh's STM32 equivalent (no fixed
# sleep -- its own net_init() is just MDIO/PHY link negotiation, fast
# enough that per-attempt retries alone cover it), this board's
# net_init() runs full USB enumeration (mailbox -> DWC2 core/port ->
# control transfers -> hub -> LAN9514 vendor protocol -> PHY
# autonegotiation) before the Ethernet link is even up, measured at
# several real seconds -- confirmed the hard way: running this test
# immediately after the JTAG resume (no settle delay) failed EVERY
# frame reproducibly, even though the per-frame retry budget
# (20 attempts x 0.5s = 10s) is individually longer than the actual
# boot delay; sending test frames while the board is still mid-
# enumeration appears to leave it in a state later frames don't
# recover from within the same retry budget, not just a slow first
# reply. A flat settle sleep is simpler and more robust here than
# trying to detect "ready" without a UART connection open concurrently
# with the raw-socket test.
SETTLE_SECS=4

run_rpi3_net_test() {
    local name="$1" elf="$2" test_script="$3"

    if ! bash "$REPO_ROOT/scripts/rpi3_jtag_load.sh" "$elf" > /dev/null; then
        printf "${RED}FAIL${RST}  %s  (JTAG injection failed -- see\n" "$name"
        printf "       examples/common_rpi3/AGENTS.md; likely needs a power cycle to\n"
        printf "       examples/common_rpi3/jtag_stub.img)\n"
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$name")
        return
    fi
    sleep "$SETTLE_SECS"

    echo "-- $name --"
    # sudo resets the environment by default -- ETH_TEST_IFACE must be
    # passed explicitly as part of the invoked command, not just
    # exported in this script's own shell, or the test script silently
    # falls back to its default enp4s0 (STM32's interface) and every
    # frame times out against the wrong wire. Confirmed the hard way:
    # this exact omission produced a 100%-fail run indistinguishable at
    # first glance from a genuine board-side bug.
    if sudo ETH_TEST_IFACE="$ETH_TEST_IFACE" ETH_TEST_SUBNET="$ETH_TEST_SUBNET" ETH_TEST_MAC="$ETH_TEST_MAC" python3 "$test_script"; then
        printf "${GRN}PASS${RST}  %s\n" "$name"
        PASS=$((PASS + 1))
    else
        printf "${RED}FAIL${RST}  %s\n" "$name"
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$name")
    fi
}

run_rpi3_net_test "net_echo (rpi3)"   "$REPO_ROOT/examples/net_echo/kernel_rpi3.elf"   "$REPO_ROOT/scripts/eth_net_echo_test.py"
run_rpi3_net_test "arp_reply (rpi3)"  "$REPO_ROOT/examples/arp_reply/kernel_rpi3.elf"  "$REPO_ROOT/scripts/eth_arp_reply_test.py"
run_rpi3_net_test "icmp_echo (rpi3)"  "$REPO_ROOT/examples/icmp_echo/kernel_rpi3.elf"  "$REPO_ROOT/scripts/eth_icmp_echo_test.py"
run_rpi3_net_test "tcp_echo (rpi3)"   "$REPO_ROOT/examples/tcp_echo/kernel_rpi3.elf"   "$REPO_ROOT/scripts/eth_tcp_echo_test.py"
run_rpi3_net_test "http_server (rpi3)" "$REPO_ROOT/examples/http_server/kernel_rpi3.elf" "$REPO_ROOT/scripts/eth_http_server_test.py"
run_rpi3_net_test "kvs_server (rpi3)"  "$REPO_ROOT/examples/kvs_server/kernel_rpi3.elf"  "$REPO_ROOT/scripts/eth_kvs_server_test.py"

echo ""
echo "rpi3 network hardware tests: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
    echo "failed tests:"
    for t in "${FAILED_TESTS[@]}"; do
        echo "  - $t"
    done
    exit 1
fi
