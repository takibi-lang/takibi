#!/usr/bin/env python3
"""Run console driver waits under deterministic UART clocks."""

import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
from unittest.mock import patch

from pass_line import CaseCount, report_pass

ROOT = Path(__file__).resolve().parent.parent
CASES = CaseCount()


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


def pty_case(events, want_pass, ceiling=28.0, exit_delay=0.0):
    CASES.note()
    path = ROOT / "scripts/run_kernel_shell_qemu_smoketest.py"
    spec = importlib.util.spec_from_file_location("pty_progress_control", path)
    driver = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(driver)
    queue, sent, closed = [], [], []
    clock = Clock([(at, lambda data=data: queue.append(data)) for at, data in events])
    done = False
    done_at = None

    def write(_fd, data):
        nonlocal done, done_at
        sent.append(data)
        if data == b"\x1d":
            done = True
            done_at = clock.now
            return len(data)
        if data == b"\x14b" or data == b"oops\n":
            answer = b"ddb> "
        elif data == b"continue\n":
            answer = b"ddb: continuing\n"
        elif driver.HTTPD_REAP_RESULT in data:
            answer = b"\n1 /bin/httpd -f -p 8080 -h /\n" + driver.HTTPD_REAP_RESULT + b"\n # "
        elif driver.COMMAND_RESULT in data:
            answer = driver.COMMAND_RESULT + b"\n"
        else:
            answer = b"\nsystem stop: halt (all cores parked)\n"
        clock.events.append((clock.now + 0.1, lambda: queue.append(answer)))
        clock.events.sort(key=lambda event: event[0])
        return len(data)

    def select(_r, _w, _x, seconds):
        clock.sleep(seconds)
        return ([42] if queue else [], [], [])

    def fail(_pid, _transcript, message):
        raise RuntimeError(message)

    driver.time = clock
    driver.os = SimpleNamespace(environ={}, path=os.path, write=write,
                                makedirs=os.makedirs, unlink=os.unlink,
                                read=lambda *_: queue.pop(0),
                                waitpid=lambda *_: (123, 0) if done and
                                clock.now >= done_at + exit_delay else (0, 0),
                                WNOHANG=1, close=closed.append)
    driver.pty = SimpleNamespace(fork=lambda: (123, 42))
    driver.select = SimpleNamespace(select=select)
    driver.fail = fail
    driver.START_TIMEOUT_SECONDS = 8.0
    driver.START_CEILING_SECONDS = ceiling
    driver.verify_http = lambda *_: None
    driver.verify_uart_transcript = lambda *_: None
    driver.drain_terminal = lambda *_: None
    driver.shutil = SimpleNamespace(copyfile=lambda *_: None)
    status, output = True, io.StringIO()
    with patch.dict(os.environ, {}, clear=True), tempfile.TemporaryDirectory() as directory:
        driver.ARTIFACT_DIR = directory
        exit_path = Path(directory) / 'await-halt-exit.jsonl'
        exit_path.write_text('stale exit timing\n')
        try:
            with contextlib.redirect_stdout(output):
                driver.run_one("halt", 0)
        except RuntimeError as error:
            status = False
            assert ('timed out waiting for ash command response' in str(error)
                    or 'timed out waiting for Ctrl-] cleanup' in str(error)), error
        rows = [json.loads(line) for line in
                (Path(directory) / 'await-halt.jsonl').read_text().splitlines()]
        assert len(rows) == 3 and all(row['timeout_seconds'] == ceiling for row in rows)
        assert all(row['budget_origin'] == 'startup ceiling (UART inactivity limit 8s)' for row in rows)
        if done:
            assert all(row['status'] == 'arrived' for row in rows)
            exit_rows = [json.loads(line) for line in exit_path.read_text().splitlines()]
            assert len(exit_rows) == 1
            assert exit_rows[0]['timeout_seconds'] == driver.EXIT_TIMEOUT_SECONDS
            assert exit_rows[0]['budget_origin'] == 'Ctrl-] cleanup start'
            assert (exit_rows[0]['status'] == 'arrived') == want_pass
            if want_pass:
                assert exit_rows[0]['elapsed_seconds'] == exit_delay
        else:
            assert not exit_path.exists()
            assert any(row['status'] == 'not-arrived' for row in rows)
    assert status == want_pass, (status, clock.now, sent, output.getvalue())
    assert closed == [42], closed
    if want_pass:
        assert clock.now > 8.0 and b"continue\n" in sent and done, sent
        assert "PASS (halt, all cores parked)" in output.getvalue()
    return clock.now


def starve_case(events, diagnostic):
    CASES.note()
    path = ROOT / "scripts/kernel_starve_gdb_check.py"
    source = path.read_text()
    clock = Clock([])
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        env = {
            "AFFINITY_GDB_SERIAL_PORT": "1", "AFFINITY_GDB_GDB_PORT": "2",
            "AFFINITY_GDB_UART_LOG": str(root / "uart"),
            "AFFINITY_GDB_VERDICT": str(root / "verdict"),
            "AFFINITY_GDB_INIT_LISTENER": str(root / "init"),
            "AFFINITY_GDB_NETWORK_READY": str(root / "net"),
        }
        namespace = {"__file__": str(path), "__name__": "starve_control"}
        with patch.dict(os.environ, env), patch.dict(
                sys.modules, {"gdb": SimpleNamespace(execute=lambda *_: None)}):
            # GDB executes the footer immediately; load its definitions here,
            # then run the actual main with controlled adapters instead.
            exec(compile(source[:source.rindex("\ntry:\n    main()")],
                         str(path), "exec"), namespace)
        namespace["time"] = clock
        namespace["BOOT_TIMEOUT"] = 8.0
        namespace["BATCH_CEILING"] = 28.0
        sent = []
        namespace["connect"] = lambda *_: SimpleNamespace(sendall=sent.append)
        namespace["threading"] = SimpleNamespace(
            Thread=lambda **_: SimpleNamespace(start=lambda: None))
        for at, data in events:
            clock.events.append((at, lambda data=data:
                                 namespace["observe_chunk"](data)))
        clock.events.sort(key=lambda event: event[0])
        output = io.StringIO()
        with patch.dict(os.environ, env), contextlib.redirect_stdout(output):
            namespace["main"]()
        text = (root / "verdict").read_text()
        assert diagnostic in text and diagnostic in output.getvalue(), text
        if text.startswith("PASS "):
            assert clock.now > 8.0 and sent == [b"exit\n", b"irqtest\n"], sent
        return clock.now


def uart_wake_case(events, expected, *, boot=True, started=0.0):
    CASES.note()
    path = ROOT / "scripts/kernel_uart_wake_check.py"
    source = path.read_text()
    clock = Clock([])
    clock.now = started
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        env = {"UART_WAKE_SERIAL_PORT": "1", "UART_WAKE_GDB_PORT": "2",
               "UART_WAKE_UART_LOG": str(root / "uart"),
               "UART_WAKE_VERDICT": str(root / "verdict"),
               "UART_WAKE_INIT_LISTENER": str(root / "init"),
               "UART_WAKE_NETWORK_READY": str(root / "net")}
        namespace = {"__file__": str(path), "__name__": "uart_wake_control"}
        with patch.dict(os.environ, env, clear=True), patch.dict(
                sys.modules, {"gdb": SimpleNamespace(Breakpoint=object)}):
            exec(compile(source[:source.rindex("\ntry:\n    run()")],
                         str(path), "exec"), namespace)
            namespace["time"] = clock
            namespace["BATCH_DEADLINE"] = 28.0
            namespace["output"].extend(b"old boot output\n")
            clock.events = [(at, lambda data=data:
                             namespace["output"].extend(data)) for at, data in events]
            result = namespace["seen"](lambda text: b"ready" in text, 8.0,
                                       boot_phase="fixture" if boot else None)
        assert result is expected, (result, clock.now)
        if boot:
            row = json.loads((root / "uart.await-fixture.jsonl").read_text())
            assert row["status"] == ("arrived" if expected else "not-arrived"), row
            assert row["timeout_seconds"] == 28.0 - started, row
        return clock.now


def main():
    advancing = [(4.0, b"boot\n"), (10.0, b"boot\n"), (16.0, b"boot\n"),
                 (20.0, b"ready\n")]
    assert uart_wake_case(advancing, True) == 20.0
    assert uart_wake_case([], False) == 8.0
    assert uart_wake_case([(4.0, b"boot\n")], False) == 12.0
    assert uart_wake_case([(at, b"boot\n") for at in range(4, 40, 4)], False) == 28.0
    assert uart_wake_case([(24.0, b"boot\n"), (29.0, b"ready\n")],
                          False, started=20.0) == 28.0
    assert uart_wake_case(advancing, False, boot=False) == 8.0
    ready = (b"open in a host browser" + bytes((58, 32))
             + b"http://127.0.0.1:1/\n"
             + b"persistent server: listener ready port=8080\n"
             + b"persistent shell: uart blocked\n"
             + b"interactive shell: uart blocked\n" + b" # ")
    assert pty_case([(4.0, b"boot\n"), (10.0, b"boot\n"), (16.0, ready)], True) < 28.0
    progress = [(4.0, b"boot\n"), (10.0, b"boot\n"), (16.0, ready)]
    assert pty_case(progress, True, exit_delay=5.0) > 20
    assert pty_case(progress, False, exit_delay=20.0) > 30
    assert pty_case([], False) == 8.0
    assert pty_case([(4.0, b"boot\n")], False) == 12.0
    assert pty_case([(at, b"boot\n") for at in range(4, 40, 4)], False) == 28.0
    shell = b"interactive shell: uart blocked\n"
    payload = b"concurrency: parent progressed while child uart-blocked\n"
    beginning = [(4.0, b"boot\n"), (10.0, shell), (16.0, payload)]
    verdict = (b"workload: busy pair STARVED: a wait passed its bound\n"
               b"workload: busy pair waits a: max_excess=62\n"
               b"workload: busy pair done\n")
    assert starve_case(beginning + [(20.0, verdict)], "PASS ") == 20.0
    assert starve_case([], "the boot never reached") == 8.0
    assert starve_case(beginning, "the busy pair never reported") == 24.0
    assert starve_case([(at, b"boot\n") for at in range(4, 40, 4)],
                       "the boot never reached") == 28.0
    assert starve_case(beginning + [(20.0, b"workload: busy pair waits bounded:\n")],
                       "still called its waits bounded") == 20.0
    assert starve_case(beginning + [(20.0, verdict.replace(b"62", b"2"))],
                       "the verdict failed for another reason") == 20.0
    report_pass("console progress controls",
                "PTY, STARVED and UART-wake waits accept advancing UART; silence "
                "and ceilings fail; stop, DDB and tick verdicts are preserved",
                cases=CASES.ran)
    return 0


if __name__ == "__main__":
    sys.exit(main())
