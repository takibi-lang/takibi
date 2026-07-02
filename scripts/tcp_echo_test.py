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
# IMPORTANT ORDERING NOTE: tcp_echo.tkb supports exactly one connection at
# a time. Before FIN/close handling existed there was no way back to
# LISTEN at all, which forced test_handshake_only()/test_data_echo() to
# share one continuous connection via module-level constants
# (HANDSHAKE_CLIENT_PORT/HANDSHAKE_CLIENT_ISN/SERVER_ISN) instead of being
# fully independent. Now that close works, test_close() finishes off that
# same connection (it must run after test_data_echo(), continuing its
# sequence numbers), and test_reconnect_after_close() proves the slot was
# actually freed by opening a brand new, fully independent connection
# afterward -- if close silently failed to reset state, this is the test
# that would catch it.
#
# The negative ("stays silent") tests still must run before
# test_handshake_only(), for the same original reason: once any handshake
# succeeds the server stops being in LISTEN, and a "stays silent" result
# after that would be true for the wrong reason (slot taken, not
# whatever-was-being-tested).
#
# Order that matters: test_syn_wrong_port_silent, test_syn_bad_checksum_silent,
# test_syn_with_options_accepted (any order among these three, all need
# LISTEN and the last one RSTs its own half-open connection before
# returning so it doesn't hold the slot) -> test_handshake_only ->
# test_data_echo -> test_close -> test_reconnect_after_close.
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
FLAG_PSH = 0x08
FLAG_ACK = 0x10

HANDSHAKE_CLIENT_PORT = 43210
HANDSHAKE_CLIENT_ISN = 500
# Matches tcp_echo.tkb's OUR_ISN -- fixed rather than randomized in this
# bare-metal single-connection test-only responder, so the post-handshake
# sequence number is always known in advance.
SERVER_ISN = 0x00001000

DATA_ECHO_PAYLOAD = b"Hello, TCP echo!"

RECONNECT_CLIENT_PORT = 43211
RECONNECT_CLIENT_ISN = 900


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
                 data: bytes = b"", corrupt_tcp_checksum: bool = False,
                 options: bytes = b"") -> bytes:
    # options is raw bytes inserted between the fixed 20-byte header and
    # data (e.g. a 4-byte MSS option), with the data offset field adjusted
    # to match -- used by test_syn_with_options_accepted to prove
    # tcp_echo.tkb doesn't require a bare 20-byte header. len(options)
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


def test_syn_with_options_accepted() -> bool:
    # Regression test: tcp_echo.tkb used to require a bare 20-byte header
    # (data offset == 5) and reject anything else, which happened to never
    # matter for this script (every frame here is hand-built without
    # options) but silently broke any *real* TCP client -- SLIRP and every
    # real OS always attach at least an MSS option to a SYN. Caught (and
    # fixed) while building examples/http_server; see CLAUDE.md's HTTP
    # Server section. This sends a SYN with a 4-byte MSS option (data
    # offset == 6, 24-byte header) and confirms it still gets a normal
    # SYN-ACK, then RSTs the half-open connection to free the slot for the
    # rest of this file's tests (which assume a bare LISTEN to start).
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind((QEMU_HOST, LOCAL_PORT))

    client_port = 40003
    client_isn = 300
    mss_option = bytes([0x02, 0x04, 0x05, 0xb4])  # kind=MSS, len=4, value=1460
    syn = build_frame(client_port, client_isn, 0, FLAG_SYN, options=mss_option)
    reply = send_and_wait(sock, syn)
    if reply is None:
        print("  no SYN-ACK reply to a SYN carrying a TCP option")
        sock.close()
        return False

    tcp = reply[34:]
    src_port, dst_port, seq, ack, _doff_res, flags = struct.unpack("!HHIIBB", tcp[0:14])
    ok = (src_port == SERVER_PORT and dst_port == client_port and
          flags == (FLAG_SYN | FLAG_ACK) and ack == client_isn + 1 and seq == SERVER_ISN)
    if not ok:
        print("  bad SYN-ACK for options-bearing SYN: src_port=%d dst_port=%d "
              "seq=%d ack=%d flags=0x%02x" % (src_port, dst_port, seq, ack, flags))

    # Abandon this half-open connection regardless of ok, so a failure
    # here doesn't also break every test that runs after it.
    rst = build_frame(client_port, client_isn + 1, 0, FLAG_RST)
    sock.sendto(rst, (QEMU_HOST, QEMU_PORT))
    sock.close()
    return ok


def do_handshake(sock: socket.socket, client_port: int, client_isn: int) -> bool:
    """Performs SYN -> verify SYN-ACK -> ACK -> verify silence. Prints its
    own diagnostics on failure; the server's ISN is always SERVER_ISN
    (fixed, not randomized -- see its definition above), so callers don't
    need it returned separately."""
    syn = build_frame(client_port, client_isn, 0, FLAG_SYN)
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

    ack_frame = build_frame(client_port, client_isn + 1, SERVER_ISN + 1, FLAG_ACK)
    silent_ok = expect_silence(sock, ack_frame)
    if not silent_ok:
        print("  server replied to the final ACK (should stay silent)")
    return silent_ok


def test_handshake_only() -> bool:
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind((QEMU_HOST, LOCAL_PORT))
    ok = do_handshake(sock, HANDSHAKE_CLIENT_PORT, HANDSHAKE_CLIENT_ISN)
    sock.close()
    return ok


def test_data_echo() -> bool:
    # Continues the connection test_handshake_only() already fully
    # established -- see the ordering note at the top of this file for why
    # this can't perform its own independent handshake.
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind((QEMU_HOST, LOCAL_PORT))

    seq = HANDSHAKE_CLIENT_ISN + 1
    ack = SERVER_ISN + 1
    frame = build_frame(HANDSHAKE_CLIENT_PORT, seq, ack, FLAG_ACK | FLAG_PSH,
                         data=DATA_ECHO_PAYLOAD)
    reply = send_and_wait(sock, frame)
    sock.close()
    if reply is None:
        print("  no echo reply")
        return False

    eth_dst, eth_src, ethertype = reply[0:6], reply[6:12], reply[12:14]
    ip = reply[14:34]
    tcp = reply[34:]
    src_port, dst_port, rseq, rack, _doff_res, flags = struct.unpack("!HHIIBB", tcp[0:14])
    rdata = tcp[20:]

    pseudo = ip[12:16] + ip[16:20] + bytes([0, 6]) + struct.pack("!H", len(tcp))
    ok = (
        eth_dst == CLIENT_MAC and eth_src == SERVER_MAC and
        ethertype == bytes([0x08, 0x00]) and
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


def test_close() -> bool:
    # Finishes off the connection test_handshake_only()/test_data_echo()
    # already built up -- must run after both.
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind((QEMU_HOST, LOCAL_PORT))

    client_seq = HANDSHAKE_CLIENT_ISN + 1 + len(DATA_ECHO_PAYLOAD)
    server_seq = SERVER_ISN + 1 + len(DATA_ECHO_PAYLOAD)

    fin = build_frame(HANDSHAKE_CLIENT_PORT, client_seq, server_seq, FLAG_FIN | FLAG_ACK)
    reply = send_and_wait(sock, fin)
    if reply is None:
        print("  no FIN-ACK reply")
        sock.close()
        return False

    eth_dst, eth_src, ethertype = reply[0:6], reply[6:12], reply[12:14]
    ip = reply[14:34]
    tcp = reply[34:]
    src_port, dst_port, rseq, rack, _doff_res, flags = struct.unpack("!HHIIBB", tcp[0:14])

    pseudo = ip[12:16] + ip[16:20] + bytes([0, 6]) + struct.pack("!H", len(tcp))
    fin_ack_ok = (
        eth_dst == CLIENT_MAC and eth_src == SERVER_MAC and
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

    final_ack = build_frame(HANDSHAKE_CLIENT_PORT, client_seq + 1, server_seq + 1, FLAG_ACK)
    silent_ok = expect_silence(sock, final_ack)
    sock.close()
    if not silent_ok:
        print("  server replied to the final closing ACK (should stay silent)")
    return silent_ok


def test_reconnect_after_close() -> bool:
    # Proves close actually freed the connection slot: opens a brand new,
    # fully independent connection (different port/ISN) with no relation
    # to the one test_close() just tore down. If close silently failed to
    # reset conn_state to LISTEN, this SYN would just be ignored and this
    # test would fail even though test_close() itself passed.
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind((QEMU_HOST, LOCAL_PORT))
    ok = do_handshake(sock, RECONNECT_CLIENT_PORT, RECONNECT_CLIENT_ISN)
    sock.close()
    return ok


def main() -> int:
    ok1 = test_syn_wrong_port_silent()
    print("  SYN to wrong port (silent):        %s" % ("PASS" if ok1 else "FAIL"))

    ok2 = test_syn_bad_checksum_silent()
    print("  SYN with bad TCP checksum (silent): %s" % ("PASS" if ok2 else "FAIL"))

    ok2b = test_syn_with_options_accepted()
    print("  SYN with TCP options accepted:     %s" % ("PASS" if ok2b else "FAIL"))

    ok3 = test_handshake_only()
    print("  three-way handshake:               %s" % ("PASS" if ok3 else "FAIL"))

    ok4 = ok3 and test_data_echo()
    print("  data echo:                         %s" % ("PASS" if ok4 else "FAIL"))

    ok5 = ok4 and test_close()
    print("  connection close:                  %s" % ("PASS" if ok5 else "FAIL"))

    ok6 = ok5 and test_reconnect_after_close()
    print("  reconnect after close:             %s" % ("PASS" if ok6 else "FAIL"))

    return 0 if (ok1 and ok2 and ok2b and ok3 and ok4 and ok5 and ok6) else 1


if __name__ == "__main__":
    sys.exit(main())
