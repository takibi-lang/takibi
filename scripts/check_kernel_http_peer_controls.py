#!/usr/bin/env python3
"""Replay delayed HTTP replies through the real host peer's handshake filter."""

import contextlib
import importlib.util
import io
from pathlib import Path
import struct
import sys

from pass_line import report_pass

ROOT = Path(__file__).resolve().parent.parent
PEER_PATH = ROOT / "scripts/kernel_net_test.py"


def load_peer():
    spec = importlib.util.spec_from_file_location("http_peer_control", PEER_PATH)
    peer = importlib.util.module_from_spec(spec)
    saved = sys.argv
    try:
        sys.argv = [str(PEER_PATH), "100", "101"]
        spec.loader.exec_module(peer)
    finally:
        sys.argv = saved
    return peer


class Replies:
    def __init__(self, frames):
        self.frames = list(frames)

    def settimeout(self, _seconds):
        pass

    def sendto(self, _frame, _address):
        pass

    def recvfrom(self, _limit):
        if not self.frames:
            raise AssertionError("the peer asked for an unexpected reply")
        return self.frames.pop(0), ("127.0.0.1", 100)


def reply(peer, port, sequence, ack, flags, payload=b""):
    # Only the TCP tuple, sequence, flags and payload are consumed here.
    return bytes(34) + struct.pack(
        "!HHIIBBHHH", peer.HTTP_SERVER_PORT, port, sequence, ack,
        5 << 4, flags, 65535, 0, 0) + payload


def replay(peer, previous_port, current_port, current_isn, *, bad_flags=None):
    parts = (b"GET / HTTP/1.0\r\n", b"Host: 192.168.20.2\r\nConnection: close\r\n\r\n")
    frames = [
        # Exactly the failure shape: a prior request's delayed data reply
        # has ACK=1200+1+38, not the current handshake's expected ISN+1.
        reply(peer, previous_port, 100, 1239, peer.FLAG_ACK | peer.FLAG_PSH, b"old"),
        reply(peer, current_port, 500, current_isn + 1,
              peer.FLAG_SYN | peer.FLAG_ACK if bad_flags is None else bad_flags),
        reply(peer, current_port, 501, current_isn + 1 + len(parts[0]), peer.FLAG_ACK),
        reply(peer, current_port, 501, current_isn + 1 + sum(map(len, parts)), peer.FLAG_ACK),
        reply(peer, current_port, 501, current_isn + 1 + sum(map(len, parts)),
              peer.FLAG_ACK | peer.FLAG_FIN, b"fresh response"),
    ]
    output = io.StringIO()
    with contextlib.redirect_stdout(output):
        result = peer.raw_http_response(Replies(frames), current_port, current_isn, "/")
    return result, output.getvalue()


def main():
    peer = load_peer()
    # Fall back to the old layout so this control also faithfully rejects
    # the original peer, rather than failing because new names are missing.
    concurrent = getattr(peer, "HTTP_CONCURRENT_CLIENT_PORTS", peer.HTTP_CLIENT_PORTS[:2])
    fixture = getattr(peer, "HTTP_FIXTURE_CLIENT_PORTS", peer.HTTP_CLIENT_PORTS[:2])
    fixture_isns = getattr(peer, "HTTP_FIXTURE_CLIENT_ISNS", peer.HTTP_CLIENT_ISNS[:2])
    phases = ((concurrent[0], fixture[0], fixture_isns[0]),
              (fixture[0], peer.HTTP_CLIENT_PORTS[0], peer.HTTP_CLIENT_ISNS[0]))
    cases = 0
    for previous, current, isn in phases:
        result, diagnostic = replay(peer, previous, current, isn)
        assert result == b"fresh response", (
            "delayed prior-phase reply was mistaken for current SYN-ACK: " + diagnostic)
        cases += 1
    # A malformed reply for the current tuple must still fail; avoiding
    # old tuples must not weaken the actual protocol assertions.
    result, diagnostic = replay(peer, concurrent[0], fixture[0], fixture_isns[0],
                                bad_flags=peer.FLAG_ACK)
    assert result is None and "bad HTTP SYN-ACK" in diagnostic, diagnostic
    cases += 1
    result, diagnostic = replay(peer, fixture[0], fixture[0], fixture_isns[0])
    assert result is None and "flags=0x18 ack=1239" in diagnostic, diagnostic
    cases += 1
    ports = (*concurrent, *fixture, *peer.HTTP_CLIENT_PORTS)
    assert len(ports) == len(set(ports)), "HTTP phases reuse a TCP tuple"
    cases += 1
    report_pass("kernel-http peer controls", "delayed prior-phase data is skipped; malformed current handshakes fail", cases=cases)
    return 0


if __name__ == "__main__":
    sys.exit(main())
