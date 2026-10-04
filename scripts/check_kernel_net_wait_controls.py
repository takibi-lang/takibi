#!/usr/bin/env python3
"""Deterministic controls for QEMU readiness waits and their UART watchdog guard."""

import contextlib
import importlib.util
import io
from pathlib import Path
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
                "outer ceiling, finite watchdog guard and runner wiring hold",
                cases=CASES.ran)
    return 0


if __name__ == "__main__":
    sys.exit(main())
