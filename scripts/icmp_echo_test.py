#!/usr/bin/env python3
# Sends ICMP echo requests (pings) to icmp_echo's virtio-net-device over
# the same UDP-backed -netdev dgram transport as virtio_net_test.py /
# arp_test.py, and verifies each echo reply: MACs and IPs swapped, type=0,
# both IP and ICMP checksums verify (checksumming a valid packet with its
# checksum field intact must sum to zero -- see
# examples/common/inet_checksum.tkb), and identifier/sequence/payload come
# back unchanged.
#
# Also sends a ping to a different IP and confirms icmp_echo stays silent
# (it must only answer for its own configured address), and a request with
# a deliberately corrupted ICMP checksum, confirming it's dropped rather
# than answered.
#
# Exit code only (0 = pass, 1 = fail); run_qemutest.sh prints the
# PASS/FAIL banner, matching the other virtio test scripts' convention.

import socket
import struct
import sys

QEMU_HOST = "127.0.0.1"
QEMU_PORT = 17771   # must match -netdev dgram,...,local.port=... in run_qemutest.sh
LOCAL_PORT = 17772  # must match -netdev dgram,...,remote.port=... in run_qemutest.sh

REQUESTER_MAC = bytes([0x02, 0x00, 0x00, 0x00, 0x00, 0x01])
REQUESTER_IP = bytes([192, 0, 2, 55])
TARGET_MAC = bytes([0x52, 0x54, 0x00, 0x12, 0x34, 0x56])  # must match run_qemutest.sh's mac=
TARGET_IP = bytes([192, 0, 2, 1])       # must match icmp_echo.tkb's our_ip
OTHER_IP = bytes([192, 0, 2, 200])      # some IP icmp_echo does NOT own

RETRIES = 20
RETRY_TIMEOUT_SECS = 0.5
SILENCE_TIMEOUT_SECS = 1.0


def inet_checksum(data: bytes) -> int:
    if len(data) % 2:
        data += b"\x00"
    s = 0
    for i in range(0, len(data), 2):
        s += (data[i] << 8) | data[i + 1]
    while s >> 16:
        s = (s & 0xffff) + (s >> 16)
    return (~s) & 0xffff


def build_echo_request(dst_ip: bytes, payload: bytes, ident: int, seq: int,
                        corrupt_icmp_checksum: bool = False) -> bytes:
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

    eth = TARGET_MAC + REQUESTER_MAC + bytes([0x08, 0x00])
    return eth + ip_hdr + icmp


def check_reply(reply: bytes, payload: bytes, ident: int, seq: int) -> bool:
    if len(reply) < 34 + 8:
        return False
    eth_dst, eth_src, ethertype = reply[0:6], reply[6:12], reply[12:14]
    ip = reply[14:34]
    icmp = reply[34:]
    return (
        eth_dst == REQUESTER_MAC and eth_src == TARGET_MAC and
        ethertype == bytes([0x08, 0x00]) and
        ip[12:16] == TARGET_IP and ip[16:20] == REQUESTER_IP and
        inet_checksum(ip) == 0 and
        icmp[0] == 0 and icmp[1] == 0 and
        inet_checksum(icmp) == 0 and
        icmp[4:6] == struct.pack("!H", ident) and
        icmp[6:8] == struct.pack("!H", seq) and
        icmp[8:] == payload
    )


def test_ping_us() -> bool:
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind((QEMU_HOST, LOCAL_PORT))
    sock.settimeout(RETRY_TIMEOUT_SECS)

    payload = b"hello-icmp-echo-0123456789"
    ident, seq = 0x1234, 1
    frame = build_echo_request(TARGET_IP, payload, ident, seq)

    for _attempt in range(RETRIES):
        sock.sendto(frame, (QEMU_HOST, QEMU_PORT))
        try:
            reply, _addr = sock.recvfrom(2000)
        except socket.timeout:
            continue
        if check_reply(reply, payload, ident, seq):
            sock.close()
            return True
    sock.close()
    return False


def test_ping_other_stays_silent() -> bool:
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind((QEMU_HOST, LOCAL_PORT))
    sock.settimeout(SILENCE_TIMEOUT_SECS)
    frame = build_echo_request(OTHER_IP, b"nobody-home", 0x5678, 2)
    sock.sendto(frame, (QEMU_HOST, QEMU_PORT))
    try:
        reply, _addr = sock.recvfrom(2000)
        sock.close()
        print("  unexpected reply for a non-owned IP:", reply.hex())
        return False
    except socket.timeout:
        sock.close()
        return True


def test_corrupted_checksum_dropped() -> bool:
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind((QEMU_HOST, LOCAL_PORT))
    sock.settimeout(SILENCE_TIMEOUT_SECS)
    frame = build_echo_request(TARGET_IP, b"bad-checksum", 0x9abc, 3,
                                corrupt_icmp_checksum=True)
    sock.sendto(frame, (QEMU_HOST, QEMU_PORT))
    try:
        reply, _addr = sock.recvfrom(2000)
        sock.close()
        print("  unexpected reply to a corrupted-checksum request:", reply.hex())
        return False
    except socket.timeout:
        sock.close()
        return True


def main() -> int:
    ok1 = test_ping_us()
    print("  ping 192.0.2.1 (ours):             %s" % ("PASS" if ok1 else "FAIL"))

    ok2 = test_ping_other_stays_silent()
    print("  ping 192.0.2.200 (silent):         %s" % ("PASS" if ok2 else "FAIL"))

    ok3 = test_corrupted_checksum_dropped()
    print("  ping with bad ICMP checksum (silent): %s" % ("PASS" if ok3 else "FAIL"))

    return 0 if (ok1 and ok2 and ok3) else 1


if __name__ == "__main__":
    sys.exit(main())
