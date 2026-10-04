#!/usr/bin/env python3
"""Run the common UART driver to check fixed connection and capture-ceiling observations."""

import contextlib
import io
import json
import math
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

        class UnavailableSerial(control.FakeSerial):
            def serial_for_url(self, url, **kwargs):
                raise self.SerialException('scripted connection refusal')

        (root / 'uart.log.await-timing.jsonl').write_text('stale capture\n')
        with patch.object(control, 'FakeSerial', UnavailableSerial), contextlib.redirect_stdout(io.StringIO()):
            outcome = control.drive(driver, TimedUart([]), root, timeout=8)
        assert 'could not open UART' in outcome.verdict
        connection = read(root / 'uart.log.connection-await.jsonl')
        assert connection[0]['status'] == 'not-arrived'
        assert connection[0]['timeout_seconds'] == 8
        assert not (root / 'uart.log.await-timing.jsonl').exists()

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
                'missing markers and DDB preserve original deadlines and verdicts', cases=CASES.ran)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
