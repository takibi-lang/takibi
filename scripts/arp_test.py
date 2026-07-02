#!/usr/bin/env python3
# Sends an ARP "who-has" request for arp_reply's configured static IP
# (192.0.2.1 -- RFC 5737 TEST-NET-1) over the same UDP-backed -netdev dgram
# transport as virtio_net_test.py (one UDP datagram == one raw Ethernet
# frame), and verifies the ARP reply: OPER=2 (reply), SHA/SPA are the
# responder's MAC/IP, THA/TPA echo back the requester's, and the Ethernet
# source MAC matches SHA.
#
# Also sends a "who-has" for a *different* IP and confirms arp_reply stays
# silent -- it must only answer for its own configured address.
#
# Exit code only (0 = pass, 1 = fail); run_qemutest.sh prints the
# PASS/FAIL banner, matching virtio_net_test.py's convention.

import socket
import sys

QEMU_HOST = "127.0.0.1"
QEMU_PORT = 17771   # must match -netdev dgram,...,local.port=... in run_qemutest.sh
LOCAL_PORT = 17772  # must match -netdev dgram,...,remote.port=... in run_qemutest.sh

REQUESTER_MAC = bytes([0x02, 0x00, 0x00, 0x00, 0x00, 0x01])
REQUESTER_IP = bytes([192, 0, 2, 55])
TARGET_IP = bytes([192, 0, 2, 1])       # must match arp_reply.tkb's our_ip
OTHER_IP = bytes([192, 0, 2, 200])      # some IP arp_reply does NOT own
BROADCAST_MAC = bytes([0xff] * 6)
ARP_ETHERTYPE = bytes([0x08, 0x06])

RETRIES = 20
RETRY_TIMEOUT_SECS = 0.5
SILENCE_TIMEOUT_SECS = 1.0


def build_arp_request(target_ip: bytes) -> bytes:
    eth = BROADCAST_MAC + REQUESTER_MAC + ARP_ETHERTYPE
    arp = (
        bytes([0x00, 0x01])    # HTYPE = Ethernet
        + bytes([0x08, 0x00])  # PTYPE = IPv4
        + bytes([6, 4])        # HLEN, PLEN
        + bytes([0x00, 0x01])  # OPER = request
        + REQUESTER_MAC        # SHA
        + REQUESTER_IP         # SPA
        + bytes([0x00] * 6)    # THA (unknown, all zero)
        + target_ip            # TPA
    )
    return eth + arp


def check_reply(reply: bytes) -> bool:
    if len(reply) < 42:
        return False
    dst_mac, src_mac, ethertype = reply[0:6], reply[6:12], reply[12:14]
    arp = reply[14:42]
    htype, ptype = arp[0:2], arp[2:4]
    hlen, plen = arp[4], arp[5]
    oper = arp[6:8]
    sha, spa, tha, tpa = arp[8:14], arp[14:18], arp[18:24], arp[24:28]
    return (
        dst_mac == REQUESTER_MAC and
        ethertype == ARP_ETHERTYPE and
        htype == bytes([0x00, 0x01]) and
        ptype == bytes([0x08, 0x00]) and
        hlen == 6 and plen == 4 and
        oper == bytes([0x00, 0x02]) and
        spa == TARGET_IP and
        tha == REQUESTER_MAC and
        tpa == REQUESTER_IP and
        src_mac == sha
    )


def test_who_has_us() -> bool:
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind((QEMU_HOST, LOCAL_PORT))
    sock.settimeout(RETRY_TIMEOUT_SECS)
    frame = build_arp_request(TARGET_IP)

    for _attempt in range(RETRIES):
        sock.sendto(frame, (QEMU_HOST, QEMU_PORT))
        try:
            reply, _addr = sock.recvfrom(2000)
        except socket.timeout:
            continue
        if check_reply(reply):
            sock.close()
            return True
    sock.close()
    return False


def test_who_has_other_stays_silent() -> bool:
    # arp_reply must not answer for an IP it doesn't own. There is no
    # "definitely never arrives" proof possible, so this just waits a bit
    # longer than a real reply would take and checks nothing showed up.
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind((QEMU_HOST, LOCAL_PORT))
    sock.settimeout(SILENCE_TIMEOUT_SECS)
    frame = build_arp_request(OTHER_IP)
    sock.sendto(frame, (QEMU_HOST, QEMU_PORT))
    try:
        reply, _addr = sock.recvfrom(2000)
        sock.close()
        print("  unexpected reply for a non-owned IP:", reply.hex())
        return False
    except socket.timeout:
        sock.close()
        return True


def main() -> int:
    ok1 = test_who_has_us()
    print("  who-has 192.0.2.1 (ours):     %s" % ("PASS" if ok1 else "FAIL"))

    ok2 = test_who_has_other_stays_silent()
    print("  who-has 192.0.2.200 (silent): %s" % ("PASS" if ok2 else "FAIL"))

    return 0 if (ok1 and ok2) else 1


if __name__ == "__main__":
    sys.exit(main())
