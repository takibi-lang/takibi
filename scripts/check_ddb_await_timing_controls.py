#!/usr/bin/env python3
"""Deterministic arrival-budget controls for the real QEMU DDB driver."""

import contextlib
import importlib.util
import io
import json
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace

from check_oops_await_timing_controls import Clock, Socket, ReadTimeout
from pass_line import CaseCount, report_pass

ROOT = Path(__file__).resolve().parent.parent
CASES = CaseCount()


class DdbSocket(Socket):
    def sendall(self, command):
        self.sent.append((command, self.clock.now - 1000.0))
        if self.reply_delay is None:
            return
        reply = ((b"ddb: continuing\r\n" + b"init: ash bootstrap\r\n") if command == b"continue\n"
                 else b"reply\nddb> ")
        self.events.append((self.clock.now + self.reply_delay, reply))
        self.events.sort()


def run(*, at=2.0, source='software', stalled=False, unanswered=False,
        connect_failure=False, unavailable=False, progress=()):
    CASES.note()
    spec = importlib.util.spec_from_file_location('ddb_driver', ROOT / 'scripts/run_kernel_ddb_driver.py')
    driver = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(driver)
    clock = Clock()
    events = [] if stalled or connect_failure else [(at, b'ddb'), (at + 0.25, b'> ')]
    events.extend((second, b'boot progress\n') for second in progress)
    events.sort()
    serial = DdbSocket(clock, events,
                       None if unanswered else 0.0)

    def connect(address, timeout):
        if connect_failure:
            clock.sleep(timeout)
            raise OSError('refused')
        return serial

    def break_in(*args):
        serial.events.append((clock.now + 0.25, b'ddb> '))
        return ''

    driver.time = clock
    driver.socket = SimpleNamespace(create_connection=connect, timeout=ReadTimeout)
    driver.sample_cpu_registers = lambda *args: ('sample', 'sample')
    driver.send_serial_break = break_in
    output = io.StringIO()
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        path = root / 'await.jsonl' if not unavailable else root / 'absent/await.jsonl'
        arguments = ['ddb', '--serial-port', '1', '--qmp-port', '2', '--kernel-address', '4000',
                     '--log', str(root / 'uart.log'), '--timeout', '10', '--break-source', source,
                     '--network-ready-file', str(root / 'net'), '--foreground-listener-file', str(root / 'fg'),
                     '--init-listener-file', str(root / 'init'), '--await-timing-log', str(path)]
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
        post = Path(str(path) + '.postmortem')
        post_rows = [json.loads(line) for line in post.read_text().splitlines()] if post.exists() else []
    return status, rows, post_rows, serial.sent, clock.now - 1000.0, output.getvalue()


def require(condition, message):
    if not condition:
        raise SystemExit('FAIL ddb await timing controls: ' + message)


def main():
    CASES.note()
    runner = (ROOT / 'scripts/run_kernel_ddb_qemutest.sh').read_text()
    require('--await-timing-log "$ARTIFACT_DIR/await-timing.jsonl"' in runner,
            'live runner lost its artifact')
    require(all(setting in runner for setting in (
        'CEILING_SECS="$((TIMEOUT_SECS * 3))"',
        'KERNEL_QEMU_TIMEOUT="$TIMEOUT_SECS" KERNEL_QEMU_CEILING="$CEILING_SECS"',
        'KERNEL_PEER_EXIT_TIMEOUT="$CEILING_SECS"',
        'seq 1 "$((CEILING_SECS * 10))"')),
        'a runner helper still stops before the progressing capture ceiling')
    for at, margin, progress in ((2.0, False, ()), (20.0, True, (5, 10, 15))):
        status, rows, post, sent, elapsed, output = run(at=at, progress=progress)
        require(status == 0 and not post, 'measurement changed a passing software BREAK')
        require(len(rows) == len(sent) + 3 and all(row['status'] == 'arrived' for row in rows),
                'a normal capture lost awaits or expected a prompt after continue')
        require(all(row['timeout_seconds'] == 30.0 and row['budget_origin'] ==
                    'capture ceiling (UART inactivity limit 10s)' for row in rows),
                'capture observations lost the ceiling and inactivity budget')
        prompt = next(row for row in rows if row['await'] == 'console prompt 1')
        require(prompt['elapsed_seconds'] == at + 0.25, 'split prompt arrival was recorded early')
        require(('await margin:' in output) == margin, 'tight timeout was not recorded')
        require(sent[-1][0] == b'continue\n', 'continue was not the final command')
    status, rows, post, sent, elapsed, output = run(unanswered=True)
    require(isinstance(status, str) and 'sequence did not complete' in status
            and any(row['status'] == 'not-arrived' for row in rows) and 12 <= elapsed <= 12.5,
            'missing replies did not exhaust the renewed inactivity budget')
    status, rows, post, sent, elapsed, output = run(stalled=True, progress=range(1, 40))
    require(isinstance(status, str) and 'sequence did not complete' in status
            and 30 <= elapsed <= 30.25,
            'continuous output without the required prompt escaped the capture ceiling')
    status, rows, post, sent, elapsed, output = run(connect_failure=True)
    require(isinstance(status, str) and 'did not accept a connection' in status
            and all(row['status'] == 'not-arrived' for row in rows), 'connection failure lost unfinished awaits')
    for unanswered in (False, True):
        status, rows, post, sent, elapsed, output = run(source='uart', stalled=True, unanswered=unanswered)
        require(isinstance(status, str) and 'scripted BREAK never fired' in status, 'postmortem changed the verdict')
        require(post and all(row['budget_origin'] == 'postmortem start' and row['timeout_seconds'] == 2.5
                             for row in post), 'postmortem reused the normal timeout')
        require(all(row['observed_seconds'] <= 7.5 for row in rows), 'normal observations continued into postmortem')
        require(elapsed <= 10.25, 'postmortem extended its existing deadline')
        require(all(row['status'] == 'arrived' for row in post) if not unanswered else
                any(row['status'] == 'not-arrived' for row in post), 'postmortem prompt observations were lost')
    status, rows, post, sent, elapsed, output = run(source='uart', stalled=True, progress=(5, 10, 15))
    require(isinstance(status, str) and 'scripted BREAK never fired' in status
            and all(22.5 <= row['observed_seconds'] <= 22.75 for row in rows
                    if row['status'] == 'not-arrived') and elapsed <= 25.25,
            'progressing UART boot was failed before its inactivity budget ran out')
    status, rows, post, sent, elapsed, output = run(source='uart', stalled=True,
                                                  unanswered=True, progress=range(1, 40))
    require(isinstance(status, str) and 'scripted BREAK never fired' in status
            and post and elapsed <= 30.25,
            'postmortem output renewed its own budget or escaped the outer ceiling')
    status, rows, post, sent, elapsed, output = run(unavailable=True)
    require(status == 0 and 'timing unavailable' in output, 'artifact failure replaced the capture verdict')
    report_pass('ddb await timing controls', 'UART progress renews capture within its ceiling; silence and continuous output remain bounded, and postmortem output cannot renew its separate budget', cases=CASES.ran)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
