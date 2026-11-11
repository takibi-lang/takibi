#!/usr/bin/env python3
"""Run the common UART driver to check fixed connection and capture-ceiling observations."""

import contextlib
import io
import json
import math
import runpy
import sys
from pathlib import Path
import tempfile
from unittest.mock import patch

import check_kernel_ddb_postmortem_controls as control
from pass_line import CaseCount, report_pass

CASES = CaseCount()


class TimedUart(control.FakeUart):
    def __init__(self, events):
        super().__init__(b'')
        self.events = list(events)
        self.started = None

    def read(self, size):
        if self.started is None:
            self.started = self.clock.monotonic()
        self.clock.sleep(self.READ_TIMEOUT)
        if self.events and round(self.clock.monotonic() - self.started, 6) >= self.events[0][0]:
            return self.events.pop(0)[1]
        return b''


def read(path):
    return [json.loads(line) for line in path.read_text().splitlines()]


def main():
    driver = control.load_driver()
    for events, arrived, elapsed in (
        ([(3, b'resources: pages=0\n')], True, 3),
        ([(4, control.BOOT_FIRST), (10, control.BOOT_FIRST),
          (16, control.BOOT_FIRST), (20, b'resources: pages=0\n')], True, 20),
        ([(4, b'resources: pages='), (10, b'0\n')], True, 10),
        ([], False, None),
    ):
        CASES.note()
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            with contextlib.redirect_stdout(io.StringIO()):
                outcome = control.drive(driver, TimedUart(events), root,
                                        timeout=8, ash_only=False)
            assert not outcome.verdict, outcome.verdict
            connection = read(root / 'uart.log.connection-await.jsonl')
            capture = read(root / 'uart.log.await-timing.jsonl')
            assert len(connection) == len(capture) == 1
            assert connection[0]['status'] == 'arrived'
            assert connection[0]['timeout_seconds'] == 8
            assert connection[0]['budget_origin'] == 'UART connection start'
            row = capture[0]
            assert row['timeout_seconds'] == 24
            assert row['budget_origin'] == 'capture ceiling (UART inactivity limit 8s)'
            assert (row['status'] == 'arrived') == arrived
            if arrived:
                assert math.isclose(row['elapsed_seconds'], elapsed), row
                assert math.isclose(row['fraction'], elapsed / 24)
            else:
                assert row['elapsed_seconds'] is None and row['fraction'] is None

    CASES.note()
    with tempfile.TemporaryDirectory() as raw:
        root = Path(raw)
        # The actual capture keeps receiving bytes through its outer ceiling,
        # but never reaches the prerequisites for sending the requested probe.
        uart = TimedUart([(at, control.BOOT_FIRST) for at in (4, 9, 14, 19, 23)])
        with contextlib.redirect_stdout(io.StringIO()):
            outcome = control.drive(driver, uart, root, timeout=8,
                                    ash_only=False, peer_settings=True)
        assert outcome.verdict, "an unstarted requested phase must fail"
        assert b"/bin/peer-settings" not in outcome.commands, outcome.commands
        assert "was not sent" in outcome.verdict, outcome.verdict
        assert "send prerequisites" in outcome.verdict, outcome.verdict
        assert "outer capture ceiling 24s reached" in outcome.verdict, outcome.verdict
        assert "#657" not in outcome.verdict, outcome.verdict
        assert "characters missing" not in outcome.verdict, outcome.verdict
        assert "24s budget" in outcome.verdict, outcome.verdict
        assert math.isclose(outcome.elapsed, 24, abs_tol=0.11), outcome.elapsed
        capture = read(root / "uart.log.await-timing.jsonl")
        assert capture[-1]["status"] == "not-arrived", capture

        # Prove the actual CLI still exits nonzero as well as naming the
        # unstarted phase. The clock and UART stay entirely in this process.
        CASES.note()
        clock = control.Clock()
        endpoint = TimedUart([(at, control.BOOT_FIRST)
                              for at in (4, 9, 14, 19, 23)])
        endpoint.clock = clock
        serial = control.FakeSerial(endpoint)
        argv = [str(control.DRIVER), "--port", "socket://127.0.0.1:1",
                "--log", str(root / "cli-uart.log"),
                "--stdin", str(root / "ash.stdin"),
                "--expected", str(root / "ash.expected"),
                "--timeout", "8", "--peer-settings"]
        output = io.StringIO()
        status = 0
        with contextlib.redirect_stdout(output), patch("sys.argv", argv), \
                patch("serial.serial_for_url", serial.serial_for_url), \
                patch("time.monotonic", clock.monotonic), \
                patch("time.sleep", clock.sleep):
            try:
                runpy.run_path(str(control.DRIVER), run_name="__main__")
            except SystemExit as error:
                status = error.code
        assert status == 1, status
        assert "was not sent" in output.getvalue(), output.getvalue()
        assert "outer capture ceiling 24s reached" in output.getvalue(), output.getvalue()
        assert "#657" not in output.getvalue(), output.getvalue()
        assert b"/bin/peer-settings" not in endpoint.commands, endpoint.commands

    CASES.note()
    with tempfile.TemporaryDirectory() as raw:
        root = Path(raw)
        with contextlib.redirect_stdout(io.StringIO()):
            outcome = control.drive(
                driver, control.FakeUart(control.BOOT_FIRST + control.BOOT_LAST),
                root, timeout=8, ash_only=False)
        assert not outcome.verdict, outcome.verdict
        assert b"/bin/peer-settings" not in outcome.commands, outcome.commands
        assert b"/bin/peer-tty" not in outcome.commands, outcome.commands

    CASES.note()
    with tempfile.TemporaryDirectory() as raw:
        root = Path(raw)

        class UnavailableSerial(control.FakeSerial):
            def serial_for_url(self, url, **kwargs):
                raise self.SerialException('scripted connection refusal')

        stale = [root / name for name in ('uart.log', 'uart.log.normalized',
                                          'uart-timing.log')]
        for path in stale:
            path.write_text('previous boot, not this attempt\n')
        (root / 'uart.log.await-timing.jsonl').write_text('stale capture\n')
        with patch.object(control, 'FakeSerial', UnavailableSerial), contextlib.redirect_stdout(io.StringIO()):
            outcome = control.drive(driver, TimedUart([]), root, timeout=8)
        assert 'could not open UART' in outcome.verdict
        connection = read(root / 'uart.log.connection-await.jsonl')
        assert connection[0]['status'] == 'not-arrived'
        assert connection[0]['timeout_seconds'] == 8
        assert not (root / 'uart.log.await-timing.jsonl').exists()
        # Exercise the actual CLI exit path too, without wall-clock waits.
        # A diagnostic alone must not disguise an accidental successful exit.
        for path in stale:
            path.write_text('previous boot, not this attempt\n')
        argv = [str(control.DRIVER), '--port', 'socket://127.0.0.1:1',
                '--log', str(root / 'uart.log'),
                '--timing-log', str(root / 'uart-timing.log'),
                '--stdin', str(root / 'ash.stdin'),
                '--expected', str(root / 'ash.expected'), '--timeout', '8']
        output = io.StringIO()
        with patch.dict(sys.modules, {'serial': UnavailableSerial(TimedUart([])),
                                      'time': control.Clock()}), \
                patch.object(sys, 'argv', argv), contextlib.redirect_stdout(output):
            status = 0
            try:
                runpy.run_path(str(control.DRIVER), run_name='__main__')
            except SystemExit as error:
                status = error.code
        assert status == 1, status
        assert 'could not open UART' in output.getvalue(), output.getvalue()
        assert all(not path.exists() for path in stale), stale

    CASES.note()
    with tempfile.TemporaryDirectory() as raw:
        root = Path(raw)
        with contextlib.redirect_stdout(io.StringIO()):
            outcome = control.drive(driver, control.FakeUart(control.BOOT_FIRST,
                                    driver.DDB_PROMPT), root, timeout=8)
        assert 'stopped at a DDB prompt' in outcome.verdict
        capture = read(root / 'uart.log.await-timing.jsonl')
        assert capture[0]['await'] == 'capture marker: busybox interactive shell exit: 0'
        assert capture[0]['status'] == 'not-arrived'
        assert capture[0]['timeout_seconds'] == 24
    report_pass('uart-await controls', 'connection budget, capture ceiling, late progress, '
                'unstarted requested probes, missing markers and DDB preserve '
                'original deadlines and verdicts', cases=CASES.ran)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
