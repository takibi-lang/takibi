#!/usr/bin/env python3
"""Deterministic controls for peer readiness, bounded ACK replay and its watchdog."""

import contextlib
import importlib.util
import io
from pathlib import Path
import struct
import sys
import tempfile

from pass_line import CaseCount, report_pass

ROOT = Path(__file__).resolve().parent.parent
CASES = CaseCount()


def load_peer(argv):
    spec = importlib.util.spec_from_file_location(
        "kernel_net_wait_control", ROOT / "scripts/kernel_net_test.py")
    module = importlib.util.module_from_spec(spec)
    saved = sys.argv
    try:
        sys.argv = argv
        spec.loader.exec_module(module)
    finally:
        sys.argv = saved
    return module


class Clock:
    def __init__(self, events):
        self.now = 0.0
        self.events = sorted(events, key=lambda event: event[0])

    def monotonic(self):
        return self.now

    def sleep(self, seconds):
        self.now = round(self.now + seconds, 8)
        while self.events and self.events[0][0] <= self.now:
            _, action = self.events.pop(0)
            action()


class ClosingPeer:
    """Fake transport: a new-port SYN gets no reply until the old ACK arrives.

    The real peer builds and checks every packet. This socket only supplies
    server replies and deterministic loss; it never waits or opens a socket.
    """

    def __init__(self, peer, lost_acks=0, *, no_reply=False, bad_reply=False,
                 no_fin=False, bad_fin=False, closing_reply=False):
        self.peer = peer
        self.lost_acks = lost_acks
        self.no_reply, self.bad_reply = no_reply, bad_reply
        self.no_fin, self.bad_fin = no_fin, bad_fin
        self.closing_reply = closing_reply
        self.state = "established"
        self.sent, self.pending, self.timeouts = [], [], []
        self.acks = 0
        self.old_isn, self.new_isn = 10000, 20000
        peer.SERVER_ISNS[peer.HANDSHAKE_CLIENT_PORT] = self.old_isn
        client_seq = peer.HANDSHAKE_CLIENT_ISN + 1 + len(peer.DATA_ECHO_PAYLOAD)
        server_seq = peer.seq_add(self.old_isn, 1 + len(peer.DATA_ECHO_PAYLOAD))
        self.fin = peer.build_tcp_frame(peer.HANDSHAKE_CLIENT_PORT, client_seq,
                                        server_seq, peer.FLAG_FIN | peer.FLAG_ACK)
        self.ack = peer.build_tcp_frame(peer.HANDSHAKE_CLIENT_PORT, client_seq + 1,
                                        server_seq + 1, peer.FLAG_ACK)
        self.fin_reply = self.reply(peer.HANDSHAKE_CLIENT_PORT, server_seq,
                                    client_seq + 1, peer.FLAG_FIN | peer.FLAG_ACK)
        self.syn = peer.build_tcp_frame(peer.RECONNECT_CLIENT_PORT,
                                        peer.RECONNECT_CLIENT_ISN, 0, peer.FLAG_SYN)

    def reply(self, port, seq, ack, flags, data=b""):
        peer = self.peer
        frame = bytearray(peer.build_tcp_frame(port, seq, ack, flags, data))
        frame[:6], frame[6:12] = peer.CLIENT_MAC, peer.SERVER_MAC
        frame[26:30], frame[30:34] = peer.SERVER_IP, peer.CLIENT_IP
        frame[34:38] = struct.pack("!HH", peer.SERVER_PORT, port)
        # Swapping the address/port pairs preserves the checksum sums.
        return bytes(frame)

    def sendto(self, frame, destination):
        peer = self.peer
        assert destination == (peer.QEMU_HOST, peer.QEMU_PORT)
        self.sent.append((frame, destination))
        if frame == self.fin:
            if not self.no_fin:
                self.state = "last-ack"
                reply = bytearray(self.fin_reply)
                if self.bad_fin:
                    reply[-1] ^= 1  # Invalid checksum: real test_close must reject it.
                self.pending.append(bytes(reply))
        elif frame == self.ack:
            self.acks += 1
            if self.lost_acks is not None and self.acks > self.lost_acks:
                self.state = "listen"
            if self.closing_reply:
                self.pending.append(b"unexpected closing reply")
        elif frame == self.syn and self.state == "listen" and not self.no_reply:
            ack = peer.RECONNECT_CLIENT_ISN + (2 if self.bad_reply else 1)
            self.pending.append(self.reply(peer.RECONNECT_CLIENT_PORT,
                                           self.new_isn, ack,
                                           peer.FLAG_SYN | peer.FLAG_ACK))
        return len(frame)

    def settimeout(self, seconds):
        self.timeouts.append(seconds)

    def recvfrom(self, _size):
        if self.pending:
            return self.pending.pop(0), (self.peer.QEMU_HOST, self.peer.QEMU_PORT)
        raise self.peer.socket.timeout()


def closing_ack_controls():
    def setup(*args, **kwargs):
        peer = load_peer(["peer", "100", "101"])
        assert peer.RETRIES == 30 and peer.RETRY_TIMEOUT_SECS == 0.5
        return peer, ClosingPeer(peer, *args, **kwargs)

    # The original no-replay path fails after a lost final ACK. Replaying
    # before every bounded SYN also recovers if the first replay is lost.
    for losses, replay, success, attempts in (
        (0, False, True, 1), (1, False, False, 30),
        (1, True, True, 1), (2, True, True, 2),
        (None, True, False, 30),
    ):
        CASES.note()
        peer, sock = setup(losses)
        close_ok, ack = peer.test_close(sock)
        assert close_ok and ack == sock.ack
        assert sock.sent == [(sock.fin, (peer.QEMU_HOST, peer.QEMU_PORT)),
                             (sock.ack, (peer.QEMU_HOST, peer.QEMU_PORT))]
        start = len(sock.sent)
        if replay:
            result = peer.do_handshake(sock, peer.RECONNECT_CLIENT_PORT,
                                       peer.RECONNECT_CLIENT_ISN, ack)
        else:
            result = peer.do_handshake(sock, peer.RECONNECT_CLIENT_PORT,
                                       peer.RECONNECT_CLIENT_ISN)
        assert result is success, (losses, replay, result)
        sequence = [frame for frame, _ in sock.sent[start:]]
        expected = ([ack, sock.syn] if replay else [sock.syn]) * attempts
        if success:
            expected.append(peer.build_tcp_frame(peer.RECONNECT_CLIENT_PORT,
                                                 peer.RECONNECT_CLIENT_ISN + 1,
                                                 sock.new_isn + 1, peer.FLAG_ACK))
        assert sequence == expected
        assert sock.timeouts == ([peer.RETRY_TIMEOUT_SECS,
                                  peer.SILENCE_TIMEOUT_SECS] +
                                 [peer.RETRY_TIMEOUT_SECS] * attempts +
                                 ([peer.SILENCE_TIMEOUT_SECS] if success else []))

    # Replay cannot turn a missing or invalid SYNACK into success, or relax
    # the FIN checks before an ACK may be retained.
    for options, attempts in (({"no_reply": True}, 30), ({"bad_reply": True}, 1)):
        CASES.note()
        peer, sock = setup(1, **options)
        close_ok, ack = peer.test_close(sock)
        assert close_ok
        assert not peer.do_handshake(sock, peer.RECONNECT_CLIENT_PORT,
                                     peer.RECONNECT_CLIENT_ISN, ack)
        assert [frame for frame, _ in sock.sent[2:]] == [ack, sock.syn] * attempts
    for options, attempts in (({"no_fin": True}, 30), ({"bad_fin": True}, 1)):
        CASES.note()
        peer, sock = setup(**options)
        assert peer.test_close(sock) == (False, None)
        assert [frame for frame, _ in sock.sent] == [sock.fin] * attempts

    CASES.note()
    peer, sock = setup(closing_reply=True)
    assert peer.test_close(sock) == (False, sock.ack)
    assert [frame for frame, _ in sock.sent] == [sock.fin, sock.ack]

    # Default send/handshake/data paths never replay an unrelated ACK.
    CASES.note()
    peer, sock = setup()
    peer.SERVER_ISNS.clear()
    sock.pending.append(sock.reply(peer.HANDSHAKE_CLIENT_PORT, sock.old_isn,
                                    peer.HANDSHAKE_CLIENT_ISN + 1,
                                    peer.FLAG_SYN | peer.FLAG_ACK))
    assert peer.do_handshake(sock, peer.HANDSHAKE_CLIENT_PORT,
                             peer.HANDSHAKE_CLIENT_ISN)
    assert len(sock.sent) == 2 and sock.ack not in [f for f, _ in sock.sent]
    sock.pending.append(sock.reply(peer.HANDSHAKE_CLIENT_PORT, sock.old_isn + 1,
                                    peer.HANDSHAKE_CLIENT_ISN + 1 +
                                    len(peer.DATA_ECHO_PAYLOAD), peer.FLAG_ACK | peer.FLAG_PSH,
                                    peer.DATA_ECHO_PAYLOAD))
    start = len(sock.sent)
    assert peer.test_data_echo(sock)
    assert len(sock.sent) == start + 1
    payload = b"unrelated caller"
    sock.pending.append(b"reply")
    assert peer.send_and_wait(sock, payload) == b"reply"
    assert sock.sent[-1] == (payload, (peer.QEMU_HOST, peer.QEMU_PORT))


def run(events, *, initial=False, tracked=True, immediate=False):
    CASES.note()
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        uart, marker, guard = (root / name for name in ("uart", "ready", "guard"))
        if initial:
            uart.write_bytes(b"old")
        if immediate:
            marker.touch()
        actions = []
        for at, kind in events:
            if kind == "marker":
                action = marker.touch
            elif kind == "bytes":
                def action():
                    with uart.open("ab") as capture:
                        capture.write(b"x")
            elif kind == "touch":
                action = uart.touch
            elif kind == "truncate":
                action = lambda: uart.write_bytes(b"")
            elif kind == "replace":
                def action():
                    replacement = root / "replacement"
                    replacement.write_bytes(b"old")
                    replacement.replace(uart)
            else:
                raise AssertionError(kind)
            actions.append((at, action))
        clock = Clock(actions)
        peer = load_peer(["peer", "100", "101", "--uart-progress-file", str(uart)])
        assert (peer.QEMU_PORT, peer.LOCAL_PORT) == (100, 101)
        assert peer.UART_PROGRESS_FILE == uart
        peer.time = clock
        peer.STARTED_AT = 0.0
        peer.MARKER_BUDGET_SECONDS = 8.0
        peer.OUTER_BUDGET_SECONDS = 30.0
        peer.MARKER_SAFETY_SECONDS = 2.0
        peer.HTTPD_GUARD_FILE = guard
        if not tracked:
            peer.UART_PROGRESS_FILE = None
        deadlines = []
        publish = peer.guard_httpd_peer

        def guard_wait(seconds):
            publish(seconds)
            deadlines.append(float(guard.read_text()))

        peer.guard_httpd_peer = guard_wait
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            status = peer.wait_for_marker(marker, "test listener")
        return status, clock.now, deadlines, output.getvalue()


def main():
    closing_ack_controls()
    for events, options, success, elapsed, diagnostic in (
        ([], {"immediate": True}, True, 0.0, ""),
        ([(3.0, "marker")], {}, True, 3.0, ""),
        ([(4.0, "bytes"), (10.0, "bytes"), (16.0, "bytes"),
          (20.0, "marker")], {}, True, 20.0, ""),
        ([], {}, False, 8.0, "no UART progress for 8.0s"),
        ([(4.0, "bytes")], {}, False, 12.0, "no UART progress for 8.0s"),
        ([(4.0, "touch")], {"initial": True}, False, 8.0,
         "no UART progress for 8.0s"),
        ([(4.0, "touch")], {}, False, 8.0, "no UART progress for 8.0s"),
        ([(at, "bytes") for at in range(4, 40, 4)], {}, False, 28.0,
         "outer ceiling reached"),
        ([(4.0, "replace"), (11.0, "marker")], {"initial": True},
         True, 11.0, ""),
        ([(4.0, "truncate")], {"initial": True}, False, 8.0,
         "no UART progress for 8.0s"),
        ([(4.0, "truncate"), (5.0, "bytes"), (11.0, "marker")],
         {"initial": True}, True, 11.0, ""),
        ([(4.0, "bytes"), (10.0, "marker")], {"tracked": False},
         False, 8.0, "no UART progress for 8.0s"),
    ):
        status, now, guards, output = run(events, **options)
        assert status == success and now == elapsed, (events, status, now, output)
        assert diagnostic in output, output
        if not options.get("immediate"):
            assert guards and guards[0] == 8.0 and max(guards) <= 28.0, guards
        assert guards == sorted(set(guards)), guards

    # Exercise the real watchdog predicate: the planned wait suppresses a
    # premature BREAK, then its finite expiry permits the original DDB walk.
    CASES.note()
    spec = importlib.util.spec_from_file_location(
        "uart_wait_control", ROOT / "scripts/run_kernel_uart_driver.py")
    driver = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(driver)
    assert not driver.postmortem_break_due(7.5, 9.0, 0.0, 8.0, 8.0)
    assert driver.postmortem_break_due(8.1, 9.0, 0.0, 8.0, 8.0)

    # Every maintained peer invocation must observe the capture its UART
    # driver actually writes, including the ash lane's existing override.
    for name, argument in (
        ("run_kernel_qemutest.sh", '"$UART_LOG"'),
        ("run_kernel_alloc_rollback_qemutest.sh", '"$UART_LOG"'),
        ("run_kernel_ddb_qemutest.sh", '"$UART_LOG"'),
        ("run_kernel_ash_qemutest.sh",
         '"${KERNEL_QEMU_ASH_UART_LOG:-$ARTIFACT_DIR/uart.log}"'),
        ("run_kernel_affinity_gdb_qemutest.sh", '"$ARTIFACT_DIR/uart.log"'),
        ("run_kernel_uart_wake_qemutest.sh", '"$ARTIFACT_DIR/uart.log"'),
    ):
        CASES.note()
        text = (ROOT / "scripts" / name).read_text()
        assert text.count("--uart-progress-file " + argument) == 1, name
    # Both sides must share the finite wait guard: otherwise the UART driver
    # asks for BREAK while the network peer is still legitimately waiting.
    for name in ("run_kernel_qemutest.sh",
                 "run_kernel_alloc_rollback_qemutest.sh"):
        CASES.note()
        text = (ROOT / "scripts" / name).read_text()
        assert text.count('--httpd-peer-guard-file "$HTTPD_GUARD_FILE"') == 2, name
        assert '"$HTTPD_GUARD_FILE" "$POSTMORTEM_REQUEST"' in text, name
    report_pass("kernel-net readiness controls",
                "guest bytes renew waits; touches and silence do not; the "
                "outer ceiling, watchdog and wiring hold; closing ACK replay "
                "keeps the reconnect retry bounds and reply checks",
                cases=CASES.ran)
    return 0


if __name__ == "__main__":
    sys.exit(main())
