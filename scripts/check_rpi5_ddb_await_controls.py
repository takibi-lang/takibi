#!/usr/bin/env python3
"""Check live RPi5 DDB timeline observations without changing its UART verdicts."""

import contextlib
import io
import json
import os
from pathlib import Path
import tempfile
from types import SimpleNamespace
from unittest.mock import patch

import run_kernel_ddb_rpi5_driver as driver
import run_kernel_ddb_rpi5_software_driver as software
from pass_line import CaseCount, report_pass

CASES = CaseCount()


def rows(path):
    return [json.loads(line) for line in path.read_text().splitlines()]


def software_case(*, first=1.0, release=1.0, echo_only=False, unavailable=False):
    CASES.note()
    with tempfile.TemporaryDirectory() as raw:
        root = Path(raw)
        args = SimpleNamespace(port="fixture", log=str(root / "uart"), timeout=8.0,
                               generated_start=0x1000, generated_end=0x2000,
                               snapshot_ready_file=str(root / "ready"),
                               snapshot_release_file=str(root / "release"))
        (root / "uart.await-commands.jsonl").write_text("stale\n")
        now = [0.0]
        sent = []

        class UART:
            def __init__(self):
                self.first_sent = False
                self.line = bytearray()
                self.queue = []

            def __enter__(self):
                return self

            def __exit__(self, *_):
                pass

            def read(self, _):
                now[0] = round(now[0] + 0.25, 8)
                if (root / "ready").exists() and now[0] >= release:
                    (root / "release").touch()
                if first is not None and not self.first_sent and now[0] >= first:
                    self.first_sent = True
                    return b"ddb: intr cpu=0 entry=brk source=21579 live_daif=0x3c0\nddb> "
                return self.queue.pop(0) if self.queue else b""

            def write(self, byte):
                if byte != b"\n":
                    self.line.extend(byte)
                    return 1
                command = bytes(self.line)
                self.line.clear()
                sent.append(command)
                if command == b"continue":
                    answer = b"ddb: continuing\n" + b"ddb: console tx=queued\n" + b" # \x1b[6n"
                elif command == b"echo ddb-software-resume-ok":
                    answer = (b"echo ddb-software-resume-ok\n # " if echo_only else
                              b"\nddb-software-resume-ok\n # ")
                elif command == b"bt":
                    answer = (b"ddb: bt frame=0 pc=0x1100 boundary=assembly-bridge\n"
                              b"ddb: bt frame=1 pc=0x1100 fp=0x3000\n"
                              b"ddb: bt frame=2 pc=0x2100 fp=0x3010 boundary=assembly\n"
                              b"ddb: bt stop=assembly-boundary fp=0x3010\nddb> ")
                else:
                    answer = b"ddb> "
                self.queue.append(b"\n" + answer)
                return 1

            def flush(self):
                pass

        def sleep(seconds):
            now[0] = round(now[0] + seconds, 8)

        def connect(*_, **__):
            if unavailable:
                raise OSError("UART unavailable")
            return UART()

        output = io.StringIO()
        with patch.dict(os.environ, {}, clear=True), \
                patch.object(software.time, "monotonic", lambda: now[0]), \
                patch.object(software.time, "sleep", sleep), \
                patch.object(software.serial, "Serial", connect), \
                contextlib.redirect_stdout(output):
            try:
                result = software.drive(args)
            except (OSError, SystemExit) as error:
                result = str(error)
        boot = rows(root / "uart.await-boot.jsonl")
        assert len(boot) == 1 and boot[0]["timeout_seconds"] == 8.0, boot
        command_path = root / "uart.await-commands.jsonl"
        if unavailable or first is None:
            assert boot[0]["status"] == "not-arrived" and not command_path.exists(), boot
            assert result == ("UART unavailable" if unavailable else
                              "RPi5 DDB did not enter through reserved software BRK"), result
        else:
            command_rows = rows(command_path)
            assert len(command_rows) == 13, command_rows
            assert all(row["timeout_seconds"] <= 8.0 for row in command_rows), command_rows
            assert all("snapshot released" in row["budget_origin"] for row in command_rows), command_rows
            assert sent[-1] == b"echo ddb-software-resume-ok", sent
            if release > first:
                assert boot[0]["elapsed_seconds"] < release, boot
            by_name = {row["await"]: row for row in command_rows}
            assert by_name["resume result"]["status"] == ("not-arrived" if echo_only else "arrived")
            if echo_only:
                assert result == "RPi5 shell did not resume in the same boot", result
            else:
                assert result == 0 and all(row["status"] == "arrived" for row in command_rows), result
            if first > 4.0:
                assert "await margin" in output.getvalue(), output.getvalue()
        return now[0]


def main():
    software_case()
    software_case(first=5.0, release=5.0)
    assert software_case(release=20.0) > 20.0
    software_case(echo_only=True)
    software_case(first=None)
    software_case(unavailable=True)
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
