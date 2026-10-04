#!/usr/bin/env python3
"""Check live RPi5 DDB timeline observations without changing its UART verdicts."""

import contextlib
import io
import json
from pathlib import Path
import tempfile
from unittest.mock import patch

import run_kernel_ddb_rpi5_driver as driver
from pass_line import CaseCount, report_pass

CASES = CaseCount()


def rows(path):
    return [json.loads(line) for line in path.read_text().splitlines()]


def main():
    with tempfile.TemporaryDirectory() as raw:
        root = Path(raw)
        now = [100.0]
        with patch.object(driver.time, 'monotonic', lambda: now[0]):
            CASES.note()
            path = root / 'await.jsonl'
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                timeline = driver.Timeline(10, str(path))
                now[0] = 105
                timeline.mark('first-prompt')
                assert 'await margin' not in output.getvalue()
                now[0] = 106
                timeline.mark('first-prompt')
                timeline.mark('continuing')
                now[0] = 110
                error = timeline.bail('original resume verdict')
            recorded = rows(path)
            assert len(recorded) == 4
            by_name = {row['await']: row for row in recorded}
            assert by_name['first-prompt']['elapsed_seconds'] == 5
            assert by_name['continuing']['fraction'] == 0.6
            assert by_name['resume-echoed']['status'] == 'not-arrived'
            assert by_name['wake-acked']['status'] == 'not-arrived'
            assert all(row['timeout_seconds'] == 10 and
                       row['budget_origin'] == 'DDB session start' for row in recorded)
            assert 'original resume verdict' in str(error)
            assert 'resume-echoed=never' in str(error)
            assert 'await margin' in output.getvalue()

            CASES.note()
            path = root / 'interrupted.jsonl'
            with contextlib.redirect_stdout(io.StringIO()):
                try:
                    with driver.Timeline(10, str(path)):
                        raise OSError('UART unavailable')
                except OSError as error:
                    assert str(error) == 'UART unavailable'
            assert len(rows(path)) == 4
            assert all(row['status'] == 'not-arrived' for row in rows(path))

            CASES.note()
            with contextlib.redirect_stdout(io.StringIO()):
                with driver.Timeline(10, str(root / 'absent/await.jsonl')) as timeline:
                    timeline.mark('first-prompt')
            assert timeline.at['first-prompt'] == 0

            CASES.note()
            archived = driver.Timeline(10)
            assert archived.timing is None
    report_pass('rpi5-ddb await controls', 'common phase budget, first arrival, half-budget '
                'boundary, missing milestones and unavailable UART/artifacts preserve verdicts',
                cases=CASES.ran)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
