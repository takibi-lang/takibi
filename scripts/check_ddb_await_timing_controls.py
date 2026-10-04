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
        connect_failure=False, unavailable=False):
    CASES.note()
    spec = importlib.util.spec_from_file_location('ddb_driver', ROOT / 'scripts/run_kernel_ddb_driver.py')
    driver = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(driver)
    clock = Clock()
    serial = DdbSocket(clock, [] if stalled or connect_failure else [(at, b'ddb'), (at + 0.25, b'> ')],
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
    require('--await-timing-log "$ARTIFACT_DIR/await-timing.jsonl"' in
            (ROOT / 'scripts/run_kernel_ddb_qemutest.sh').read_text(), 'live runner lost its artifact')
    for at, margin in ((2.0, False), (6.0, True)):
        status, rows, post, sent, elapsed, output = run(at=at)
        require(status == 0 and not post, 'measurement changed a passing software BREAK')
        require(len(rows) == len(sent) + 3 and all(row['status'] == 'arrived' for row in rows),
                'a normal capture lost awaits or expected a prompt after continue')
        require(all(row['timeout_seconds'] == 10.0 and row['budget_origin'] == 'driver start' for row in rows),
                'the common deadline was reinterpreted')
        prompt = next(row for row in rows if row['await'] == 'console prompt 1')
        require(prompt['elapsed_seconds'] == at + 0.25, 'split prompt arrival was recorded early')
        require(('await margin:' in output) == margin, 'tight timeout was not recorded')
        require(sent[-1][0] == b'continue\n', 'continue was not the final command')
    status, rows, post, sent, elapsed, output = run(unanswered=True)
    require(isinstance(status, str) and 'sequence did not complete' in status
            and any(row['status'] == 'not-arrived' for row in rows) and elapsed <= 10.25,
            'missing replies lost the original failure or extended its deadline')
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
    status, rows, post, sent, elapsed, output = run(unavailable=True)
    require(status == 0 and 'timing unavailable' in output, 'artifact failure replaced the capture verdict')
    report_pass('ddb await timing controls', 'normal and postmortem UART observations retain their separate deadlines; split prompts, tight budgets, unfinished awaits and unavailable artifacts preserve the driver verdict', cases=CASES.ran)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
