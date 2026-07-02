#!/usr/bin/env python3
"""
Fires a sustained burst of large TCP data segments at
examples/tcp_echo/tcp_echo.tkb, over one connection, so
profile_tcp_echo.py's PC sampler has continuous work to sample instead of
mostly landing in the idle-wait loop the way the HTTP-server profile did
(see that script's docstring for why: request/response round trips there
were dominated by network-wait and a deliberate 1s silence check, so the
server was idle almost the whole time).

Two things are deliberately different from a correctness test like
tcp_echo_test.py here, specifically to keep the server continuously busy:
  - No expect_silence-style dead time between segments -- just handshake
    once, then send/receive as fast as the connection allows.
  - Each segment carries close to the max payload a single frame can hold
    (RX_BUF_SIZE=1536 in tcp_echo.tkb, minus 54 bytes of eth+ip+tcp
    headers), to maximize the compute (copy + checksum) done per exchange
    rather than per round trip.

Run as: python3 profile_tcp_burst_load.py NUM_SEGMENTS
"""
import os
import socket
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import tcp_echo_test as tet  # noqa: E402

PAYLOAD_LEN = 1400  # comfortably under RX_BUF_SIZE(1536) - 54 bytes of headers
CLIENT_PORT = 44000
CLIENT_ISN = 7000


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: profile_tcp_burst_load.py NUM_SEGMENTS", file=sys.stderr)
        return 1
    num_segments = int(sys.argv[1])

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind((tet.QEMU_HOST, tet.LOCAL_PORT))

    if not tet.do_handshake(sock, CLIENT_PORT, CLIENT_ISN):
        print("PROFILE_TCP_LOAD: handshake failed", file=sys.stderr)
        sock.close()
        return 1

    payload = bytes((i % 256) for i in range(PAYLOAD_LEN))
    seq = CLIENT_ISN + 1
    ack = tet.SERVER_ISN + 1
    ok_count = 0
    for _ in range(num_segments):
        frame = tet.build_frame(CLIENT_PORT, seq, ack, tet.FLAG_ACK | tet.FLAG_PSH, data=payload)
        reply = tet.send_and_wait(sock, frame)
        if reply is None:
            break
        tcp = reply[34:]
        _sp, _dp, rseq, rack, _doff, _flags = struct.unpack("!HHIIBB", tcp[0:14])
        rdata = tcp[20:]
        if rdata != payload:
            # Still counts as forward progress for load-generation purposes
            # (the server did the work regardless of what came back) -- see
            # do_request's docstring in http_server_test.py for the same
            # reasoning. Just don't trust rseq/rack below if this happened.
            pass
        else:
            ok_count += 1
        seq += PAYLOAD_LEN
        ack = rseq + len(rdata) if rdata else ack + PAYLOAD_LEN

    sock.close()
    print("PROFILE_TCP_LOAD: %d/%d segments echoed correctly" % (ok_count, num_segments),
          file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
