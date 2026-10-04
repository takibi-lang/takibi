#!/usr/bin/env python3
"""Drive real crash-console await measurement with a deterministic clock.

Scripted socket observations exercise arrival, split/interleaved markers,
connection delay, timeout, and command gating without a guest or wall time.
"""

import contextlib
import importlib.util
import io
import json
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace

from pass_line import CaseCount, report_pass

ROOT = Path(__file__).resolve().parent.parent
CASES = CaseCount()


class Clock:
    def __init__(self):
        self.now = 1000.0

    def monotonic(self):
        return self.now

    def sleep(self, seconds):
        self.now += seconds


class ReadTimeout(Exception):
    pass


class Socket:
    def __init__(self, clock, events, reply_delay):
        self.clock = clock
        self.events = [(clock.now + at, chunk) for at, chunk in events]
        self.reply_delay = reply_delay
        self.sent = []
        self.timeout = 0.25

    def __enter__(self):
        return self

    def __exit__(self, *args):
        pass

    def settimeout(self, timeout):
        self.timeout = timeout

    def recv(self, count):
        until = self.clock.now + self.timeout
        if self.events and self.events[0][0] <= until:
            at, chunk = self.events.pop(0)
            self.clock.now = max(self.clock.now, at)
            return chunk
        self.clock.now = until
        raise ReadTimeout()

    def sendall(self, command):
        self.sent.append((command, self.clock.now - 1000.0))
        if self.reply_delay is not None:
            self.events.append((self.clock.now + self.reply_delay, b"reply\nddb> "))
            self.events.sort()


def run(events, *, timeout=10.0, connect_delay=0.0, connect_failure=False,
        awaited=("FIRST", "SECOND"), reply_delay=0.25, timing=True, unavailable=False):
    CASES.note()
    spec = importlib.util.spec_from_file_location("crash_console", ROOT / "scripts/run_kernel_crash_console.py")
    driver = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(driver)
    clock = Clock()
    endpoint = Socket(clock, events, reply_delay)

    def connect(address, budget):
        clock.sleep(budget if connect_failure else connect_delay)
        if connect_failure:
            raise OSError("refused")
        return endpoint

    driver.time = clock
    driver.socket = SimpleNamespace(create_connection=connect, timeout=ReadTimeout)
    output = io.StringIO()
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        path = root / "await.jsonl"
        if unavailable:
            path = root / "absent/await.jsonl"
        arguments = ["crash-console", "--port", "1", "--log", str(root / "uart.log"),
                     "--timeout", str(timeout)]
        for line in awaited:
            arguments += ["--await-line", line]
        if timing:
            arguments += ["--await-timing-log", str(path)]
        saved = sys.argv
        try:
            sys.argv = arguments
            with contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
                try:
                    status = driver.main()
                except SystemExit as error:
                    status = str(error)
        finally:
            sys.argv = saved
        rows = [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []
    return status, rows, endpoint.sent, clock.now - 1000.0, output.getvalue()


def require(condition, message):
    if not condition:
        raise SystemExit("FAIL oops await timing controls: " + message)


def main():
    CASES.note()
    runner = (ROOT / "scripts/run_kernel_oops_qemutest.sh").read_text(encoding="ascii")
    require('--await-timing-log "$ARTIFACT_DIR/await-timing.jsonl"' in runner,
            "the real oops runner does not request the artifact beside its UART capture")
    for at, warned in ((2.0, False), (5.0, False), (6.0, True)):
        status, rows, sent, elapsed, output = run([(at, b"FIRST\nSECOND\nddb> ")], reply_delay=0.0)
        require(status == 0, "measurement changed a passing lane")
        require(len(rows) == 8 and len({row['await'] for row in rows}) == 8,
                "missing or duplicate arrival records")
        require(all(row['status'] == 'arrived' and row['timeout_seconds'] == 10.0
                    and row['budget_origin'] == 'driver start' for row in rows), "common timeout lost")
        first = next(row for row in rows if row['await'] == 'await-line 1')
        require(first['elapsed_seconds'] == at and first['fraction'] == at / 10.0,
                "elapsed time or budget fraction is wrong")
        require(('await margin:' in output) == warned, "half-budget boundary was not respected")
        require([command for command, _ in sent] == [b"oops\n", b"trace\n", b"ps\n", b"proc 1\n"],
                "measurement changed console commands")
    status, rows, sent, elapsed, output = run([
        (2.0, b"FI"), (3.0, b"ddb> RST\n"), (6.0, b"SECOND\n")], connect_delay=1.0)
    require(status == 0 and sent[0][1] == 6.0, "the first command did not wait for both reports")
    arrivals = {row['await']: row['elapsed_seconds'] for row in rows}
    require(arrivals['UART connection'] == 1.0 and arrivals['await-line 1'] == 3.0
            and arrivals['await-line 2'] == 6.0 and arrivals['console prompt 1'] == 3.0,
            "split markers, interleaved prompts, or connection time were misattributed")
    status, rows, sent, elapsed, output = run([(2.0, b"ddb> ")], awaited=())
    require(status == 0 and len(rows) == 6, "ordinary oops modes lost their prompt measurements")
    for options, diagnosis in (
            ({'events': [(2.0, b"FIRST\nddb> ")]}, "never saw 'SECOND'"),
            ({'events': [], 'connect_failure': True}, "did not accept a connection"),
            ({'events': [(2.0, b"FIRST\nSECOND\nddb> ")], 'reply_delay': None}, "did not complete all commands"),
            ({'events': [(2.0, b"")]}, "never saw 'FIRST'")):
        status, rows, sent, elapsed, output = run(**options)
        require(isinstance(status, str) and diagnosis in status, "original failure diagnosis lost")
        require(len(rows) == 8 and any(row['status'] == 'not-arrived' for row in rows),
                "unfinished awaits were not retained")
        require(all(row['elapsed_seconds'] is None and row['fraction'] is None
                    for row in rows if row['status'] == 'not-arrived'), "timeout recorded as an arrival")
        require(all(row['observed_seconds'] == elapsed for row in rows
                    if row['status'] == 'not-arrived'), "unfinished observations used another clock")
        require(elapsed <= 10.55, "measurement restarted or extended the deadline")
    status, rows, sent, elapsed, output = run([(2.0, b"FIRST\nSECOND\nddb> ")], unavailable=True)
    require(status == 0 and 'timing unavailable' in output, "artifact failure replaced the lane verdict")
    status, rows, sent, elapsed, output = run([(2.0, b"FIRST\nSECOND\nddb> ")], timing=False)
    require(status == 0 and not rows, "an older invocation required a timing artifact")
    report_pass("oops await timing controls", "arrival times include connection and boot, partial markers and prompt gating retain the common deadline, tight budgets are recorded, and failures retain unfinished awaits and their original verdict", cases=CASES.ran)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
