#!/usr/bin/env python3
# Sends an ARP "who-has" request for arp_reply_stm32's configured static IP
# (192.0.2.1 -- RFC 5737 TEST-NET-1, examples/common_stm32/netconfig.tkb)
# over a raw AF_PACKET socket on a physical point-to-point link to the real
# STM32F746G-DISCOVERY board, and verifies the ARP reply: OPER=2 (reply),
# SHA/SPA are the responder's MAC/IP, THA/TPA echo back the requester's, and
# the Ethernet source MAC matches SHA. Same checks as scripts/arp_test.py
# (the QEMU/virtio-net counterpart) -- see that file for the non-hardware
# version.
#
# ARP frames are only 42 bytes (14-byte Ethernet header + 28-byte ARP
# payload), below Ethernet's 60-byte minimum -- the sending NIC pads our
# request to 60 bytes before it hits the wire, and ARP's EtherType (0x0806)
# is >= 0x600, so it's Ethernet-II framed and the STM32 MAC's automatic
# pad/CRC stripping cannot strip that padding on receive (same reasoning as
# scripts/eth_net_echo_test.py's module comment). The reply therefore comes
# back with trailing bytes beyond the real 42-byte ARP reply -- check_reply()
# below only looks at the first 42 bytes, tolerating that padding, exactly
# like eth_net_echo_test.py's prefix comparison.
#
# Needs CAP_NET_RAW (run via sudo, or `make hwcheck-net` which already does)
# and ETH_TEST_IFACE pointed at the wired interface (default enp4s0).
#
# Exit code only (0 = pass, 1 = fail).

import os
import socket
import sys
import time

IFACE = os.environ.get("ETH_TEST_IFACE", "enp4s0")
ARP_ETHERTYPE = bytes([0x08, 0x06])

REQUESTER_MAC = bytes([0x02, 0x00, 0x00, 0x00, 0x00, 0x01])
REQUESTER_IP = bytes([192, 0, 2, 55])
TARGET_IP = bytes([192, 0, 2, 1])       # must match netconfig.tkb's OUR_IP
OTHER_IP = bytes([192, 0, 2, 200])      # some IP arp_reply_stm32 does NOT own
BROADCAST_MAC = bytes([0xff] * 6)

RETRIES = 20
RETRY_TIMEOUT_SECS = 0.5
SILENCE_TIMEOUT_SECS = 1.0


def read_iface_mac(iface: str) -> bytes:
    with open(f"/sys/class/net/{iface}/address") as f:
        return bytes(int(b, 16) for b in f.read().strip().split(":"))


def build_arp_request(requester_mac: bytes, target_ip: bytes) -> bytes:
    eth = BROADCAST_MAC + requester_mac + ARP_ETHERTYPE
    arp = (
        bytes([0x00, 0x01])    # HTYPE = Ethernet
        + bytes([0x08, 0x00])  # PTYPE = IPv4
        + bytes([6, 4])        # HLEN, PLEN
        + bytes([0x00, 0x01])  # OPER = request
        + requester_mac        # SHA
        + REQUESTER_IP         # SPA
        + bytes([0x00] * 6)    # THA (unknown, all zero)
        + target_ip             # TPA
    )
    return eth + arp


def check_reply(reply: bytes, requester_mac: bytes) -> bool:
    if len(reply) < 42:
        return False
    reply = reply[:42]
    dst_mac, src_mac, ethertype = reply[0:6], reply[6:12], reply[12:14]
    arp = reply[14:42]
    htype, ptype = arp[0:2], arp[2:4]
    hlen, plen = arp[4], arp[5]
    oper = arp[6:8]
    sha, spa, tha, tpa = arp[8:14], arp[14:18], arp[18:24], arp[24:28]
    return (
        dst_mac == requester_mac and
        ethertype == ARP_ETHERTYPE and
        htype == bytes([0x00, 0x01]) and
        ptype == bytes([0x08, 0x00]) and
        hlen == 6 and plen == 4 and
        oper == bytes([0x00, 0x02]) and
        spa == TARGET_IP and
        tha == requester_mac and
        tpa == REQUESTER_IP and
        src_mac == sha
    )


def test_who_has_us(sock: socket.socket, requester_mac: bytes) -> bool:
    frame = build_arp_request(requester_mac, TARGET_IP)
    for _attempt in range(RETRIES):
        sock.send(frame)
        deadline = time.monotonic() + RETRY_TIMEOUT_SECS
        while time.monotonic() < deadline:
            try:
                reply = sock.recv(2000)
            except socket.timeout:
                break
            if reply[: len(frame)] == frame:
                continue  # AF_PACKET loops our own outgoing frame back -- skip it
            if check_reply(reply, requester_mac):
                return True
    return False


def test_who_has_other_stays_silent(sock: socket.socket, requester_mac: bytes) -> bool:
    # arp_reply_stm32 must not answer for an IP it doesn't own. There is no
    # "definitely never arrives" proof possible, so this just waits a bit
    # longer than a real reply would take and checks nothing showed up.
    frame = build_arp_request(requester_mac, OTHER_IP)
    sock.send(frame)
    deadline = time.monotonic() + SILENCE_TIMEOUT_SECS
    while time.monotonic() < deadline:
        try:
            reply = sock.recv(2000)
        except socket.timeout:
            continue
        if reply[: len(frame)] == frame:
            continue  # our own outgoing frame looped back -- not a reply
        print("  unexpected reply for a non-owned IP:", reply.hex())
        return False
    return True


def main() -> int:
    if not os.path.exists(f"/sys/class/net/{IFACE}"):
        print(f"error: interface {IFACE!r} not found -- set ETH_TEST_IFACE?", file=sys.stderr)
        return 1
    requester_mac = read_iface_mac(IFACE)

    sock = socket.socket(socket.AF_PACKET, socket.SOCK_RAW, socket.htons(0x0806))
    sock.bind((IFACE, 0))
    sock.settimeout(RETRY_TIMEOUT_SECS)

    ok1 = test_who_has_us(sock, requester_mac)
    print("  who-has 192.0.2.1 (ours):     %s" % ("PASS" if ok1 else "FAIL"))

    ok2 = test_who_has_other_stays_silent(sock, requester_mac)
    print("  who-has 192.0.2.200 (silent): %s" % ("PASS" if ok2 else "FAIL"))

    return 0 if (ok1 and ok2) else 1


if __name__ == "__main__":
    sys.exit(main())
