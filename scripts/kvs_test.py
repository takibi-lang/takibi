#!/usr/bin/env python3
# Tests examples/kvs_server/kvs_server.tkb (GitHub issue #135) over the same
# UDP-backed -netdev dgram transport as the other virtio-net test scripts
# (one UDP datagram == one raw Ethernet frame). See http_server_test.py's
# header for why plain, option-free TCP segments are enough here (the
# server accepts them; only a real client's SLIRP-injected MSS option would
# need constructing, and this test never runs against SLIRP).
#
# Each KVS operation is its own TCP connection (the shared core handles one
# connection at a time and actively closes after every response), so this
# script opens a fresh SYN/SYN-ACK/ACK handshake per request -- the same
# pattern http_server_test.py already proved across its two sequential
# requests, just generalized into a reusable helper and run many times in
# sequence. qemutest boots a fresh QEMU process per test, so the table
# starts empty every run: every assertion below is on an exact status line
# and exact body (LIST is checked as a set, since slot order depends on the
# hash function, not on insertion order).
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
SERVER_IP = bytes([10, 0, 2, 15])                          # must match kvs_server.tkb's our_ip
SERVER_PORT = 80                                            # must match http_server_common.tkb's HTTP_PORT

RETRIES = 20
RETRY_TIMEOUT_SECS = 0.5

FLAG_FIN = 0x01
FLAG_SYN = 0x02
FLAG_ACK = 0x10

_next_port = [51000]
_next_isn = [10000]


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


def http_request(request: bytes):
    """Runs one full TCP connection: SYN -> SYN-ACK -> ACK -> request ->
    response(+FIN) -> our FIN+ACK -> final ACK. Returns (status_code, body)
    on success, or None on any wire-level failure."""
    client_port = _next_port[0]
    client_isn = _next_isn[0]
    _next_port[0] += 1
    _next_isn[0] += 10000

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind((QEMU_HOST, LOCAL_PORT))
    try:
        syn = build_frame(client_port, client_isn, 0, FLAG_SYN)
        reply = send_and_wait(sock, syn)
        if reply is None:
            print("  no SYN-ACK reply")
            return None

        tcp = reply[34:]
        src_port, dst_port, server_isn, ack, _doff_res, flags = struct.unpack("!HHIIBB", tcp[0:14])
        if not (src_port == SERVER_PORT and dst_port == client_port and
                flags == (FLAG_SYN | FLAG_ACK) and ack == client_isn + 1):
            print("  bad SYN-ACK: src_port=%d dst_port=%d ack=%d flags=0x%02x" %
                  (src_port, dst_port, ack, flags))
            return None

        ack_frame = build_frame(client_port, client_isn + 1, server_isn + 1, FLAG_ACK)
        sock.sendto(ack_frame, (QEMU_HOST, QEMU_PORT))

        req_frame = build_frame(client_port, client_isn + 1, server_isn + 1, FLAG_ACK, data=request)
        reply2 = send_and_wait(sock, req_frame)
        if reply2 is None:
            print("  no HTTP response")
            return None

        eth_dst, eth_src, ethertype = reply2[0:6], reply2[6:12], reply2[12:14]
        ip2 = reply2[14:34]
        tcp2 = reply2[34:]
        src_port2, dst_port2, rseq, rack, doff_res2, flags2 = struct.unpack("!HHIIBB", tcp2[0:14])
        tcp_hdr_len = (doff_res2 >> 4) * 4
        body_raw = tcp2[tcp_hdr_len:]

        pseudo = ip2[12:16] + ip2[16:20] + bytes([0, 6]) + struct.pack("!H", len(tcp2))
        header_ok = (
            eth_dst == CLIENT_MAC and eth_src == SERVER_MAC and
            ethertype == bytes([0x08, 0x00]) and
            src_port2 == SERVER_PORT and dst_port2 == client_port and
            (flags2 & (FLAG_ACK | FLAG_FIN)) == (FLAG_ACK | FLAG_FIN) and
            rack == client_isn + 1 + len(request) and
            checksum_fold(checksum_add(ip2)) == 0 and
            checksum_fold(checksum_add(pseudo + tcp2)) == 0
        )
        if not header_ok:
            print("  bad HTTP response wire header: flags=0x%02x" % flags2)
            return None

        if not body_raw.startswith(b"HTTP/1.1 "):
            print("  malformed status line:", body_raw[:40])
            return None
        status_code = int(body_raw[9:12])
        if b"\r\n\r\n" not in body_raw:
            print("  no header/body terminator:", body_raw[:200])
            return None
        head, resp_body = body_raw.split(b"\r\n\r\n", 1)
        content_length = None
        for line in head.split(b"\r\n")[1:]:
            if line.startswith(b"Content-Length: "):
                content_length = int(line[len(b"Content-Length: "):])
        if content_length is None or content_length != len(resp_body):
            print("  Content-Length mismatch: header=%s actual=%d" %
                  (content_length, len(resp_body)))
            return None

        response_payload_len = len(tcp2) - tcp_hdr_len
        client_fin_seq = client_isn + 1 + len(request)
        client_fin_ack = rseq + response_payload_len + 1
        peer_fin = build_frame(client_port, client_fin_seq, client_fin_ack,
                               FLAG_FIN | FLAG_ACK)
        reply3 = send_and_wait(sock, peer_fin)
        if reply3 is None:
            print("  no final ACK for client FIN")
            return None

        tcp3 = reply3[34:]
        src_port3, dst_port3, rseq3, rack3, _doff_res3, flags3 = struct.unpack("!HHIIBB", tcp3[0:14])
        ip3 = reply3[14:34]
        pseudo3 = ip3[12:16] + ip3[16:20] + bytes([0, 6]) + struct.pack("!H", len(tcp3))
        close_ok = (
            src_port3 == SERVER_PORT and dst_port3 == client_port and
            flags3 == FLAG_ACK and
            rseq3 == client_fin_ack and
            rack3 == client_fin_seq + 1 and
            checksum_fold(checksum_add(ip3)) == 0 and
            checksum_fold(checksum_add(pseudo3 + tcp3)) == 0
        )
        if not close_ok:
            print("  bad final ACK: flags=0x%02x seq=%d ack=%d" %
                  (flags3, rseq3, rack3))
            return None

        return (status_code, resp_body)
    finally:
        sock.close()


def build_put(path: str, body: bytes, content_length: int = None) -> bytes:
    cl = len(body) if content_length is None else content_length
    head = ("PUT %s HTTP/1.1\r\nHost: 10.0.2.15\r\nContent-Length: %d\r\n"
            "Connection: close\r\n\r\n" % (path, cl)).encode()
    return head + body


def build_put_no_cl(path: str, body: bytes) -> bytes:
    head = ("PUT %s HTTP/1.1\r\nHost: 10.0.2.15\r\nConnection: close\r\n\r\n" % path).encode()
    return head + body


def build_get(path: str) -> bytes:
    return ("GET %s HTTP/1.1\r\nHost: 10.0.2.15\r\nConnection: close\r\n\r\n" % path).encode()


def build_delete(path: str) -> bytes:
    return ("DELETE %s HTTP/1.1\r\nHost: 10.0.2.15\r\nConnection: close\r\n\r\n" % path).encode()


def expect(desc: str, result, want_status: int, want_body: bytes = None) -> bool:
    if result is None:
        print("  [%s] FAIL: no response" % desc)
        return False
    status, body = result
    ok = (status == want_status) and (want_body is None or body == want_body)
    if not ok:
        print("  [%s] FAIL: got status=%d body=%r, want status=%d body=%r" %
              (desc, status, body, want_status, want_body))
    return ok


def test_missing_key() -> bool:
    return expect("GET missing key", http_request(build_get("/keys/nokey")),
                  404, b"not found\n")


def test_set_get_overwrite_del() -> bool:
    ok = True
    ok &= expect("PUT alpha=one (new)", http_request(build_put("/keys/alpha", b"one")),
                 201, b"")
    ok &= expect("GET alpha", http_request(build_get("/keys/alpha")),
                 200, b"one")
    ok &= expect("PUT alpha=two (overwrite)", http_request(build_put("/keys/alpha", b"two")),
                 200, b"")
    ok &= expect("GET alpha after overwrite", http_request(build_get("/keys/alpha")),
                 200, b"two")
    ok &= expect("PUT alpha=three (overwrite again)", http_request(build_put("/keys/alpha", b"three")),
                 200, b"")
    ok &= expect("GET alpha after 2nd overwrite", http_request(build_get("/keys/alpha")),
                 200, b"three")
    ok &= expect("DELETE alpha", http_request(build_delete("/keys/alpha")),
                 200, b"")
    ok &= expect("GET alpha after delete", http_request(build_get("/keys/alpha")),
                 404, b"not found\n")
    ok &= expect("DELETE alpha again (missing)", http_request(build_delete("/keys/alpha")),
                 404, b"not found\n")
    return ok


def test_list_empty() -> bool:
    return expect("LIST (empty table)", http_request(build_get("/keys")),
                  200, b"")


def test_table_full_and_list() -> bool:
    ok = True
    for i in range(16):
        key = "k%02d" % i
        ok &= expect("PUT %s (fill)" % key, http_request(build_put("/keys/" + key, b"v")),
                     201, b"")
    if not ok:
        return False

    r17 = http_request(build_put("/keys/k16", b"v"))
    ok &= expect("PUT k16 (table full)", r17, 507, b"table full\n")

    r_list = http_request(build_get("/keys"))
    if r_list is None:
        print("  [LIST full] FAIL: no response")
        return False
    status, body = r_list
    lines = [l for l in body.split(b"\n") if l]
    expected = set(("k%02d" % i).encode() for i in range(16))
    if status != 200 or len(lines) != 16 or set(lines) != expected:
        print("  [LIST full] FAIL: status=%d lines=%r" % (status, lines))
        ok = False

    ok &= expect("PUT k07 (overwrite while full)", http_request(build_put("/keys/k07", b"v2")),
                 200, b"")
    ok &= expect("GET k07 after overwrite-while-full", http_request(build_get("/keys/k07")),
                 200, b"v2")
    return ok


def test_tombstone_reuse() -> bool:
    ok = True
    ok &= expect("DELETE k03 (tombstone)", http_request(build_delete("/keys/k03")),
                 200, b"")
    ok &= expect("PUT fresh (reuses tombstone)", http_request(build_put("/keys/fresh", b"v")),
                 201, b"")
    ok &= expect("GET fresh", http_request(build_get("/keys/fresh")),
                 200, b"v")

    r_list = http_request(build_get("/keys"))
    if r_list is None:
        print("  [LIST after tombstone reuse] FAIL: no response")
        return False
    status, body = r_list
    lines = set(l for l in body.split(b"\n") if l)
    if status != 200 or b"fresh" not in lines or b"k03" in lines:
        print("  [LIST after tombstone reuse] FAIL: status=%d lines=%r" % (status, lines))
        ok = False
    return ok


def test_parser_errors() -> bool:
    ok = True
    ok &= expect("PUT key too long (33 chars)",
                 http_request(build_put("/keys/" + "a" * 33, b"v")),
                 400, b"bad request\n")
    ok &= expect("PUT key with bad char (*)",
                 http_request(build_put("/keys/ba*d", b"v")),
                 400, b"bad request\n")
    ok &= expect("PUT value too large (129 bytes)",
                 http_request(build_put("/keys/big", b"x" * 129)),
                 400, b"bad request\n")
    ok &= expect("PUT Content-Length mismatch",
                 http_request(build_put("/keys/mismatch", b"abc", content_length=100)),
                 400, b"bad request\n")
    ok &= expect("GET unknown path", http_request(build_get("/nope")),
                 404, b"not found\n")
    ok &= expect("PUT /keys (no key)", http_request(build_put_no_cl("/keys", b"")),
                 405, b"method not allowed\n")
    ok &= expect("DELETE /keys (no key)", http_request(build_delete("/keys")),
                 405, b"method not allowed\n")
    return ok


def test_put_without_content_length() -> bool:
    # Run before the table-full test fills every slot: PUT without a
    # Content-Length header is still accepted (the value is just "the rest
    # of this segment") -- see kvs_content_length's header comment. Cleans
    # up its own key afterward so it doesn't consume a slot the table-full
    # test needs.
    ok = True
    ok &= expect("PUT no Content-Length (accepted, rest-of-segment body)",
                 http_request(build_put_no_cl("/keys/nocl", b"raw")),
                 201, b"")
    ok &= expect("GET nocl", http_request(build_get("/keys/nocl")),
                 200, b"raw")
    ok &= expect("DELETE nocl (cleanup)", http_request(build_delete("/keys/nocl")),
                 200, b"")
    return ok


TESTS = [
    ("missing key",                 test_missing_key),
    ("set/get/overwrite/delete",    test_set_get_overwrite_del),
    ("list (empty)",                test_list_empty),
    ("put without content-length",  test_put_without_content_length),
    ("parser/error cases",          test_parser_errors),
    ("table full + list",           test_table_full_and_list),
    ("tombstone reuse",             test_tombstone_reuse),
]


def main() -> int:
    all_ok = True
    for name, fn in TESTS:
        ok = fn()
        print("  %-32s %s" % (name, "PASS" if ok else "FAIL"))
        all_ok = all_ok and ok
    return 0 if all_ok else 1


if __name__ == "__main__":
    sys.exit(main())
