#!/usr/bin/env python3
# Tests examples/http_server/http_server.tkb over the same UDP-backed
# -netdev dgram transport as the other virtio-net test scripts (one UDP
# datagram == one raw Ethernet frame). Deliberately sends plain,
# option-free TCP segments -- unlike a real client (see
# http_server.tkb's file header: QEMU's -netdev user/SLIRP always
# includes a TCP MSS option on its SYN, which is what caught the
# "doff must be exactly 5" bug tcp_echo.tkb still has). The server accepts
# both, so this script doesn't need to bother constructing options.
#
# The request counter is fully deterministic here: qemutest boots a fresh
# QEMU process per test, so it always starts at 0, and this script always
# sends exactly two real, sequential requests (never blind retries of a
# request that might have already been processed -- see send_and_wait,
# which resends the *same* frame bytes on timeout; the server's
# seq-number-based duplicate detection, already relied on by
# tcp_echo_test.py, means even a resent duplicate can't double-count).
# So the counter is asserted to read exactly 1, then exactly 2 -- no
# flakiness from retries or reordering.
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
SERVER_IP = bytes([10, 0, 2, 15])                          # must match http_server.tkb's our_ip
SERVER_PORT = 80                                            # must match http_server.tkb's HTTP_PORT

RETRIES = 20
RETRY_TIMEOUT_SECS = 0.5
SILENCE_TIMEOUT_SECS = 1.0

FLAG_FIN = 0x01
FLAG_SYN = 0x02
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


def build_frame(client_port: int, seq: int, ack: int, flags: int, data: bytes = b"") -> bytes:
    tcp_no_csum = struct.pack("!HHIIBBHHH", client_port, SERVER_PORT, seq, ack,
                               (5 << 4), flags, 65535, 0, 0) + data
    pseudo = CLIENT_IP + SERVER_IP + bytes([0, 6]) + struct.pack("!H", len(tcp_no_csum))
    csum = checksum_fold(checksum_add(pseudo + tcp_no_csum))
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


def do_request(sock: socket.socket, client_port: int, client_isn: int,
                expected_count: int) -> bool:
    """SYN -> SYN-ACK -> ACK -> GET -> verify HTTP response (with the
    expected request counter value) + FIN -> ACK -> verify silence."""
    syn = build_frame(client_port, client_isn, 0, FLAG_SYN)
    reply = send_and_wait(sock, syn)
    if reply is None:
        print("  no SYN-ACK reply")
        return False

    ip = reply[14:34]
    tcp = reply[34:]
    src_port, dst_port, server_isn, ack, _doff_res, flags = struct.unpack("!HHIIBB", tcp[0:14])
    if not (src_port == SERVER_PORT and dst_port == client_port and
            flags == (FLAG_SYN | FLAG_ACK) and ack == client_isn + 1):
        print("  bad SYN-ACK: src_port=%d dst_port=%d ack=%d flags=0x%02x" %
              (src_port, dst_port, ack, flags))
        return False

    ack_frame = build_frame(client_port, client_isn + 1, server_isn + 1, FLAG_ACK)
    sock.sendto(ack_frame, (QEMU_HOST, QEMU_PORT))

    request = b"GET / HTTP/1.1\r\nHost: 10.0.2.15\r\nConnection: close\r\n\r\n"
    get_frame = build_frame(client_port, client_isn + 1, server_isn + 1, FLAG_ACK, data=request)
    reply2 = send_and_wait(sock, get_frame)
    if reply2 is None:
        print("  no HTTP response")
        return False

    eth_dst, eth_src, ethertype = reply2[0:6], reply2[6:12], reply2[12:14]
    ip2 = reply2[14:34]
    tcp2 = reply2[34:]
    src_port2, dst_port2, rseq, rack, doff_res2, flags2 = struct.unpack("!HHIIBB", tcp2[0:14])
    tcp_hdr_len = (doff_res2 >> 4) * 4
    body = tcp2[tcp_hdr_len:]

    pseudo = ip2[12:16] + ip2[16:20] + bytes([0, 6]) + struct.pack("!H", len(tcp2))
    expected_marker = ("Request <span class='count'>#%d</span>" % expected_count).encode()
    header_ok = (
        eth_dst == CLIENT_MAC and eth_src == SERVER_MAC and
        ethertype == bytes([0x08, 0x00]) and
        src_port2 == SERVER_PORT and dst_port2 == client_port and
        (flags2 & (FLAG_ACK | FLAG_FIN)) == (FLAG_ACK | FLAG_FIN) and
        rack == client_isn + 1 + len(request) and
        checksum_fold(checksum_add(ip2)) == 0 and
        checksum_fold(checksum_add(pseudo + tcp2)) == 0
    )
    body_ok = (
        body.startswith(b"HTTP/1.1 200 OK\r\n") and
        b"Content-Length: " in body and
        b"Hello from Takibi!" in body and
        expected_marker in body
    )
    content_length_ok = False
    if b"\r\n\r\n" in body:
        head, html = body.split(b"\r\n\r\n", 1)
        for line in head.split(b"\r\n"):
            if line.startswith(b"Content-Length: "):
                content_length_ok = (int(line[len(b"Content-Length: "):]) == len(html))

    if not (header_ok and body_ok and content_length_ok):
        print("  bad HTTP response: flags=0x%02x header_ok=%s body_ok=%s content_length_ok=%s" %
              (flags2, header_ok, body_ok, content_length_ok))
        print("  body:", body[:200])
        return False

    # Server actively closed (FIN piggybacked on the response) -- ACK it
    # and confirm silence, matching tcp_echo's active-close convention.
    # The ack value must cover the *entire* response payload (headers +
    # body), not just the FIN -- getting this wrong leaves the server
    # stuck in TCP_LAST_ACK forever (it never sees ack == conn_snd_nxt),
    # which silently breaks every later connection for the rest of the
    # boot, not just this one.
    response_payload_len = len(tcp2) - tcp_hdr_len
    final_ack = build_frame(client_port, client_isn + 1 + len(request),
                             rseq + response_payload_len + 1, FLAG_ACK)
    return expect_silence(sock, final_ack)


def test_single_request() -> bool:
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind((QEMU_HOST, LOCAL_PORT))
    ok = do_request(sock, client_port=50001, client_isn=1000, expected_count=1)
    sock.close()
    return ok


def test_counter_increments_on_second_request() -> bool:
    # A second, fully independent connection (server returned to LISTEN
    # after closing the first) -- proves the counter is real per-boot
    # state, not a hardcoded "1" in the template.
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind((QEMU_HOST, LOCAL_PORT))
    ok = do_request(sock, client_port=50002, client_isn=2000, expected_count=2)
    sock.close()
    return ok


def main() -> int:
    ok1 = test_single_request()
    print("  first request (#1):                %s" % ("PASS" if ok1 else "FAIL"))

    ok2 = ok1 and test_counter_increments_on_second_request()
    print("  second request (#2, counter bump): %s" % ("PASS" if ok2 else "FAIL"))

    return 0 if (ok1 and ok2) else 1


if __name__ == "__main__":
    sys.exit(main())
