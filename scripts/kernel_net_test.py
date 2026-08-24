#!/usr/bin/env python3
# Host-side peer for kernel/'s QEMU virtio-net milestone (GitHub issue
# #237 M4). Unlike examples/'s own arp_test.py/icmp_echo_test.py/
# tcp_echo_test.py (each a fresh QEMU boot per protocol, since those are
# separate standalone examples), kernel/platform/qemu/init.tkb's fn main()
# runs ARP then ICMP then TCP sequentially in ONE boot --
# kernel_arp_reply_once() replies to exactly one valid request and
# returns, then kernel_icmp_reply_once() starts waiting, then
# kernel_tcp_echo_check() -- so this script drives all three in that
# order against the same running QEMU instance, over the same UDP-backed
# -netdev dgram transport (one UDP datagram == one raw Ethernet frame)
# those scripts already use.
#
# The TCP half is adapted from scripts/tcp_echo_test.py (the proven
# QEMU/virtio-net counterpart for examples/tcp_echo) -- same frame
# builder, same checksum helpers, same handshake/echo/close/reconnect
# ordering, retargeted at kernel/net/netconfig.tkb's own MAC/IP.
# kernel/net/tcp.tkb's kernel_tcp_echo_check() returns Verified only once
# it has counted >= 2 completed handshakes, >= 1 echo, and >= 1 close, so
# the reconnect at the end is load-bearing, not decorative. The
# "SYN with TCP options" case that script also covers is deliberately not
# ported: it leaves a half-open connection that its own version clears
# with an RST, and kernel_tcp_echo_check() drives a single connection
# slot, so a stuck half-open would block the real handshake below.
#
# Exit code only (0 = pass, 1 = fail).

import socket
import struct
import sys
import time
from pathlib import Path

QEMU_HOST = "127.0.0.1"
MODE_FLAGS = {"--fast"}
RAW_ARGS = sys.argv[1:]
FAST_MODE = "--fast" in RAW_ARGS
INTERACTIVE_READY_FILE = None
if "--interactive-ready-file" in RAW_ARGS:
    ready_index = RAW_ARGS.index("--interactive-ready-file")
    if ready_index + 1 >= len(RAW_ARGS):
        raise SystemExit("--interactive-ready-file requires a path")
    INTERACTIVE_READY_FILE = Path(RAW_ARGS[ready_index + 1])
POSITIONAL_ARGS = [
    arg for index, arg in enumerate(RAW_ARGS)
    if arg not in MODE_FLAGS and arg != "--interactive-ready-file" and
    not (index > 0 and RAW_ARGS[index - 1] == "--interactive-ready-file")
]
QEMU_PORT = int(POSITIONAL_ARGS[0]) if len(POSITIONAL_ARGS) > 0 else 17771
LOCAL_PORT = int(POSITIONAL_ARGS[1]) if len(POSITIONAL_ARGS) > 1 else 17772

CLIENT_MAC = bytes([0x02, 0x00, 0x00, 0x00, 0x00, 0x01])
CLIENT_IP = bytes([192, 168, 20, 55])
SERVER_MAC = bytes([0x02, 0x00, 0x20, 0x00, 0x00, 0x02])  # kernel/net/netconfig.tkb's OUR_MAC
SERVER_IP = bytes([192, 168, 20, 2])                      # kernel/net/netconfig.tkb's OUR_IP
SERVER_PORT = 7                                           # kernel/net/tcp.tkb's TCP_ECHO_PORT
HTTP_SERVER_PORT = 8080
# kernel/net/wire.tkb's TCP_INITIAL_SEQ -- fixed, not randomized, so every
# post-handshake sequence number below is known in advance.
SERVER_ISN = 0x00001000

BROADCAST_MAC = bytes([0xff] * 6)
ARP_ETHERTYPE = bytes([0x08, 0x06])
IPV4_ETHERTYPE = bytes([0x08, 0x00])

RETRIES = 30
RETRY_TIMEOUT_SECS = 0.5
SILENCE_TIMEOUT_SECS = 1.0

FLAG_FIN = 0x01
FLAG_SYN = 0x02
FLAG_PSH = 0x08
FLAG_ACK = 0x10

HANDSHAKE_CLIENT_PORT = 43210
HANDSHAKE_CLIENT_ISN = 500
DATA_ECHO_PAYLOAD = b"Hello, TCP echo!"
RECONNECT_CLIENT_PORT = 43211
RECONNECT_CLIENT_ISN = 900
HTTP_CLIENT_PORTS = (43300, 43301, 43302, 43303)
HTTP_CLIENT_ISNS = (1200, 2200, 3200, 4200)
REPO_ROOT = Path(__file__).resolve().parents[1]
HTTP_ASSETS = (
    ("/", REPO_ROOT / "kernel/tests/ext2/index.html", "text/html"),
    ("/index.html", REPO_ROOT / "kernel/tests/ext2/index.html", "text/html"),
    ("/about.html", REPO_ROOT / "kernel/tests/ext2/about.html", "text/html"),
    ("/icon.png", REPO_ROOT / "kernel/tests/ext2/icon.png", "image/png"),
)
INIT_SERVER_PORT = 8080
INIT_CLIENT_PORTS = (43210, 43211)
INIT_CLIENT_ISNS = (500, 900)
INIT_SOCKET_B_INPUT = b"second-B"
INIT_SOCKET_B_RESPONSE = b"conn-B\n!"
INIT_SOCKET_A_RESPONSE = b"HTTP/1.0 200 OK\r\n\r\n"
INIT_LARGE_RESPONSE = b"Z" * 1461


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


def inet_checksum(data: bytes) -> int:
    return checksum_fold(checksum_add(data))


# -- ARP ---------------------------------------------------------------

def build_arp_request(target_ip: bytes) -> bytes:
    eth = BROADCAST_MAC + CLIENT_MAC + ARP_ETHERTYPE
    arp = (
        bytes([0x00, 0x01])
        + bytes([0x08, 0x00])
        + bytes([6, 4])
        + bytes([0x00, 0x01])
        + CLIENT_MAC
        + CLIENT_IP
        + bytes([0x00] * 6)
        + target_ip
    )
    return eth + arp


def check_arp_reply(reply: bytes) -> bool:
    if len(reply) < 42:
        return False
    dst_mac, src_mac, ethertype = reply[0:6], reply[6:12], reply[12:14]
    arp = reply[14:42]
    oper = arp[6:8]
    sha, spa, tha, tpa = arp[8:14], arp[14:18], arp[18:24], arp[24:28]
    return (
        dst_mac == CLIENT_MAC and
        ethertype == ARP_ETHERTYPE and
        oper == bytes([0x00, 0x02]) and
        spa == SERVER_IP and
        tha == CLIENT_MAC and
        tpa == CLIENT_IP and
        src_mac == sha
    )


# -- ICMP --------------------------------------------------------------

def build_icmp_echo(payload: bytes, ident: int, seq: int) -> bytes:
    icmp = struct.pack("!BBHHH", 8, 0, 0, ident, seq) + payload
    csum = inet_checksum(icmp)
    icmp = struct.pack("!BBHHH", 8, 0, csum, ident, seq) + payload

    total_len = 20 + len(icmp)
    ip_hdr = struct.pack("!BBHHHBBH4s4s", 0x45, 0, total_len, 0, 0, 64, 1, 0,
                          CLIENT_IP, SERVER_IP)
    ip_csum = inet_checksum(ip_hdr)
    ip_hdr = struct.pack("!BBHHHBBH4s4s", 0x45, 0, total_len, 0, 0, 64, 1, ip_csum,
                          CLIENT_IP, SERVER_IP)

    eth = SERVER_MAC + CLIENT_MAC + IPV4_ETHERTYPE
    return eth + ip_hdr + icmp


def check_icmp_reply(reply: bytes, payload: bytes, ident: int, seq: int) -> bool:
    if len(reply) < 34 + 8:
        return False
    eth_dst, eth_src, ethertype = reply[0:6], reply[6:12], reply[12:14]
    ip = reply[14:34]
    icmp = reply[34:]
    return (
        eth_dst == CLIENT_MAC and eth_src == SERVER_MAC and
        ethertype == IPV4_ETHERTYPE and
        ip[12:16] == SERVER_IP and ip[16:20] == CLIENT_IP and
        inet_checksum(ip) == 0 and
        icmp[0] == 0 and icmp[1] == 0 and
        inet_checksum(icmp) == 0 and
        icmp[4:6] == struct.pack("!H", ident) and
        icmp[6:8] == struct.pack("!H", seq) and
        icmp[8:] == payload
    )


# -- TCP ---------------------------------------------------------------

def build_tcp_frame(client_port: int, seq: int, ack: int, flags: int,
                    data: bytes = b"", server_port: int = SERVER_PORT,
                    corrupt_tcp_checksum: bool = False) -> bytes:
    tcp_no_csum = struct.pack("!HHIIBBHHH", client_port, server_port, seq, ack,
                              (5 << 4), flags, 65535, 0, 0) + data
    pseudo = CLIENT_IP + SERVER_IP + bytes([0, 6]) + struct.pack("!H", len(tcp_no_csum))
    csum = checksum_fold(checksum_add(pseudo + tcp_no_csum))
    if corrupt_tcp_checksum:
        csum ^= 0xffff
    tcp = struct.pack("!HHIIBBHHH", client_port, server_port, seq, ack,
                      (5 << 4), flags, 65535, csum, 0) + data

    total_len = 20 + len(tcp)
    ip_no_csum = struct.pack("!BBHHHBBH4s4s", 0x45, 0, total_len, 0, 0, 64, 6, 0,
                             CLIENT_IP, SERVER_IP)
    ip_csum = checksum_fold(checksum_add(ip_no_csum))
    ip = struct.pack("!BBHHHBBH4s4s", 0x45, 0, total_len, 0, 0, 64, 6, ip_csum,
                     CLIENT_IP, SERVER_IP)

    eth = SERVER_MAC + CLIENT_MAC + IPV4_ETHERTYPE
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


def do_handshake(sock: socket.socket, client_port: int, client_isn: int) -> bool:
    syn = build_tcp_frame(client_port, client_isn, 0, FLAG_SYN)
    reply = send_and_wait(sock, syn)
    if reply is None:
        print("  no SYN-ACK reply")
        return False

    eth_dst, eth_src, ethertype = reply[0:6], reply[6:12], reply[12:14]
    ip = reply[14:34]
    tcp = reply[34:]
    src_port, dst_port, seq, ack, _doff_res, flags = struct.unpack("!HHIIBB", tcp[0:14])

    pseudo = ip[12:16] + ip[16:20] + bytes([0, 6]) + struct.pack("!H", len(tcp))
    syn_ack_ok = (
        eth_dst == CLIENT_MAC and eth_src == SERVER_MAC and
        ethertype == IPV4_ETHERTYPE and
        src_port == SERVER_PORT and dst_port == client_port and
        flags == (FLAG_SYN | FLAG_ACK) and
        ack == client_isn + 1 and
        seq == SERVER_ISN and
        checksum_fold(checksum_add(ip)) == 0 and
        checksum_fold(checksum_add(pseudo + tcp)) == 0
    )
    if not syn_ack_ok:
        print("  bad SYN-ACK: src_port=%d dst_port=%d seq=%d ack=%d flags=0x%02x" %
              (src_port, dst_port, seq, ack, flags))
        return False

    ack_frame = build_tcp_frame(client_port, client_isn + 1, SERVER_ISN + 1, FLAG_ACK)
    silent_ok = expect_silence(sock, ack_frame)
    if not silent_ok:
        print("  server replied to the final ACK (should stay silent)")
    return silent_ok


def test_syn_wrong_port_silent(sock: socket.socket) -> bool:
    frame = build_tcp_frame(40001, 100, 0, FLAG_SYN, server_port=9999)
    return expect_silence(sock, frame)


def test_syn_bad_checksum_silent(sock: socket.socket) -> bool:
    frame = build_tcp_frame(40002, 200, 0, FLAG_SYN, corrupt_tcp_checksum=True)
    return expect_silence(sock, frame)


def test_data_echo(sock: socket.socket) -> bool:
    seq = HANDSHAKE_CLIENT_ISN + 1
    ack = SERVER_ISN + 1
    frame = build_tcp_frame(HANDSHAKE_CLIENT_PORT, seq, ack, FLAG_ACK | FLAG_PSH,
                            data=DATA_ECHO_PAYLOAD)
    reply = send_and_wait(sock, frame)
    if reply is None:
        print("  no echo reply")
        return False

    ip = reply[14:34]
    tcp = reply[34:]
    src_port, dst_port, rseq, rack, _doff_res, flags = struct.unpack("!HHIIBB", tcp[0:14])
    rdata = tcp[20:]
    pseudo = ip[12:16] + ip[16:20] + bytes([0, 6]) + struct.pack("!H", len(tcp))
    ok = (
        src_port == SERVER_PORT and dst_port == HANDSHAKE_CLIENT_PORT and
        flags == (FLAG_ACK | FLAG_PSH) and
        rseq == SERVER_ISN + 1 and rack == seq + len(DATA_ECHO_PAYLOAD) and
        rdata == DATA_ECHO_PAYLOAD and
        checksum_fold(checksum_add(ip)) == 0 and
        checksum_fold(checksum_add(pseudo + tcp)) == 0
    )
    if not ok:
        print("  bad echo reply: seq=%d ack=%d flags=0x%02x data=%r" %
              (rseq, rack, flags, rdata))
    return ok


def test_close(sock: socket.socket) -> bool:
    client_seq = HANDSHAKE_CLIENT_ISN + 1 + len(DATA_ECHO_PAYLOAD)
    server_seq = SERVER_ISN + 1 + len(DATA_ECHO_PAYLOAD)

    fin = build_tcp_frame(HANDSHAKE_CLIENT_PORT, client_seq, server_seq,
                          FLAG_FIN | FLAG_ACK)
    reply = send_and_wait(sock, fin)
    if reply is None:
        print("  no FIN-ACK reply")
        return False

    ip = reply[14:34]
    tcp = reply[34:]
    src_port, dst_port, rseq, rack, _doff_res, flags = struct.unpack("!HHIIBB", tcp[0:14])
    pseudo = ip[12:16] + ip[16:20] + bytes([0, 6]) + struct.pack("!H", len(tcp))
    fin_ack_ok = (
        src_port == SERVER_PORT and dst_port == HANDSHAKE_CLIENT_PORT and
        flags == (FLAG_FIN | FLAG_ACK) and
        rseq == server_seq and rack == client_seq + 1 and
        checksum_fold(checksum_add(ip)) == 0 and
        checksum_fold(checksum_add(pseudo + tcp)) == 0
    )
    if not fin_ack_ok:
        print("  bad FIN-ACK: seq=%d ack=%d flags=0x%02x" % (rseq, rack, flags))
        return False

    final_ack = build_tcp_frame(HANDSHAKE_CLIENT_PORT, client_seq + 1,
                                server_seq + 1, FLAG_ACK)
    silent_ok = expect_silence(sock, final_ack)
    if not silent_ok:
        print("  server replied to the final closing ACK (should stay silent)")
    return silent_ok


def recv_matching(sock: socket.socket, predicate, timeout: float = 5.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        remaining = max(0.05, deadline - time.monotonic())
        sock.settimeout(remaining)
        try:
            frame = sock.recvfrom(2000)[0]
        except socket.timeout:
            continue
        if len(frame) >= 54 and predicate(frame):
            return frame
    return None


def init_handshake(sock: socket.socket, client_port: int, client_isn: int):
    syn = build_tcp_frame(client_port, client_isn, 0, FLAG_SYN,
                          server_port=INIT_SERVER_PORT)
    reply = None
    for _attempt in range(RETRIES):
        sock.sendto(syn, (QEMU_HOST, QEMU_PORT))
        reply = recv_matching(
            sock,
            lambda candidate: (
                struct.unpack("!HHIIBB", candidate[34:48])[0] ==
                INIT_SERVER_PORT and
                struct.unpack("!HHIIBB", candidate[34:48])[1] ==
                client_port),
            timeout=RETRY_TIMEOUT_SECS)
        if reply is not None:
            break
    if reply is None:
        return None
    tcp = reply[34:]
    src_port, dst_port, server_seq, ack, _doff_res, flags = \
        struct.unpack("!HHIIBB", tcp[0:14])
    if (src_port != INIT_SERVER_PORT or dst_port != client_port or
            flags != (FLAG_SYN | FLAG_ACK) or ack != client_isn + 1):
        return None
    client_seq = client_isn + 1
    server_next = server_seq + 1
    sock.sendto(build_tcp_frame(client_port, client_seq, server_next, FLAG_ACK,
                                server_port=INIT_SERVER_PORT),
                (QEMU_HOST, QEMU_PORT))
    return [client_port, client_seq, server_next, b""]


def init_send(sock: socket.socket, state, data: bytes) -> bool:
    client_port, client_seq, server_next, _pending = state
    frame = build_tcp_frame(client_port, client_seq, server_next,
                            FLAG_ACK | FLAG_PSH, data=data,
                            server_port=INIT_SERVER_PORT)
    sock.sendto(frame, (QEMU_HOST, QEMU_PORT))
    state[1] = client_seq + len(data)
    return True


def init_script_fixture(sock: socket.socket) -> bool:
    # /bin/user_payload binds 8080, accepts both streams before reading either,
    # reads eight bytes from each, writes conn-B on fd 6 and an HTTP status
    # line on fd 5, then writes a 1461-byte response split by the kernel's
    # deliberate dropped-data-segment fixture.
    first = init_handshake(sock, INIT_CLIENT_PORTS[0], INIT_CLIENT_ISNS[0])
    second = init_handshake(sock, INIT_CLIENT_PORTS[1], INIT_CLIENT_ISNS[1])
    if first is None or second is None:
        return False
    # Match the proven RPi5 exchange: A's read is delivered first, then B's
    # read after a short gap so the one-entry virtio RX path is not overrun.
    init_send(sock, first, DATA_ECHO_PAYLOAD)
    time.sleep(0.05)
    init_send(sock, second, INIT_SOCKET_B_INPUT)

    expected_b = INIT_SOCKET_B_RESPONSE
    expected_a = INIT_SOCKET_A_RESPONSE + INIT_LARGE_RESPONSE
    received_b = bytearray()
    received_a = bytearray()
    next_b = second[2]
    next_a = first[2]
    fin_b = False
    fin_a = False
    deadline = time.monotonic() + 10.0
    while (len(received_b) < len(expected_b) or
           len(received_a) < len(expected_a) or
           not fin_b or not fin_a) and time.monotonic() < deadline:
        frame = recv_matching(
            sock,
            lambda candidate: (
                struct.unpack("!HHIIBB", candidate[34:48])[0] ==
                INIT_SERVER_PORT and
                struct.unpack("!HHIIBB", candidate[34:48])[1] in
                INIT_CLIENT_PORTS),
            timeout=0.5)
        if frame is None:
            continue
        tcp = frame[34:]
        src_port, dst_port, sequence, _ack, _doff, flags = \
            struct.unpack("!HHIIBB", tcp[:14])
        header_len = (tcp[12] >> 4) * 4
        payload = frame[34 + header_len:]
        if dst_port == INIT_CLIENT_PORTS[1]:
            if sequence == next_b:
                received_b.extend(payload)
                next_b += len(payload)
                if flags & FLAG_FIN:
                    next_b += 1
                    fin_b = True
            sock.sendto(build_tcp_frame(
                dst_port, second[1], next_b, FLAG_ACK,
                server_port=INIT_SERVER_PORT), (QEMU_HOST, QEMU_PORT))
        else:
            if sequence == next_a:
                received_a.extend(payload)
                next_a += len(payload)
                if flags & FLAG_FIN:
                    next_a += 1
                    fin_a = True
            sock.sendto(build_tcp_frame(
                dst_port, first[1], next_a, FLAG_ACK,
                server_port=INIT_SERVER_PORT), (QEMU_HOST, QEMU_PORT))
    ok = (bytes(received_b) == expected_b and
          bytes(received_a) == expected_a)
    print("  init.sh connected I/O fixture: %s" % ("PASS" if ok else "FAIL"))
    return ok


def http_request(sock: socket.socket, client_port: int, client_isn: int,
                 path: str, expected_body: bytes,
                 expected_content_type: str) -> bool:
    # The bounded boot fixture deliberately drops the first SYN-ACK; the
    # interactive daemon does not. The same retry loop correctly covers both
    # lifecycles without making the interactive test inherit fixture state.
    syn = build_tcp_frame(client_port, client_isn, 0, FLAG_SYN,
                          server_port=HTTP_SERVER_PORT)
    reply = send_and_wait(sock, syn)
    if reply is None:
        print("  no HTTP SYN-ACK reply")
        return False
    tcp = reply[34:]
    src_port, dst_port, server_seq, ack, _doff_res, flags = struct.unpack(
        "!HHIIBB", tcp[0:14])
    if (src_port != HTTP_SERVER_PORT or dst_port != client_port or
            flags != (FLAG_SYN | FLAG_ACK) or ack != client_isn + 1):
        print("  bad HTTP SYN-ACK")
        return False

    client_seq = client_isn + 1
    server_next = server_seq + 1
    early_response_frames = []
    sock.sendto(build_tcp_frame(client_port, client_seq, server_next, FLAG_ACK,
                                server_port=HTTP_SERVER_PORT),
                (QEMU_HOST, QEMU_PORT))

    request_parts = (
        f"GET {path} HTTP/1.0\r\n".encode("ascii"),
        b"Host: 192.168.20.2\r\nConnection: close\r\n\r\n",
    )
    for part in request_parts:
        frame = build_tcp_frame(client_port, client_seq, server_next,
                                FLAG_ACK | FLAG_PSH, data=part,
                                server_port=HTTP_SERVER_PORT)
        expected_ack = client_seq + len(part)
        for _attempt in range(RETRIES):
            sock.sendto(frame, (QEMU_HOST, QEMU_PORT))
            ack_frame = recv_matching(
                sock,
                lambda candidate: (
                    struct.unpack("!HHIIBB", candidate[34:48])[0] ==
                    HTTP_SERVER_PORT and
                    struct.unpack("!HHIIBB", candidate[34:48])[1] ==
                    client_port and
                    (struct.unpack("!HHIIBB", candidate[34:48])[5] & FLAG_ACK) and
                    struct.unpack("!HHIIBB", candidate[34:48])[3] >= expected_ack),
                timeout=RETRY_TIMEOUT_SECS)
            if ack_frame is not None:
                break
        else:
            print("  no HTTP request ACK")
            return False
        tcp_header_length = (ack_frame[46] >> 4) * 4
        if len(ack_frame) > 34 + tcp_header_length:
            early_response_frames.append(ack_frame)
        client_seq = expected_ack

    body = bytearray()
    response_end = False
    deadline = time.monotonic() + 10.0
    while not response_end and time.monotonic() < deadline:
        if early_response_frames:
            frame = early_response_frames.pop(0)
        else:
            sock.settimeout(max(0.05, deadline - time.monotonic()))
            try:
                frame = sock.recvfrom(2000)[0]
            except socket.timeout:
                continue
        if len(frame) < 54:
            continue
        src_port, dst_port, sequence, acknowledgment, _doff_res, flags = \
            struct.unpack("!HHIIBB", frame[34:48])
        if src_port != HTTP_SERVER_PORT or dst_port != client_port:
            continue
        tcp_header_length = (frame[46] >> 4) * 4
        payload = frame[34 + tcp_header_length:34 + len(frame) - 34]
        if sequence == server_next:
            body.extend(payload)
            server_next += len(payload)
        if flags & FLAG_FIN:
            if sequence == server_next:
                server_next += 1
            response_end = True
        if payload or (flags & FLAG_FIN):
            sock.sendto(build_tcp_frame(client_port, client_seq, server_next,
                                        FLAG_ACK, server_port=HTTP_SERVER_PORT),
                        (QEMU_HOST, QEMU_PORT))
    if not response_end:
        print("  HTTP response did not close")
        return False
    response = bytes(body)
    separator = response.find(b"\r\n\r\n")
    header = response[:separator].decode("iso-8859-1") if separator >= 0 else ""
    actual_body = response[separator + 4:] if separator >= 0 else b""
    content_type = ""
    for line in header.split("\r\n"):
        if line.lower().startswith("content-type:"):
            content_type = line.split(":", 1)[1].strip().lower()
            break
    ok = (actual_body == expected_body and
          content_type == expected_content_type)
    print("  HTTP GET %-11s body+type:       %s" %
          (path, "PASS" if ok else "FAIL"))
    if not ok:
        print("  expected content type:", expected_content_type)
        print("  actual content type:  ", content_type)
        print("  expected body bytes:  ", len(expected_body))
        print("  actual body bytes:    ", len(actual_body))
    return ok


def send_until_reply(sock: socket.socket, frame: bytes, check) -> bool:
    for _attempt in range(RETRIES):
        sock.sendto(frame, (QEMU_HOST, QEMU_PORT))
        sock.settimeout(RETRY_TIMEOUT_SECS)
        try:
            reply, _addr = sock.recvfrom(2000)
        except socket.timeout:
            continue
        if check(reply):
            return True
    return False


def main() -> int:
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind((QEMU_HOST, LOCAL_PORT))
    sock.settimeout(RETRY_TIMEOUT_SECS)

    arp_ok = send_until_reply(sock, build_arp_request(SERVER_IP), check_arp_reply)
    print("  who-has 192.168.20.2 (ours):        %s" % ("PASS" if arp_ok else "FAIL"))

    icmp_ok = False
    if arp_ok:
        payload = b"kernel-icmp-echo-0123456789"
        ident, seq = 0x2237, 1
        icmp_ok = send_until_reply(
            sock, build_icmp_echo(payload, ident, seq),
            lambda r: check_icmp_reply(r, payload, ident, seq))
    print("  ping 192.168.20.2 (ours):           %s" % ("PASS" if icmp_ok else "FAIL"))

    # kernel_tcp_echo_check() only starts listening once ICMP has replied,
    # so every TCP step below depends on the two above.
    ok_wrong_port = (icmp_ok if FAST_MODE else
                     icmp_ok and test_syn_wrong_port_silent(sock))
    wrong_port_result = "SKIP (fast shell mode)" if FAST_MODE else (
        "PASS" if ok_wrong_port else "FAIL")
    print("  SYN to wrong port (silent):         %s" % wrong_port_result)

    ok_bad_csum = (ok_wrong_port if FAST_MODE else
                   ok_wrong_port and test_syn_bad_checksum_silent(sock))
    bad_csum_result = "SKIP (fast shell mode)" if FAST_MODE else (
        "PASS" if ok_bad_csum else "FAIL")
    print("  SYN with bad TCP checksum (silent): %s" % bad_csum_result)

    ok_handshake = ok_bad_csum and do_handshake(
        sock, HANDSHAKE_CLIENT_PORT, HANDSHAKE_CLIENT_ISN)
    print("  three-way handshake:                %s" % ("PASS" if ok_handshake else "FAIL"))

    ok_echo = ok_handshake and test_data_echo(sock)
    print("  data echo:                          %s" % ("PASS" if ok_echo else "FAIL"))

    ok_close = ok_echo and test_close(sock)
    print("  connection close:                   %s" % ("PASS" if ok_close else "FAIL"))

    ok_reconnect = ok_close and do_handshake(
        sock, RECONNECT_CLIENT_PORT, RECONNECT_CLIENT_ISN)
    print("  reconnect after close:              %s" % ("PASS" if ok_reconnect else "FAIL"))

    http_ok = False
    if ok_reconnect:
        init_ok = init_script_fixture(sock)
        print("  waiting for HTTP daemon listener")
        for _attempt in range(60):
            try:
                sock.settimeout(0.25)
                frame = sock.recvfrom(2000)[0]
                # No packet is expected here; discard stale dgram frames.
                del frame
            except socket.timeout:
                break
        root_body = HTTP_ASSETS[0][1].read_bytes()
        http_ok = init_ok and all(
            http_request(sock, port, isn, "/", root_body, "text/html")
            for port, isn in zip(HTTP_CLIENT_PORTS[:2], HTTP_CLIENT_ISNS[:2])
        )

    normal_ok = ok_reconnect and http_ok
    if (normal_ok and INTERACTIVE_READY_FILE is not None):
        deadline = time.monotonic() + 90.0
        while not INTERACTIVE_READY_FILE.exists() and time.monotonic() < deadline:
            time.sleep(0.1)
        if not INTERACTIVE_READY_FILE.exists():
            print("  interactive HTTPd never became ready")
            sock.close()
            return 1
        arp_ok = send_until_reply(
            sock, build_arp_request(SERVER_IP), check_arp_reply)
        print("  ARP while HTTPd is listening:       %s" %
              ("PASS" if arp_ok else "FAIL"))
        interactive_ok = arp_ok and all(
            http_request(sock, port, isn, path, source.read_bytes(), mime)
            for (path, source, mime), port, isn in
            zip(HTTP_ASSETS, HTTP_CLIENT_PORTS, HTTP_CLIENT_ISNS))
        sock.close()
        return 0 if interactive_ok else 1

    sock.close()
    return 0 if normal_ok else 1


if __name__ == "__main__":
    sys.exit(main())
