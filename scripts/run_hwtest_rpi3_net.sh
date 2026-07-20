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
# RTOS + storage examples (http_server_sdcard_rtos/kvs_server_sdcard_rtos)
# do more at boot than the plain net examples above -- net_init() PLUS
# disk_initialize()/fat_mount() PLUS (kvs) loading or creating the
# persistence file, spawning the SD worker task along the way. Confirmed
# on real hardware: kvs_server_sdcard_rtos with the plain SETTLE_SECS=4
# window reproducibly failed every request with "No route to host" (the
# board hadn't finished bringing up the network stack yet), while the
# same board answered correctly moments later once given more time.
SDCARD_RTOS_SETTLE_SECS=10

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

# http_server_sdcard (rpi3, GitHub issue #145): the concurrent Ethernet +
# USB-mass-storage foundation's first real payoff -- serves the genuine
# content of examples/sdcard_content/ over HTTP from the attached USB
# drive, exactly like http_server_sdcard already does against STM32's
# real SD card. Provisioning (scripts/rpi3_provision_http_server_sdcard.sh,
# the JTAG-breakpoint counterpart of scripts/provision_http_server_sdcard.sh)
# formats the drive first -- confirmed acceptable, same as every other
# destructive USB-storage test in this suite. SDCARD_CONTENT_DIR must be
# passed on sudo's own command line, same reasoning as ETH_TEST_IFACE
# above.
sdcard_name="http_server_sdcard (rpi3)"
sdcard_content_dir="$REPO_ROOT/examples/sdcard_content"
sdcard_provision_log=$(mktemp)
if ! bash "$REPO_ROOT/scripts/rpi3_provision_http_server_sdcard.sh" \
        "$REPO_ROOT/examples/http_server_sdcard_install/kernel_rpi3.elf" \
        "$sdcard_content_dir" > "$sdcard_provision_log" 2>&1; then
    printf "${RED}FAIL${RST}  %s  (USB drive provisioning failed)\n" "$sdcard_name"
    sed 's/^/       /' "$sdcard_provision_log"
    FAIL=$((FAIL + 1))
    FAILED_TESTS+=("$sdcard_name")
elif ! bash "$REPO_ROOT/scripts/rpi3_jtag_load.sh" "$REPO_ROOT/examples/http_server_sdcard/kernel_rpi3.elf" > /dev/null; then
    printf "${RED}FAIL${RST}  %s  (JTAG injection failed)\n" "$sdcard_name"
    FAIL=$((FAIL + 1))
    FAILED_TESTS+=("$sdcard_name")
else
    sleep "$SETTLE_SECS"
    echo "-- $sdcard_name --"
    if sudo ETH_TEST_IFACE="$ETH_TEST_IFACE" ETH_TEST_SUBNET="$ETH_TEST_SUBNET" \
            SDCARD_CONTENT_DIR="$sdcard_content_dir" python3 "$REPO_ROOT/scripts/eth_http_server_sdcard_test.py"; then
        printf "${GRN}PASS${RST}  %s\n" "$sdcard_name"
        PASS=$((PASS + 1))
    else
        printf "${RED}FAIL${RST}  %s\n" "$sdcard_name"
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$sdcard_name")
    fi
fi
rm -f "$sdcard_provision_log"

# http_server_sdcard_rtos (rpi3): same real SD-card-served HTTP content
# as http_server_sdcard above, but SD/FAT operations run behind a Simple
# RTOS worker task (examples/http_server_sdcard_rtos/
# http_server_sdcard_rtos.tkb) -- reuses the SAME drive content the
# http_server_sdcard test above just provisioned, no separate
# provisioning step needed.
sdcard_rtos_name="http_server_sdcard_rtos (rpi3)"
if ! bash "$REPO_ROOT/scripts/rpi3_jtag_load.sh" "$REPO_ROOT/examples/http_server_sdcard_rtos/kernel_rpi3.elf" > /dev/null; then
    printf "${RED}FAIL${RST}  %s  (JTAG injection failed)\n" "$sdcard_rtos_name"
    FAIL=$((FAIL + 1))
    FAILED_TESTS+=("$sdcard_rtos_name")
else
    sleep "$SDCARD_RTOS_SETTLE_SECS"
    echo "-- $sdcard_rtos_name --"
    if sudo ETH_TEST_IFACE="$ETH_TEST_IFACE" ETH_TEST_SUBNET="$ETH_TEST_SUBNET" \
            SDCARD_CONTENT_DIR="$sdcard_content_dir" python3 "$REPO_ROOT/scripts/eth_http_server_sdcard_test.py"; then
        printf "${GRN}PASS${RST}  %s\n" "$sdcard_rtos_name"
        PASS=$((PASS + 1))
    else
        printf "${RED}FAIL${RST}  %s\n" "$sdcard_rtos_name"
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$sdcard_rtos_name")
    fi
fi

# kvs_server_sdcard_rtos (rpi3): real Ethernet + real USB-storage
# persistence through FAT12 + RTOS task separation, mirroring
# scripts/run_hwtest_net_ram.sh's own STM32 two-boot proof -- no
# provisioning step (this firmware creates its own persistence file on
# first boot if none exists, so whatever the http_server_sdcard(_rtos)
# tests above left on the drive gives this test's first boot a genuine
# "no saved table yet" start every run). Boot 1 (KVS_TEST_PHASE=full,
# the script's own default) proves PUT/GET/DELETE/LIST end to end and
# leaves one extra key durably written; a REAL chip reset
# (scripts/rpi3_jtag_reset.sh -- this board has no `reset halt`, see
# AGENTS.md) followed by boot 2 (KVS_TEST_PHASE=verify_persistence)
# proves that key survived, not just RAM lifetime.
#
# An explicit reset ALSO precedes boot 1 here (unlike every other test in
# this script, which just re-injects over whatever the previous example
# left running) -- confirmed on real hardware that running this
# particular example immediately after http_server_sdcard_rtos with no
# reset in between reproducibly left the network stack unreachable
# ("No route to host" on every request) even after this script's own
# generous SDCARD_RTOS_SETTLE_SECS wait, while the identical firmware
# booted from a genuine reset answered correctly every time. Root cause
# not isolated (this board's own DWC2 soft-reset inside net_init() is
# expected to already bring the USB core to a clean state regardless of
# the previous payload) -- kept as a real-hardware-confirmed fix per this
# project's established precedent for this class of finding (see
# examples/common_rpi3/AGENTS.md's DWC2 XACT_ERROR investigation).
kvs_rtos_name="kvs_server_sdcard_rtos (rpi3)"
if ! bash "$REPO_ROOT/scripts/rpi3_jtag_reset.sh" > /dev/null || \
   ! bash "$REPO_ROOT/scripts/rpi3_jtag_load.sh" "$REPO_ROOT/examples/kvs_server_sdcard_rtos/kernel_rpi3.elf" > /dev/null; then
    printf "${RED}FAIL${RST}  %s  (reset/JTAG injection failed, boot 1)\n" "$kvs_rtos_name"
    FAIL=$((FAIL + 1))
    FAILED_TESTS+=("$kvs_rtos_name")
else
    sleep "$SDCARD_RTOS_SETTLE_SECS"
    echo "-- $kvs_rtos_name --"
    if ! sudo ETH_TEST_IFACE="$ETH_TEST_IFACE" ETH_TEST_SUBNET="$ETH_TEST_SUBNET" python3 "$REPO_ROOT/scripts/eth_kvs_server_stm32_test.py"; then
        printf "${RED}FAIL${RST}  %s  (protocol test failed, boot 1)\n" "$kvs_rtos_name"
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$kvs_rtos_name")
    elif ! bash "$REPO_ROOT/scripts/rpi3_jtag_reset.sh" > /dev/null || \
         ! bash "$REPO_ROOT/scripts/rpi3_jtag_load.sh" "$REPO_ROOT/examples/kvs_server_sdcard_rtos/kernel_rpi3.elf" > /dev/null; then
        printf "${RED}FAIL${RST}  %s  (reset/reinjection failed, boot 2)\n" "$kvs_rtos_name"
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$kvs_rtos_name")
    else
        sleep "$SDCARD_RTOS_SETTLE_SECS"
        echo "-- $kvs_rtos_name (persistence-survives-reset check) --"
        if sudo ETH_TEST_IFACE="$ETH_TEST_IFACE" ETH_TEST_SUBNET="$ETH_TEST_SUBNET" \
                KVS_TEST_PHASE=verify_persistence python3 "$REPO_ROOT/scripts/eth_kvs_server_stm32_test.py"; then
            printf "${GRN}PASS${RST}  %s\n" "$kvs_rtos_name"
            PASS=$((PASS + 1))
        else
            printf "${RED}FAIL${RST}  %s\n" "$kvs_rtos_name"
            FAIL=$((FAIL + 1))
            FAILED_TESTS+=("$kvs_rtos_name")
        fi
    fi
fi

echo ""
echo "rpi3 network hardware tests: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
    echo "failed tests:"
    for t in "${FAILED_TESTS[@]}"; do
        echo "  - $t"
    done
    exit 1
fi
