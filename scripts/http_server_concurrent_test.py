#!/usr/bin/env python3
# Tests examples/http_server/http_server.tkb's N-way concurrent TCP
# connection support (GitHub issue #135's multi-connection follow-up).
# Unlike http_server_test.py, which never has more than one connection
# open at a time, this script deliberately keeps multiple TCP connections
# open simultaneously (different client_port values multiplexed over the
# same one-frame-per-UDP-datagram transport http_server_test.py already
# uses -- see that file's header) to exercise http_conn_state.tkb's
# MAX_CONNS=4 slot table: independent admission, independent per-slot
# sequence-number state, table-full silent-ignore, and slot reuse after
# close.
#
# Frame-building/checksum helpers are copied from http_server_test.py
# (kept as plain top-level functions there too, no shared module to
# import from -- see that file's own header for the wire-format notes).
#
# Exit code only (0 = pass, 1 = fail); run_qemutest.sh prints the
# PASS/FAIL banner, matching the other virtio test scripts' convention.

import re
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
SERVER_IP = bytes([10, 0, 2, 15])                          # must match http_server.tkb's our_ip
SERVER_PORT = 80                                            # must match http_server.tkb's HTTP_PORT

MAX_CONNS = 4  # must match http_conn_state.tkb's MAX_CONNS

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
    """Tracks one TCP connection's client-side sequence state across a
    handshake that may be interleaved with other Conns on the wire."""

    def __init__(self, client_port: int, client_isn: int):
        self.client_port = client_port
        self.client_isn = client_isn
        self.server_isn = None
        self.snd = client_isn  # next byte we will send, pre-SYN
        self.rcv = None        # next byte we expect from the server


def syn_frame(c: Conn) -> bytes:
    return build_frame(c.client_port, c.client_isn, 0, FLAG_SYN)


def complete_handshake_from_synack(c: Conn, reply: bytes, sock: socket.socket) -> bool:
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


def build_get_frame(c: Conn, path: str = "/") -> bytes:
    """Builds (and advances c.snd past) a GET request frame. Does NOT send
    it -- callers choose send-and-wait vs. fire-and-collect-later so tests
    can control interleaving explicitly."""
    request = ("GET %s HTTP/1.1\r\nHost: 10.0.2.15\r\nConnection: close\r\n\r\n" % path).encode()
    frame = build_frame(c.client_port, c.snd, c.rcv, FLAG_ACK, data=request)
    c.snd += len(request)
    return frame


def close_conn(c: Conn, response_reply: bytes, sock: socket.socket) -> bool:
    """Given the server's response (which piggybacks FIN|ACK, same as
    http_server_test.py's do_request), finishes the active-close sequence
    and confirms the server ACKs our FIN. Returns slot to Listen."""
    src_port, dst_port, rseq, rack, flags, payload = parse_tcp(response_reply)
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


def test_simultaneous_syns_get_independent_synacks() -> bool:
    """3 SYNs sent back-to-back, before any handshake completes. Each must
    get its own SYN-ACK, correctly addressed, with a distinct server ISN
    (proves the ISN-collision fix -- see netutil.tkb's tcp_initial_seq)."""
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind((QEMU_HOST, LOCAL_PORT))
    try:
        conns = [Conn(60001 + i, 1000 + i * 100) for i in range(3)]

        # Send all still-unanswered SYNs together each round (so whichever
        # ones are outstanding stay genuinely simultaneous on the wire),
        # retrying only to absorb transport-level loss/QEMU boot timing --
        # not because the protocol itself is expected to drop anything.
        pending = {c.client_port: c for c in conns}
        replies_by_port = {}
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
                    replies_by_port[dst_port] = reply
                    del pending[dst_port]
        if pending:
            print("  missing SYN-ACK(s) for ports: %r" % sorted(pending.keys()))
            return False

        ok = True
        for c in conns:
            reply = replies_by_port.get(c.client_port)
            if reply is None:
                print("  no SYN-ACK addressed to port %d" % c.client_port)
                ok = False
                continue
            ok &= complete_handshake_from_synack(c, reply, sock)

        isns = [c.server_isn for c in conns if c.server_isn is not None]
        if len(set(isns)) != len(isns):
            print("  server ISNs are not all distinct: %r" % isns)
            ok = False

        # Clean up: close all 3 so later tests start from an empty table.
        for c in conns:
            get_reply = send_and_wait(sock, build_get_frame(c))
            if get_reply is None:
                print("  no response while cleaning up port %d" % c.client_port)
                ok = False
                continue
            ok &= close_conn(c, get_reply, sock)
        return ok
    finally:
        sock.close()


def test_interleaved_handshakes_and_gets_stay_independent() -> bool:
    """3 fresh connections: complete all 3 handshakes, then send all 3 GETs
    before reading any response, then verify each response is correctly
    addressed and well-formed, and that the shared request counter shows
    no duplication or loss (the 3 observed values are 3 distinct,
    consecutive integers -- not hardcoded to {1,2,3}, since an earlier
    test in this same run may already have bumped the counter)."""
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind((QEMU_HOST, LOCAL_PORT))
    try:
        conns = [Conn(60101 + i, 2000 + i * 100) for i in range(3)]
        ok = True
        for c in conns:
            reply = send_and_wait(sock, syn_frame(c))
            if reply is None:
                print("  no SYN-ACK for port %d" % c.client_port)
                return False
            ok &= complete_handshake_from_synack(c, reply, sock)
        if not ok:
            return False

        request_len = len(b"GET / HTTP/1.1\r\nHost: 10.0.2.15\r\nConnection: close\r\n\r\n")
        for c in conns:
            sock.sendto(build_get_frame(c), (QEMU_HOST, QEMU_PORT))

        responses_by_port = {}
        for _ in range(3):
            reply = recv_one(sock, 2.0)
            if reply is None:
                print("  missing a response (got %d of 3)" % len(responses_by_port))
                return False
            _src, dst_port, _seq, _ack, _flags, _payload = parse_tcp(reply)
            responses_by_port[dst_port] = reply

        counters = []
        for c in conns:
            reply = responses_by_port.get(c.client_port)
            if reply is None:
                print("  no response addressed to port %d" % c.client_port)
                ok = False
                continue
            src_port, dst_port, rseq, rack, flags, payload = parse_tcp(reply)
            addr_ok = (src_port == SERVER_PORT and dst_port == c.client_port and
                       rack == c.client_isn + 1 + request_len)
            body_ok = payload.startswith(b"HTTP/1.1 200 OK\r\n") and b"Hello from Takibi!" in payload
            if not (addr_ok and body_ok):
                print("  bad response for port %d: addr_ok=%s body_ok=%s" %
                      (c.client_port, addr_ok, body_ok))
                ok = False
                continue
            m = re.search(rb"Request <span class='count'>#(\d+)</span>", payload)
            if not m:
                print("  no counter marker in response for port %d" % c.client_port)
                ok = False
                continue
            counters.append(int(m.group(1)))
            ok &= close_conn(c, reply, sock)

        sorted_counters = sorted(counters)
        consecutive = (len(sorted_counters) == 3 and
                       sorted_counters == list(range(sorted_counters[0], sorted_counters[0] + 3)))
        if not consecutive:
            print("  counters not 3 distinct consecutive values: %r (duplication or loss)" % counters)
            ok = False
        return ok
    finally:
        sock.close()


def test_table_full_fifth_syn_silently_ignored() -> bool:
    """Fill all MAX_CONNS=4 slots with un-closed connections, then confirm
    a 5th SYN gets no reply at all (the existing "unknown peer, ignore"
    path -- see http_conn_state.tkb's tcp_conn_dispatch Pass 3)."""
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind((QEMU_HOST, LOCAL_PORT))
    try:
        conns = [Conn(60201 + i, 3000 + i * 100) for i in range(MAX_CONNS)]
        ok = True
        for c in conns:
            reply = send_and_wait(sock, syn_frame(c))
            if reply is None:
                print("  no SYN-ACK for port %d while filling table" % c.client_port)
                return False
            ok &= complete_handshake_from_synack(c, reply, sock)
        if not ok:
            return False

        fifth = Conn(60299, 3900)
        sock.sendto(syn_frame(fifth), (QEMU_HOST, QEMU_PORT))
        sock.settimeout(SILENCE_TIMEOUT_SECS)
        try:
            stray = sock.recvfrom(2000)[0]
            print("  unexpected reply to 5th SYN:", stray.hex())
            ok = False
        except socket.timeout:
            pass

        # Clean up: close all 4 open connections so later tests can reuse
        # their slots.
        for c in conns:
            get_reply = send_and_wait(sock, build_get_frame(c))
            if get_reply is None:
                print("  no response while cleaning up port %d" % c.client_port)
                ok = False
                continue
            ok &= close_conn(c, get_reply, sock)
        return ok
    finally:
        sock.close()


def test_slots_reusable_after_close() -> bool:
    """After the previous test closed all 4 connections, a brand-new
    connection must be admitted again (proves closed slots actually
    return to Listen instead of staying stuck)."""
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind((QEMU_HOST, LOCAL_PORT))
    try:
        c = Conn(60301, 4000)
        reply = send_and_wait(sock, syn_frame(c))
        if reply is None:
            print("  no SYN-ACK after prior connections closed (slot not reused)")
            return False
        if not complete_handshake_from_synack(c, reply, sock):
            return False
        get_reply = send_and_wait(sock, build_get_frame(c))
        if get_reply is None:
            print("  no response on reused slot")
            return False
        return close_conn(c, get_reply, sock)
    finally:
        sock.close()


def main() -> int:
    ok1 = test_simultaneous_syns_get_independent_synacks()
    print("  3 simultaneous SYNs -> independent SYN-ACKs: %s" % ("PASS" if ok1 else "FAIL"))

    ok2 = test_interleaved_handshakes_and_gets_stay_independent()
    print("  interleaved handshakes + GETs stay independent: %s" % ("PASS" if ok2 else "FAIL"))

    ok3 = test_table_full_fifth_syn_silently_ignored()
    print("  table full: 5th SYN silently ignored:          %s" % ("PASS" if ok3 else "FAIL"))

    ok4 = test_slots_reusable_after_close()
    print("  slots reusable after close:                    %s" % ("PASS" if ok4 else "FAIL"))

    return 0 if (ok1 and ok2 and ok3 and ok4) else 1


if __name__ == "__main__":
    sys.exit(main())
