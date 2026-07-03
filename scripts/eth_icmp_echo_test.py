#!/usr/bin/env python3
# Sends ICMP echo requests (pings) to icmp_echo_stm32 over a raw AF_PACKET
# socket on a physical point-to-point link to the real STM32F746G-DISCOVERY
# board, and verifies each echo reply: MACs and IPs swapped, type=0, both IP
# and ICMP checksums verify, and identifier/sequence/payload come back
# unchanged. Same checks as scripts/icmp_echo_test.py (the QEMU/virtio-net
# counterpart) -- see that file for the non-hardware version.
#
# Also sends a ping to a different IP and confirms icmp_echo_stm32 stays
# silent, and a request with a deliberately corrupted ICMP checksum,
# confirming it's dropped rather than answered.
#
# Needs CAP_NET_RAW (run via sudo, or `make hwcheck-net` which already does)
# and ETH_TEST_IFACE pointed at the wired interface (default enp4s0).
#
# Exit code only (0 = pass, 1 = fail).

import os
import socket
import struct
import sys
import time

IFACE = os.environ.get("ETH_TEST_IFACE", "enp4s0")

REQUESTER_IP = bytes([192, 168, 10, 55])
TARGET_MAC = bytes([0x00, 0x80, 0xE1, 0x00, 0x00, 0x00])  # must match netconfig.tkb's OUR_MAC
TARGET_IP = bytes([192, 168, 10, 2])                       # must match netconfig.tkb's OUR_IP
OTHER_IP = bytes([192, 168, 10, 200])                      # some IP icmp_echo_stm32 does NOT own

RETRIES = 20
RETRY_TIMEOUT_SECS = 0.5
SILENCE_TIMEOUT_SECS = 1.0


def read_iface_mac(iface: str) -> bytes:
    with open(f"/sys/class/net/{iface}/address") as f:
        return bytes(int(b, 16) for b in f.read().strip().split(":"))


def inet_checksum(data: bytes) -> int:
    if len(data) % 2:
        data += b"\x00"
    s = 0
    for i in range(0, len(data), 2):
        s += (data[i] << 8) | data[i + 1]
    while s >> 16:
        s = (s & 0xffff) + (s >> 16)
    return (~s) & 0xffff


def build_echo_request(requester_mac: bytes, dst_ip: bytes, payload: bytes, ident: int,
                        seq: int, corrupt_icmp_checksum: bool = False) -> bytes:
    icmp = struct.pack("!BBHHH", 8, 0, 0, ident, seq) + payload
    csum = inet_checksum(icmp)
    if corrupt_icmp_checksum:
        csum ^= 0xffff
    icmp = struct.pack("!BBHHH", 8, 0, csum, ident, seq) + payload

    total_len = 20 + len(icmp)
    ip_hdr = struct.pack("!BBHHHBBH4s4s", 0x45, 0, total_len, 0, 0, 64, 1, 0,
                          REQUESTER_IP, dst_ip)
    ip_csum = inet_checksum(ip_hdr)
    ip_hdr = struct.pack("!BBHHHBBH4s4s", 0x45, 0, total_len, 0, 0, 64, 1, ip_csum,
                          REQUESTER_IP, dst_ip)

    eth = TARGET_MAC + requester_mac + bytes([0x08, 0x00])
    return eth + ip_hdr + icmp


def check_reply(reply: bytes, requester_mac: bytes, payload: bytes, ident: int, seq: int) -> bool:
    if len(reply) < 34 + 8 + len(payload):
        return False
    eth_dst, eth_src, ethertype = reply[0:6], reply[6:12], reply[12:14]
    ip = reply[14:34]
    icmp = reply[34:34 + 8 + len(payload)]
    return (
        eth_dst == requester_mac and eth_src == TARGET_MAC and
        ethertype == bytes([0x08, 0x00]) and
        ip[12:16] == TARGET_IP and ip[16:20] == REQUESTER_IP and
        inet_checksum(ip) == 0 and
        icmp[0] == 0 and icmp[1] == 0 and
        inet_checksum(icmp) == 0 and
        icmp[4:6] == struct.pack("!H", ident) and
        icmp[6:8] == struct.pack("!H", seq) and
        icmp[8:] == payload
    )


def test_ping_us(sock: socket.socket, requester_mac: bytes) -> bool:
    payload = b"hello-icmp-echo-0123456789"
    ident, seq = 0x1234, 1
    frame = build_echo_request(requester_mac, TARGET_IP, payload, ident, seq)

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
            if check_reply(reply, requester_mac, payload, ident, seq):
                return True
    return False


def test_ping_other_stays_silent(sock: socket.socket, requester_mac: bytes) -> bool:
    frame = build_echo_request(requester_mac, OTHER_IP, b"nobody-home", 0x5678, 2)
    sock.send(frame)
    deadline = time.monotonic() + SILENCE_TIMEOUT_SECS
    while time.monotonic() < deadline:
        try:
            reply = sock.recv(2000)
        except socket.timeout:
            continue
        if reply[: len(frame)] == frame:
            continue
        print("  unexpected reply for a non-owned IP:", reply.hex())
        return False
    return True


def test_corrupted_checksum_dropped(sock: socket.socket, requester_mac: bytes) -> bool:
    frame = build_echo_request(requester_mac, TARGET_IP, b"bad-checksum", 0x9abc, 3,
                                corrupt_icmp_checksum=True)
    sock.send(frame)
    deadline = time.monotonic() + SILENCE_TIMEOUT_SECS
    while time.monotonic() < deadline:
        try:
            reply = sock.recv(2000)
        except socket.timeout:
            continue
        if reply[: len(frame)] == frame:
            continue
        print("  unexpected reply to a corrupted-checksum request:", reply.hex())
        return False
    return True


def main() -> int:
    if not os.path.exists(f"/sys/class/net/{IFACE}"):
        print(f"error: interface {IFACE!r} not found -- set ETH_TEST_IFACE?", file=sys.stderr)
        return 1
    requester_mac = read_iface_mac(IFACE)

    sock = socket.socket(socket.AF_PACKET, socket.SOCK_RAW, socket.htons(0x0800))
    sock.bind((IFACE, 0))
    sock.settimeout(RETRY_TIMEOUT_SECS)

    ok1 = test_ping_us(sock, requester_mac)
    print("  ping 192.168.10.2 (ours):             %s" % ("PASS" if ok1 else "FAIL"))

    ok2 = test_ping_other_stays_silent(sock, requester_mac)
    print("  ping 192.168.10.200 (silent):         %s" % ("PASS" if ok2 else "FAIL"))

    ok3 = test_corrupted_checksum_dropped(sock, requester_mac)
    print("  ping with bad ICMP checksum (silent): %s" % ("PASS" if ok3 else "FAIL"))

    return 0 if (ok1 and ok2 and ok3) else 1


if __name__ == "__main__":
    sys.exit(main())
