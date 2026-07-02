#!/usr/bin/env python3
# Tests examples/tcp_echo/tcp_echo.tkb over the same UDP-backed -netdev
# dgram transport as the other virtio-net test scripts. One test function
# per development stage, all run against the same kernel -- see
# CLAUDE.md's TCP section for why tcp_echo is grown incrementally in one
# binary rather than split into separate examples like inet_checksum/
# ip_parse/icmp_echo were. Each function stays in this file permanently,
# so a future regression in (say) handshake sequencing still fails
# test_handshake_only specifically even once later stages have their own
# passing tests.
#
# IMPORTANT ORDERING NOTE: tcp_echo.tkb supports exactly one connection.
# Once test_handshake_only() succeeds, the server is ESTABLISHED with that
# test's (fake) client and no longer in LISTEN, so any SYN sent
# afterwards -- valid or not -- is ignored simply because the connection
# slot is taken, not because of whatever the later test meant to check.
# The negative ("stays silent") tests must therefore run BEFORE
# test_handshake_only() so they're actually exercising LISTEN-state
# validation, not just "the server happens to be busy."
#
# Exit code only (0 = pass, 1 = fail); run_qemutest.sh prints the
# PASS/FAIL banner, matching the other virtio test scripts' convention.

import socket
import struct
import sys

QEMU_HOST = "127.0.0.1"
QEMU_PORT = 17771   # must match -netdev dgram,...,local.port=... in run_qemutest.sh
LOCAL_PORT = 17772  # must match -netdev dgram,...,remote.port=... in run_qemutest.sh

CLIENT_MAC = bytes([0x02, 0x00, 0x00, 0x00, 0x00, 0x01])
CLIENT_IP = bytes([192, 0, 2, 55])
SERVER_MAC = bytes([0x52, 0x54, 0x00, 0x12, 0x34, 0x56])  # must match run_qemutest.sh's mac=
SERVER_IP = bytes([192, 0, 2, 1])                          # must match tcp_echo.tkb's our_ip
SERVER_PORT = 7                                            # must match tcp_echo.tkb's TCP_ECHO_PORT

RETRIES = 20
RETRY_TIMEOUT_SECS = 0.5
SILENCE_TIMEOUT_SECS = 1.0

FLAG_FIN = 0x01
FLAG_SYN = 0x02
FLAG_RST = 0x04
FLAG_ACK = 0x10


def checksum_add(data: bytes, sum_in: int = 0) -> int:
    if len(data) % 2:
        data += b"\x00"
    s = sum_in
    for i in range(0, len(data), 2):
        s += (data[i] << 8) | data[i + 1]
    return s


def checksum_fold(s: int) -> int:
    while s >> 16:
        s = (s & 0xffff) + (s >> 16)
    return (~s) & 0xffff


def build_frame(client_port: int, seq: int, ack: int, flags: int,
                 data: bytes = b"", corrupt_tcp_checksum: bool = False) -> bytes:
    tcp_no_csum = struct.pack("!HHIIBBHHH", client_port, SERVER_PORT, seq, ack,
                               (5 << 4), flags, 65535, 0, 0) + data
    pseudo = CLIENT_IP + SERVER_IP + bytes([0, 6]) + struct.pack("!H", len(tcp_no_csum))
    csum = checksum_fold(checksum_add(pseudo + tcp_no_csum))
    if corrupt_tcp_checksum:
        csum ^= 0xffff
    tcp = struct.pack("!HHIIBBHHH", client_port, SERVER_PORT, seq, ack,
                       (5 << 4), flags, 65535, csum, 0) + data

    total_len = 20 + len(tcp)
    ip_no_csum = struct.pack("!BBHHHBBH4s4s", 0x45, 0, total_len, 0, 0, 64, 6, 0,
                              CLIENT_IP, SERVER_IP)
    ip_csum = checksum_fold(checksum_add(ip_no_csum))
    ip = struct.pack("!BBHHHBBH4s4s", 0x45, 0, total_len, 0, 0, 64, 6, ip_csum,
                      CLIENT_IP, SERVER_IP)

    eth = SERVER_MAC + CLIENT_MAC + bytes([0x08, 0x00])
    return eth + ip + tcp


def send_and_wait(sock: socket.socket, frame: bytes):
    for _attempt in range(RETRIES):
        sock.sendto(frame, (QEMU_HOST, QEMU_PORT))
        sock.settimeout(RETRY_TIMEOUT_SECS)
        try:
            return sock.recvfrom(2000)[0]
        except socket.timeout:
            continue
    return None


def expect_silence(sock: socket.socket, frame: bytes) -> bool:
    sock.sendto(frame, (QEMU_HOST, QEMU_PORT))
    sock.settimeout(SILENCE_TIMEOUT_SECS)
    try:
        reply = sock.recvfrom(2000)[0]
        print("  unexpected reply:", reply.hex())
        return False
    except socket.timeout:
        return True


def test_syn_wrong_port_silent() -> bool:
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind((QEMU_HOST, LOCAL_PORT))
    global SERVER_PORT
    saved = SERVER_PORT
    SERVER_PORT = 9999  # not tcp_echo's listening port
    frame = build_frame(client_port=40001, seq=100, ack=0, flags=FLAG_SYN)
    SERVER_PORT = saved
    ok = expect_silence(sock, frame)
    sock.close()
    return ok


def test_syn_bad_checksum_silent() -> bool:
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind((QEMU_HOST, LOCAL_PORT))
    frame = build_frame(client_port=40002, seq=200, ack=0, flags=FLAG_SYN,
                         corrupt_tcp_checksum=True)
    ok = expect_silence(sock, frame)
    sock.close()
    return ok


def test_handshake_only() -> bool:
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind((QEMU_HOST, LOCAL_PORT))

    client_port = 43210
    client_isn = 500

    syn = build_frame(client_port, client_isn, 0, FLAG_SYN)
    reply = send_and_wait(sock, syn)
    if reply is None:
        print("  no SYN-ACK reply")
        sock.close()
        return False

    eth_dst, eth_src, ethertype = reply[0:6], reply[6:12], reply[12:14]
    ip = reply[14:34]
    tcp = reply[34:]
    src_port, dst_port, seq, ack, _doff_res, flags = struct.unpack("!HHIIBB", tcp[0:14])

    pseudo = ip[12:16] + ip[16:20] + bytes([0, 6]) + struct.pack("!H", len(tcp))
    syn_ack_ok = (
        eth_dst == CLIENT_MAC and eth_src == SERVER_MAC and
        ethertype == bytes([0x08, 0x00]) and
        src_port == SERVER_PORT and dst_port == client_port and
        flags == (FLAG_SYN | FLAG_ACK) and
        ack == client_isn + 1 and
        checksum_fold(checksum_add(ip)) == 0 and
        checksum_fold(checksum_add(pseudo + tcp)) == 0
    )
    if not syn_ack_ok:
        print("  bad SYN-ACK: src_port=%d dst_port=%d seq=%d ack=%d flags=0x%02x" %
              (src_port, dst_port, seq, ack, flags))
        sock.close()
        return False

    server_isn = seq
    ack_frame = build_frame(client_port, client_isn + 1, server_isn + 1, FLAG_ACK)
    silent_ok = expect_silence(sock, ack_frame)
    sock.close()
    if not silent_ok:
        print("  server replied to the final ACK (should stay silent)")
    return silent_ok


def main() -> int:
    ok1 = test_syn_wrong_port_silent()
    print("  SYN to wrong port (silent):        %s" % ("PASS" if ok1 else "FAIL"))

    ok2 = test_syn_bad_checksum_silent()
    print("  SYN with bad TCP checksum (silent): %s" % ("PASS" if ok2 else "FAIL"))

    ok3 = test_handshake_only()
    print("  three-way handshake:               %s" % ("PASS" if ok3 else "FAIL"))

    return 0 if (ok1 and ok2 and ok3) else 1


if __name__ == "__main__":
    sys.exit(main())
