#!/usr/bin/env python3
# Tests examples/kvs_server/kvs_server.tkb under N-way concurrent TCP
# connections (GitHub issue #135's multi-connection follow-up). kvs_server
# shares the exact same core (http_conn_state.tkb/http_server_common.tkb)
# that scripts/http_server_concurrent_test.py already exercises at the TCP
# layer (simultaneous SYN admission, table-full silent-ignore, slot
# reuse) -- this script does not repeat that coverage. It instead checks
# the thing specific to a stateful KV store: that PUTs/GETs issued on
# several simultaneously-open connections land in (and read back from)
# the right table row, with no cross-connection corruption of either the
# shared kv_keys/kv_vals table or any connection's own response framing
# (conn_snd_nxt[idx]/conn_rcv_nxt[idx] -- see http_server_common.tkb).
#
# Frame-building/checksum/Conn helpers are copied from
# http_server_concurrent_test.py (see that file's header for why there is
# no shared module to import from instead).
#
# Exit code only (0 = pass, 1 = fail); run_qemutest.sh prints the
# PASS/FAIL banner, matching the other virtio test scripts' convention.

import socket
import struct
import sys
import time

QEMU_HOST = "127.0.0.1"
QEMU_PORT = 17771   # must match -netdev dgram,...,local.port=... in run_qemutest.sh
LOCAL_PORT = 17772  # must match -netdev dgram,...,remote.port=... in run_qemutest.sh

CLIENT_MAC = bytes([0x02, 0x00, 0x00, 0x00, 0x00, 0x01])
CLIENT_IP = bytes([192, 0, 2, 55])
SERVER_MAC = bytes([0x52, 0x54, 0x00, 0x12, 0x34, 0x56])  # must match run_qemutest.sh's mac=
SERVER_IP = bytes([10, 0, 2, 15])                          # must match kvs_server.tkb's our_ip
SERVER_PORT = 80                                            # must match http_server_common.tkb's HTTP_PORT

MAX_CONNS = 16  # must match http_conn_state.tkb's MAX_CONNS

RETRIES = 20
RETRY_TIMEOUT_SECS = 0.5

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


def parse_tcp(frame: bytes):
    """Returns (src_port, dst_port, seq, ack, flags, payload)."""
    tcp = frame[34:]
    src_port, dst_port, seq, ack, doff_res, flags = struct.unpack("!HHIIBB", tcp[0:14])
    hdr_len = (doff_res >> 4) * 4
    return src_port, dst_port, seq, ack, flags, tcp[hdr_len:]


def recv_one(sock: socket.socket, timeout: float):
    sock.settimeout(timeout)
    try:
        return sock.recvfrom(2000)[0]
    except socket.timeout:
        return None


def send_and_wait(sock: socket.socket, frame: bytes):
    for _attempt in range(RETRIES):
        sock.sendto(frame, (QEMU_HOST, QEMU_PORT))
        reply = recv_one(sock, RETRY_TIMEOUT_SECS)
        if reply is not None:
            return reply
    return None


class Conn:
    def __init__(self, client_port: int, client_isn: int):
        self.client_port = client_port
        self.client_isn = client_isn
        self.server_isn = None
        self.snd = client_isn
        self.rcv = None


def syn_frame(c: Conn) -> bytes:
    return build_frame(c.client_port, c.client_isn, 0, FLAG_SYN)


def open_conn(c: Conn, sock: socket.socket) -> bool:
    """Sends whichever SYNs are still unanswered together each retry round,
    so genuinely simultaneous opens stay simultaneous on the wire while
    still being robust to transport-level loss/QEMU boot timing."""
    reply = send_and_wait(sock, syn_frame(c))
    if reply is None:
        print("  no SYN-ACK for port %d" % c.client_port)
        return False
    src_port, dst_port, server_isn, ack, flags, _payload = parse_tcp(reply)
    if not (src_port == SERVER_PORT and dst_port == c.client_port and
            flags == (FLAG_SYN | FLAG_ACK) and ack == c.client_isn + 1):
        print("  bad SYN-ACK for port %d: dst_port=%d ack=%d flags=0x%02x" %
              (c.client_port, dst_port, ack, flags))
        return False
    c.server_isn = server_isn
    c.snd = c.client_isn + 1
    c.rcv = server_isn + 1
    ack_frame = build_frame(c.client_port, c.snd, c.rcv, FLAG_ACK)
    sock.sendto(ack_frame, (QEMU_HOST, QEMU_PORT))
    return True


def open_conns_simultaneously(conns, sock: socket.socket) -> bool:
    pending = {c.client_port: c for c in conns}
    replies = {}
    for _attempt in range(RETRIES):
        if not pending:
            break
        for c in pending.values():
            sock.sendto(syn_frame(c), (QEMU_HOST, QEMU_PORT))
        deadline = time.monotonic() + RETRY_TIMEOUT_SECS
        while pending:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                break
            reply = recv_one(sock, remaining)
            if reply is None:
                break
            _src, dst_port, _seq, _ack, _flags, _payload = parse_tcp(reply)
            if dst_port in pending:
                replies[dst_port] = reply
                del pending[dst_port]
    if pending:
        print("  missing SYN-ACK(s) for ports: %r" % sorted(pending.keys()))
        return False

    ok = True
    for c in conns:
        src_port, dst_port, server_isn, ack, flags, _payload = parse_tcp(replies[c.client_port])
        if not (src_port == SERVER_PORT and flags == (FLAG_SYN | FLAG_ACK) and
                ack == c.client_isn + 1):
            print("  bad SYN-ACK for port %d: ack=%d flags=0x%02x" %
                  (c.client_port, ack, flags))
            ok = False
            continue
        c.server_isn = server_isn
        c.snd = c.client_isn + 1
        c.rcv = server_isn + 1
        sock.sendto(build_frame(c.client_port, c.snd, c.rcv, FLAG_ACK), (QEMU_HOST, QEMU_PORT))
    return ok


def build_request_frame(c: Conn, request: bytes) -> bytes:
    frame = build_frame(c.client_port, c.snd, c.rcv, FLAG_ACK, data=request)
    c.snd += len(request)
    return frame


def close_conn(c: Conn, response_reply: bytes, sock: socket.socket) -> bool:
    src_port, dst_port, rseq, rack, flags, _payload = parse_tcp(response_reply)
    if (flags & (FLAG_ACK | FLAG_FIN)) != (FLAG_ACK | FLAG_FIN):
        print("  response for port %d missing FIN|ACK: flags=0x%02x" % (c.client_port, flags))
        return False
    response_payload_len = len(response_reply) - 34 - ((response_reply[46] >> 4) * 4)
    client_fin_seq = c.snd
    client_fin_ack = rseq + response_payload_len + 1
    peer_fin = build_frame(c.client_port, client_fin_seq, client_fin_ack, FLAG_FIN | FLAG_ACK)
    reply = send_and_wait(sock, peer_fin)
    if reply is None:
        print("  no final ACK for port %d's FIN" % c.client_port)
        return False
    src_port3, dst_port3, rseq3, rack3, flags3, _payload3 = parse_tcp(reply)
    ok = (src_port3 == SERVER_PORT and dst_port3 == c.client_port and
          flags3 == FLAG_ACK and rseq3 == client_fin_ack and rack3 == client_fin_seq + 1)
    if not ok:
        print("  bad final ACK for port %d: flags=0x%02x seq=%d ack=%d" %
              (c.client_port, flags3, rseq3, rack3))
    return ok


def build_put(path: str, body: bytes) -> bytes:
    head = ("PUT %s HTTP/1.1\r\nHost: 10.0.2.15\r\nContent-Length: %d\r\n"
            "Connection: close\r\n\r\n" % (path, len(body))).encode()
    return head + body


def build_get(path: str) -> bytes:
    return ("GET %s HTTP/1.1\r\nHost: 10.0.2.15\r\nConnection: close\r\n\r\n" % path).encode()


def parse_response(reply: bytes):
    """Returns (status_code, body) or None on malformed input."""
    _src, _dst, _seq, _ack, _flags, body_raw = parse_tcp(reply)
    if not body_raw.startswith(b"HTTP/1.1 "):
        return None
    status_code = int(body_raw[9:12])
    if b"\r\n\r\n" not in body_raw:
        return None
    _head, body = body_raw.split(b"\r\n\r\n", 1)
    return status_code, body


def run_one_request_per_conn(conns, requests_by_port, sock: socket.socket):
    """Sends one request per connection, all interleaved (every request
    sent before any response is read), then returns {client_port: reply}.
    Returns None (with a printed reason) on any missing reply."""
    frames_by_port = {}
    for c in conns:
        frame = build_request_frame(c, requests_by_port[c.client_port])
        frames_by_port[c.client_port] = frame
        sock.sendto(frame, (QEMU_HOST, QEMU_PORT))

    replies_by_port = {}
    deadline = time.monotonic() + 3.0
    while len(replies_by_port) < len(conns) and time.monotonic() < deadline:
        reply = recv_one(sock, max(0.0, deadline - time.monotonic()))
        if reply is None:
            break
        _src, dst_port, _seq, _ack, _flags, _payload = parse_tcp(reply)
        if dst_port in frames_by_port:
            replies_by_port[dst_port] = reply

    missing = [p for p in frames_by_port if p not in replies_by_port]
    if missing:
        print("  missing response(s) for port(s): %r" % missing)
        return None
    return replies_by_port


def test_concurrent_put_no_crosstalk() -> bool:
    """3 simultaneously-open connections each PUT a distinct key/value in
    the same interleaved round; each response must be addressed to (and
    only readable from) its own connection, with the right status."""
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind((QEMU_HOST, LOCAL_PORT))
    try:
        conns = [Conn(61001 + i, 5000 + i * 100) for i in range(3)]
        if not open_conns_simultaneously(conns, sock):
            return False

        values = {c.client_port: ("val-%d" % i).encode() for i, c in enumerate(conns)}
        keys = {c.client_port: "ckey%d" % i for i, c in enumerate(conns)}
        requests = {c.client_port: build_put("/keys/" + keys[c.client_port], values[c.client_port])
                    for c in conns}

        replies = run_one_request_per_conn(conns, requests, sock)
        if replies is None:
            return False

        ok = True
        for c in conns:
            parsed = parse_response(replies[c.client_port])
            if parsed is None or parsed[0] != 201:
                print("  bad PUT response for port %d: %r" % (c.client_port, parsed))
                ok = False
                continue
            ok &= close_conn(c, replies[c.client_port], sock)
        return ok
    finally:
        sock.close()


def test_concurrent_get_reads_back_correct_values() -> bool:
    """3 NEW simultaneous connections GET the keys the previous test wrote,
    each read on a DIFFERENT connection than the one that wrote it (so a
    slot-index bug that mixed up connections' response framing, or a
    table bug that mixed up which row a concurrent write landed in, would
    show up as a wrong value on the wrong port)."""
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind((QEMU_HOST, LOCAL_PORT))
    try:
        conns = [Conn(61101 + i, 6000 + i * 100) for i in range(3)]
        if not open_conns_simultaneously(conns, sock):
            return False

        # Deliberately rotated: conn i reads the key conn (i+1)%3 wrote.
        keys_in_write_order = ["ckey0", "ckey1", "ckey2"]
        values_in_write_order = [b"val-0", b"val-1", b"val-2"]
        requests = {}
        expected = {}
        for i, c in enumerate(conns):
            read_idx = (i + 1) % 3
            requests[c.client_port] = build_get("/keys/" + keys_in_write_order[read_idx])
            expected[c.client_port] = values_in_write_order[read_idx]

        replies = run_one_request_per_conn(conns, requests, sock)
        if replies is None:
            return False

        ok = True
        for c in conns:
            parsed = parse_response(replies[c.client_port])
            if parsed is None:
                print("  malformed GET response for port %d" % c.client_port)
                ok = False
                continue
            status, body = parsed
            if status != 200 or body != expected[c.client_port]:
                print("  wrong value for port %d: status=%d body=%r want=%r" %
                      (c.client_port, status, body, expected[c.client_port]))
                ok = False
                continue
            ok &= close_conn(c, replies[c.client_port], sock)
        return ok
    finally:
        sock.close()


def main() -> int:
    ok1 = test_concurrent_put_no_crosstalk()
    print("  concurrent PUTs on 3 conns, no crosstalk:       %s" % ("PASS" if ok1 else "FAIL"))

    ok2 = ok1 and test_concurrent_get_reads_back_correct_values()
    print("  concurrent GETs read back correct values:       %s" % ("PASS" if ok2 else "FAIL"))

    return 0 if (ok1 and ok2) else 1


if __name__ == "__main__":
    sys.exit(main())
