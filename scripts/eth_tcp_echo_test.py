#!/usr/bin/env python3
# Tests examples/tcp_echo/tcp_echo_stm32.tkb over a raw AF_PACKET socket on a
# physical point-to-point link to the real STM32F746G-DISCOVERY board. Same
# test functions, same ordering requirements, and the same "why one kernel,
# many test functions instead of many kernels" reasoning as
# scripts/tcp_echo_test.py (the QEMU/virtio-net counterpart) -- see that
# file's header comment in full; only the transport differs here.
#
# One real-hardware wrinkle not present over virtio-net: TCP control
# segments with no payload (bare SYN/SYN-ACK/FIN-ACK, 54 bytes: 14 eth + 20
# IP + 20 TCP) are below Ethernet's 60-byte minimum. The STM32 MAC's
# automatic pad/CRC handling (MACCR.APCS) pads *outgoing* short frames to 60
# bytes regardless of EtherType -- unlike the *receive*-side stripping
# ambiguity documented in scripts/eth_net_echo_test.py's module comment,
# which only applies to frames the board receives, not ones it sends. So a
# reply this script receives may have trailing pad bytes beyond the logical
# TCP segment. Slicing `reply[34:]` to "everything remaining" (as the QEMU
# version does, safe there since virtio-net never pads) would fold those pad
# bytes into the TCP checksum verification and fail it for the wrong reason.
# Every reply is therefore sliced to its exact expected length below instead.
#
# Needs CAP_NET_RAW (run via sudo, or `make hwcheck-net` which already does)
# and ETH_TEST_IFACE pointed at the wired interface (default enp4s0).
# ETH_TEST_SUBNET/ETH_TEST_MAC optionally select another target while
# retaining STM32's existing defaults (used by the Raspberry Pi 3 port).
#
# Exit code only (0 = pass, 1 = fail).

import os
import socket
import struct
import sys
import time

IFACE = os.environ.get("ETH_TEST_IFACE", "enp4s0")

SUBNET = [int(part) for part in os.environ.get("ETH_TEST_SUBNET", "192.168.10").split(".")]
SERVER_MAC = bytes.fromhex(os.environ.get("ETH_TEST_MAC", "00:80:e1:00:00:00").replace(":", ""))
CLIENT_IP = bytes(SUBNET + [55])
SERVER_IP = bytes(SUBNET + [2])
SERVER_PORT = int(os.environ.get("TCP_TEST_PORT", "7"))

RETRIES = 20
RETRY_TIMEOUT_SECS = 0.5
SILENCE_TIMEOUT_SECS = 1.0

FLAG_FIN = 0x01
FLAG_SYN = 0x02
FLAG_RST = 0x04
FLAG_PSH = 0x08
FLAG_ACK = 0x10

HANDSHAKE_CLIENT_PORT = 43210
HANDSHAKE_CLIENT_ISN = 500
# Matches tcp_echo_stm32.tkb's OUR_ISN -- fixed rather than randomized in
# this bare-metal single-connection test-only responder, so the
# post-handshake sequence number is always known in advance.
SERVER_ISN = 0x00001000

DATA_ECHO_PAYLOAD = b"Hello, TCP echo!"
CONNECTED_RESPONSE_PAYLOAD = b"HTTP/1.0 200 OK\r\n\r\n"

RECONNECT_CLIENT_PORT = 43211
RECONNECT_CLIENT_ISN = 900


def read_iface_mac(iface: str) -> bytes:
    with open(f"/sys/class/net/{iface}/address") as f:
        return bytes(int(b, 16) for b in f.read().strip().split(":"))


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


def build_frame(client_mac: bytes, client_port: int, seq: int, ack: int, flags: int,
                 data: bytes = b"", corrupt_tcp_checksum: bool = False,
                 options: bytes = b"") -> bytes:
    # options is raw bytes inserted between the fixed 20-byte header and
    # data (e.g. a 4-byte MSS option), with the data offset field adjusted
    # to match -- used by test_syn_with_options_accepted to prove
    # tcp_echo_stm32.tkb doesn't require a bare 20-byte header. len(options)
    # must be a multiple of 4 (TCP header length is in 32-bit words).
    doff_words = 5 + len(options) // 4
    tcp_no_csum = struct.pack("!HHIIBBHHH", client_port, SERVER_PORT, seq, ack,
                               (doff_words << 4), flags, 65535, 0, 0) + options + data
    pseudo = CLIENT_IP + SERVER_IP + bytes([0, 6]) + struct.pack("!H", len(tcp_no_csum))
    csum = checksum_fold(checksum_add(pseudo + tcp_no_csum))
    if corrupt_tcp_checksum:
        csum ^= 0xffff
    tcp = struct.pack("!HHIIBBHHH", client_port, SERVER_PORT, seq, ack,
                       (doff_words << 4), flags, 65535, csum, 0) + options + data

    total_len = 20 + len(tcp)
    ip_no_csum = struct.pack("!BBHHHBBH4s4s", 0x45, 0, total_len, 0, 0, 64, 6, 0,
                              CLIENT_IP, SERVER_IP)
    ip_csum = checksum_fold(checksum_add(ip_no_csum))
    ip = struct.pack("!BBHHHBBH4s4s", 0x45, 0, total_len, 0, 0, 64, 6, ip_csum,
                      CLIENT_IP, SERVER_IP)

    eth = SERVER_MAC + client_mac + bytes([0x08, 0x00])
    return eth + ip + tcp


def recv_reply(sock: socket.socket, sent_frame: bytes, timeout: float):
    """Reads until a genuine server-to-client reply arrives or timeout.

    AF_PACKET can report our outgoing frame with padding or other link-layer
    differences, so byte-for-byte comparison with ``sent_frame`` is not a
    sufficient direction filter.  A bound raw socket can also see unrelated
    IPv4 traffic on the interface.  Filter both explicitly before handing a
    frame to the protocol-specific checks below.
    """
    deadline = time.monotonic() + timeout
    client_mac = sent_frame[6:12]
    while time.monotonic() < deadline:
        sock.settimeout(max(deadline - time.monotonic(), 0.001))
        try:
            reply, addr = sock.recvfrom(2000)
        except socket.timeout:
            return None
        # sockaddr_ll tuple: (ifname, proto, pkttype, hatype, addr).
        # PACKET_OUTGOING is 4 on Linux; getattr keeps this usable on Python
        # builds that do not expose the symbolic constant.
        if len(addr) >= 3 and addr[2] == getattr(socket, "PACKET_OUTGOING", 4):
            continue
        if len(reply) < 14:
            continue
        if reply[0:6] != client_mac or reply[6:12] != SERVER_MAC:
            continue
        if reply[12:14] != bytes([0x08, 0x00]):
            continue
        return reply
    return None


def send_and_wait(sock: socket.socket, frame: bytes):
    for _attempt in range(RETRIES):
        sock.send(frame)
        reply = recv_reply(sock, frame, RETRY_TIMEOUT_SECS)
        if reply is not None:
            return reply
    return None


def expect_silence(sock: socket.socket, frame: bytes) -> bool:
    sock.send(frame)
    reply = recv_reply(sock, frame, SILENCE_TIMEOUT_SECS)
    if reply is not None:
        print("  unexpected reply:", reply.hex())
        return False
    return True


def new_sock() -> socket.socket:
    sock = socket.socket(socket.AF_PACKET, socket.SOCK_RAW, socket.htons(0x0800))
    sock.bind((IFACE, 0))
    return sock


def test_syn_wrong_port_silent(client_mac: bytes) -> bool:
    sock = new_sock()
    global SERVER_PORT
    saved = SERVER_PORT
    SERVER_PORT = 9999  # not tcp_echo_stm32's listening port
    frame = build_frame(client_mac, client_port=40001, seq=100, ack=0, flags=FLAG_SYN)
    SERVER_PORT = saved
    ok = expect_silence(sock, frame)
    sock.close()
    return ok


def test_syn_bad_checksum_silent(client_mac: bytes) -> bool:
    sock = new_sock()
    frame = build_frame(client_mac, client_port=40002, seq=200, ack=0, flags=FLAG_SYN,
                         corrupt_tcp_checksum=True)
    ok = expect_silence(sock, frame)
    sock.close()
    return ok


def test_syn_with_options_accepted(client_mac: bytes) -> bool:
    # Regression test carried over from scripts/tcp_echo_test.py: a real TCP
    # client always attaches at least an MSS option to a SYN. Sends a SYN
    # with a 4-byte MSS option (data offset == 6, 24-byte header) and
    # confirms it still gets a normal SYN-ACK, then RSTs the half-open
    # connection to free the slot for the rest of this file's tests.
    sock = new_sock()

    client_port = 40003
    client_isn = 300
    mss_option = bytes([0x02, 0x04, 0x05, 0xb4])  # kind=MSS, len=4, value=1460
    syn = build_frame(client_mac, client_port, client_isn, 0, FLAG_SYN, options=mss_option)
    reply = send_and_wait(sock, syn)
    if reply is None:
        print("  no SYN-ACK reply to a SYN carrying a TCP option")
        sock.close()
        return False

    tcp = reply[34:54]  # exactly 20 bytes -- see module comment on TX-side padding
    src_port, dst_port, seq, ack, _doff_res, flags = struct.unpack("!HHIIBB", tcp[0:14])
    ok = (src_port == SERVER_PORT and dst_port == client_port and
          flags == (FLAG_SYN | FLAG_ACK) and ack == client_isn + 1 and seq == SERVER_ISN)
    if not ok:
        print("  bad SYN-ACK for options-bearing SYN: src_port=%d dst_port=%d "
              "seq=%d ack=%d flags=0x%02x" % (src_port, dst_port, seq, ack, flags))

    # Abandon this half-open connection regardless of ok, so a failure
    # here doesn't also break every test that runs after it.
    rst = build_frame(client_mac, client_port, client_isn + 1, 0, FLAG_RST)
    sock.send(rst)
    sock.close()
    return ok


def do_handshake(sock: socket.socket, client_mac: bytes, client_port: int, client_isn: int) -> bool:
    """Performs SYN -> verify SYN-ACK -> ACK -> verify silence. Prints its
    own diagnostics on failure; the server's ISN is always SERVER_ISN
    (fixed, not randomized -- see its definition above), so callers don't
    need it returned separately."""
    syn = build_frame(client_mac, client_port, client_isn, 0, FLAG_SYN)
    reply = send_and_wait(sock, syn)
    if reply is None:
        print("  no SYN-ACK reply")
        return False

    eth_dst, eth_src, ethertype = reply[0:6], reply[6:12], reply[12:14]
    ip = reply[14:34]
    tcp = reply[34:54]  # exactly 20 bytes -- see module comment on TX-side padding
    src_port, dst_port, seq, ack, _doff_res, flags = struct.unpack("!HHIIBB", tcp[0:14])

    pseudo = ip[12:16] + ip[16:20] + bytes([0, 6]) + struct.pack("!H", len(tcp))
    syn_ack_ok = (
        eth_dst == client_mac and eth_src == SERVER_MAC and
        ethertype == bytes([0x08, 0x00]) and
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

    ack_frame = build_frame(client_mac, client_port, client_isn + 1, SERVER_ISN + 1, FLAG_ACK)
    silent_ok = expect_silence(sock, ack_frame)
    if not silent_ok:
        print("  server replied to the final ACK (should stay silent)")
    return silent_ok


def test_handshake_only(client_mac: bytes) -> bool:
    sock = new_sock()
    ok = do_handshake(sock, client_mac, HANDSHAKE_CLIENT_PORT, HANDSHAKE_CLIENT_ISN)
    sock.close()
    return ok


def test_data_echo(client_mac: bytes, expected_payload: bytes = DATA_ECHO_PAYLOAD) -> bool:
    # Continues the connection test_handshake_only() already fully
    # established -- see scripts/tcp_echo_test.py's ordering note for why
    # this can't perform its own independent handshake.
    sock = new_sock()

    seq = HANDSHAKE_CLIENT_ISN + 1
    ack = SERVER_ISN + 1
    frame = build_frame(client_mac, HANDSHAKE_CLIENT_PORT, seq, ack, FLAG_ACK | FLAG_PSH,
                         data=DATA_ECHO_PAYLOAD)
    reply = send_and_wait(sock, frame)
    sock.close()
    if reply is None:
        print("  no echo reply")
        return False

    eth_dst, eth_src, ethertype = reply[0:6], reply[6:12], reply[12:14]
    ip = reply[14:34]
    # Exactly 20 + payload bytes -- the frame is well above the 60-byte
    # Ethernet minimum here, so no TX-side padding is actually added in
    # practice, but slicing explicitly keeps this robust regardless.
    tcp = reply[34:34 + 20 + len(expected_payload)]
    src_port, dst_port, rseq, rack, _doff_res, flags = struct.unpack("!HHIIBB", tcp[0:14])
    rdata = tcp[20:]

    pseudo = ip[12:16] + ip[16:20] + bytes([0, 6]) + struct.pack("!H", len(tcp))
    ok = (
        eth_dst == client_mac and eth_src == SERVER_MAC and
        ethertype == bytes([0x08, 0x00]) and
        src_port == SERVER_PORT and dst_port == HANDSHAKE_CLIENT_PORT and
        flags == (FLAG_ACK | FLAG_PSH) and
        rseq == SERVER_ISN + 1 and rack == seq + len(DATA_ECHO_PAYLOAD) and
        rdata == expected_payload and
        checksum_fold(checksum_add(ip)) == 0 and
        checksum_fold(checksum_add(pseudo + tcp)) == 0
    )
    if not ok:
        print("  bad echo reply: seq=%d ack=%d flags=0x%02x data=%r" %
              (rseq, rack, flags, rdata))
    return ok


def test_close(client_mac: bytes) -> bool:
    # Finishes off the connection test_handshake_only()/test_data_echo()
    # already built up -- must run after both.
    sock = new_sock()

    client_seq = HANDSHAKE_CLIENT_ISN + 1 + len(DATA_ECHO_PAYLOAD)
    server_seq = SERVER_ISN + 1 + len(DATA_ECHO_PAYLOAD)

    fin = build_frame(client_mac, HANDSHAKE_CLIENT_PORT, client_seq, server_seq, FLAG_FIN | FLAG_ACK)
    reply = send_and_wait(sock, fin)
    if reply is None:
        print("  no FIN-ACK reply")
        sock.close()
        return False

    eth_dst, eth_src, ethertype = reply[0:6], reply[6:12], reply[12:14]
    ip = reply[14:34]
    tcp = reply[34:54]  # exactly 20 bytes -- see module comment on TX-side padding
    src_port, dst_port, rseq, rack, _doff_res, flags = struct.unpack("!HHIIBB", tcp[0:14])

    pseudo = ip[12:16] + ip[16:20] + bytes([0, 6]) + struct.pack("!H", len(tcp))
    fin_ack_ok = (
        eth_dst == client_mac and eth_src == SERVER_MAC and
        ethertype == bytes([0x08, 0x00]) and
        src_port == SERVER_PORT and dst_port == HANDSHAKE_CLIENT_PORT and
        flags == (FLAG_FIN | FLAG_ACK) and
        rseq == server_seq and rack == client_seq + 1 and
        checksum_fold(checksum_add(ip)) == 0 and
        checksum_fold(checksum_add(pseudo + tcp)) == 0
    )
    if not fin_ack_ok:
        print("  bad FIN-ACK: seq=%d ack=%d flags=0x%02x" % (rseq, rack, flags))
        sock.close()
        return False

    final_ack = build_frame(client_mac, HANDSHAKE_CLIENT_PORT, client_seq + 1, server_seq + 1, FLAG_ACK)
    silent_ok = expect_silence(sock, final_ack)
    sock.close()
    if not silent_ok:
        print("  server replied to the final closing ACK (should stay silent)")
    return silent_ok


def test_reconnect_after_close(client_mac: bytes) -> bool:
    # Proves close actually freed the connection slot: opens a brand new,
    # fully independent connection (different port/ISN) with no relation
    # to the one test_close() just tore down.
    sock = new_sock()
    ok = do_handshake(sock, client_mac, RECONNECT_CLIENT_PORT, RECONNECT_CLIENT_ISN)
    sock.close()
    return ok


# GitHub issue #180: kernel/arch/arm64/kernel/user_entry.S's EL0 fixture
# (used only by TCP_TEST_CONNECTED_IO=1, the userspace socket-syscall
# path -- not the BusyBox/curl path) issues exactly 3 write(5, ...)
# calls on connection A after connection B has also been accepted: 19 bytes
# ("HTTP/1.0 200 OK\r\n\r\n"), 1461 bytes of 0x5a fill capped at 1460 by
# the kernel's partial-write behavior, then the final byte. kernel/init/
# main.tkb arms kernel_tcp_inject_drop_data_segment(1) before running
# this fixture, so the MIDDLE (1460-byte) segment's first transmission
# is always silently skipped and only reaches the wire via the kernel's
# real timeout+retry queue (kernel/net/tcp.tkb's pending_tcp_service_once)
# -- this one check therefore has to prove both the multi-segment queue's
# happy path (segments 0 and 2) and its drop-recovery path (segment 1) at
# once, since both happen in the same boot. Earlier versions of this
# check only read the first reply frame and only verified the 19-byte
# header; this reconstructs and byte-compares the complete response.
CONNECTED_LARGE_RESPONSE = CONNECTED_RESPONSE_PAYLOAD + (b"\x5a" * 1460) + b"\x5a"


def test_connected_large_response(client_mac: bytes) -> bool:
    # Issue #189: establish A and B before sending data on either one. The
    # EL0 fixture blocks in its second accept4() while A remains live, so a
    # successful second handshake proves the kernel allocated fd 6 and an
    # independent connection-pool slot rather than overwriting fd 5/A.
    sock = new_sock()
    if not do_handshake(sock, client_mac, HANDSHAKE_CLIENT_PORT,
                        HANDSHAKE_CLIENT_ISN):
        sock.close()
        return False
    if not do_handshake(sock, client_mac, RECONNECT_CLIENT_PORT,
                        RECONNECT_CLIENT_ISN):
        sock.close()
        return False
    client_seq = HANDSHAKE_CLIENT_ISN + 1 + len(DATA_ECHO_PAYLOAD)
    server_seq = SERVER_ISN + 1
    second_payload = b"second-B"
    second_response = b"conn-B\n!"
    second_client_seq = RECONNECT_CLIENT_ISN + 1 + len(second_payload)
    second_server_seq = SERVER_ISN + 1

    req = build_frame(client_mac, HANDSHAKE_CLIENT_PORT,
                       HANDSHAKE_CLIENT_ISN + 1, server_seq,
                       FLAG_ACK | FLAG_PSH, data=DATA_ECHO_PAYLOAD)
    sock.send(req)
    # A's first read rearms the sole physical GEM RX descriptor before the
    # fixture asks for B. This small delay avoids intentionally overrunning
    # that one-entry hardware ring; #189 tests connection state, not RX-ring
    # depth or concurrent packet arrival.
    time.sleep(0.05)
    second_req = build_frame(
        client_mac, RECONNECT_CLIENT_PORT, RECONNECT_CLIENT_ISN + 1,
        second_server_seq, FLAG_ACK | FLAG_PSH, data=second_payload)
    sock.send(second_req)

    collected = b""
    want = len(CONNECTED_LARGE_RESPONSE)
    fin_acked = False
    second_response_ok = False
    second_fin_acked = False
    # Generous but bounded: the kernel's own retry budget for one dropped
    # segment is TCP_RETRY_LIMIT(3) * retry_ticks(~200ms) =~ 600ms (see
    # kernel/net/tcp.tkb's kernel_tcp_accept_once comment) -- 10s covers
    # that many times over without masking a genuine hang as a slow pass.
    # kernel/init/main.tkb also arms kernel_tcp_inject_drop_next_fin, so
    # close()'s own FIN is silently unsent on its first attempt too and
    # only reaches the wire via the same retry path -- this loop keeps
    # running past a fully-collected body specifically to see and ACK
    # that FIN once it (eventually) arrives; skipping it would leave
    # kernel_tcp_injected_fin_recovered() permanently false, since it
    # requires a real peer ACK, not merely a retransmit attempt.
    deadline = time.monotonic() + 10.0
    while (len(collected) < want or not second_response_ok or
           not fin_acked or not second_fin_acked) and time.monotonic() < deadline:
        reply = recv_reply(sock, req, 2.0)
        if reply is None:
            continue
        if len(reply) < 54:
            continue
        ip = reply[14:34]
        tcp_hdr = reply[34:54]
        src_port, dst_port, rseq, rack, _doff_res, flags = struct.unpack(
            "!HHIIBB", tcp_hdr[0:14])
        if src_port != SERVER_PORT or dst_port not in (
                HANDSHAKE_CLIENT_PORT, RECONNECT_CLIENT_PORT):
            continue
        if (flags & FLAG_ACK) == 0:
            continue
        total_len = struct.unpack("!H", ip[2:4])[0]
        payload_len = total_len - 40  # 20 IP + 20 TCP, no options on any reply here

        if dst_port == RECONNECT_CLIENT_PORT:
            if payload_len > 0 and not second_response_ok:
                payload = reply[54:54 + payload_len]
                if (rseq == second_server_seq and
                    rack == second_client_seq and
                    payload == second_response):
                    second_server_seq += payload_len
                    second_response_ok = True
                    sock.send(build_frame(
                        client_mac, RECONNECT_CLIENT_PORT,
                        second_client_seq, second_server_seq, FLAG_ACK))
                continue
            if ((flags & FLAG_FIN) != 0 and not second_fin_acked and
                    rseq == second_server_seq):
                second_server_seq += 1
                sock.send(build_frame(
                    client_mac, RECONNECT_CLIENT_PORT,
                    second_client_seq, second_server_seq, FLAG_ACK))
                second_fin_acked = True
            continue

        if len(collected) < want and payload_len > 0:
            if rseq != server_seq:
                # Not the next in-order byte -- either a retransmit of a
                # segment already collected, or (should not happen here)
                # one arriving out of order. Cumulative-ACK it again
                # without appending, matching real TCP receiver behavior,
                # so the kernel's own retry loop sees the ack it is
                # waiting for even if this reply is a duplicate.
                dup_ack = build_frame(client_mac, HANDSHAKE_CLIENT_PORT,
                                       client_seq, server_seq, FLAG_ACK)
                sock.send(dup_ack)
                continue
            payload = reply[54:54 + payload_len]
            collected += payload
            server_seq += payload_len
            ack = build_frame(client_mac, HANDSHAKE_CLIENT_PORT,
                               client_seq, server_seq, FLAG_ACK)
            sock.send(ack)
            continue

        if (flags & FLAG_FIN) != 0 and not fin_acked and rseq == server_seq:
            server_seq += 1  # FIN consumes one sequence number
            fin_ack = build_frame(client_mac, HANDSHAKE_CLIENT_PORT,
                                   client_seq, server_seq, FLAG_ACK)
            sock.send(fin_ack)
            fin_acked = True

    sock.close()
    if collected != CONNECTED_LARGE_RESPONSE:
        print("  connected large response mismatch: got %d bytes, want %d" %
              (len(collected), want))
        for i in range(min(len(collected), want)):
            if collected[i] != CONNECTED_LARGE_RESPONSE[i]:
                print("    first difference at byte %d: got 0x%02x want 0x%02x" %
                      (i, collected[i], CONNECTED_LARGE_RESPONSE[i]))
                break
        return False
    if not second_response_ok:
        print("  second overlapping connection response mismatch")
        return False
    if not second_fin_acked:
        print("  second overlapping connection FIN was never acknowledged")
        return False
    if not fin_acked:
        print("  server FIN was never observed/acknowledged")
        return False
    return True


def main() -> int:
    if not os.path.exists(f"/sys/class/net/{IFACE}"):
        print(f"error: interface {IFACE!r} not found -- set ETH_TEST_IFACE?", file=sys.stderr)
        return 1
    client_mac = read_iface_mac(IFACE)

    if os.environ.get("TCP_TEST_CONNECTED_IO") == "1":
        io_ok = test_connected_large_response(client_mac)
        print("  userspace overlapping accepts (fd 5 + fd 6): %s" %
              ("PASS" if io_ok else "FAIL"))
        print("  userspace connected generated response (%d bytes, incl. "
              "mid-response drop recovery): %s" %
              (len(CONNECTED_LARGE_RESPONSE), "PASS" if io_ok else "FAIL"))
        return 0 if io_ok else 1

    ok1 = test_syn_wrong_port_silent(client_mac)
    print("  SYN to wrong port (silent):        %s" % ("PASS" if ok1 else "FAIL"))

    ok2 = test_syn_bad_checksum_silent(client_mac)
    print("  SYN with bad TCP checksum (silent): %s" % ("PASS" if ok2 else "FAIL"))

    ok2b = test_syn_with_options_accepted(client_mac)
    print("  SYN with TCP options accepted:     %s" % ("PASS" if ok2b else "FAIL"))

    ok3 = test_handshake_only(client_mac)
    print("  three-way handshake:               %s" % ("PASS" if ok3 else "FAIL"))

    ok4 = ok3 and test_data_echo(client_mac)
    print("  data echo:                         %s" % ("PASS" if ok4 else "FAIL"))

    ok5 = ok4 and test_close(client_mac)
    print("  connection close:                  %s" % ("PASS" if ok5 else "FAIL"))

    ok6 = ok5 and test_reconnect_after_close(client_mac)
    print("  reconnect after close:             %s" % ("PASS" if ok6 else "FAIL"))

    return 0 if (ok1 and ok2 and ok2b and ok3 and ok4 and ok5 and ok6) else 1


if __name__ == "__main__":
    sys.exit(main())
