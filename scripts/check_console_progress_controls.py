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


def reap_parse_cases():
    """#856: workload lines split the echoed reap command in the 2026-10-20
    land log; the parser must read only echo's own marker lines."""
    path = ROOT / "scripts/run_kernel_shell_qemu_smoketest.py"
    spec = importlib.util.spec_from_file_location("pty_reap_control", path)
    driver = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(driver)
    count = driver.httpd_reap_count
    line = driver.HTTPD_REAP_LINE.rstrip(b"\n")
    assert driver.HTTPD_REAP_BEGIN not in line and driver.HTTPD_REAP_END not in line
    assert driver.COMMAND_RESULT not in driver.COMMAND_LINE
    begin = b"\n" + driver.HTTPD_REAP_BEGIN + b"\n"
    end = driver.HTTPD_REAP_END + b"\n"
    ps_one = (b"PID   USER     TIME  COMMAND\n    1 0         0:00 init\n"
              b"   12 0         0:00 /bin/httpd -f -p 8080 -h /www\n")
    zombie = ps_one + b"   31 0         0:00 /bin/httpd -f -p 8080 -h /www\n"
    # The land log's shape: a workload line split the echoed command, and
    # the old marker's tail landed alone on a line before ps ever ran.
    split = len(line) // 2
    interleaved = (b" # " + line[:split] +
                   b"inned httpd closed and shut down a connected socket\n" +
                   line[split:] + b"\n")
    for cut in range(len(line) + 1):
        CASES.note()
        echoed = b" # " + line[:cut] + b"\nworkload: pinned httpd read and wrote a connected socket on the secondary cpu\n" + line[cut:] + b"\n"
        assert count(echoed) is None, cut
    CASES.note()
    assert count(interleaved) is None
    CASES.note()
    assert count(interleaved + begin[1:] + ps_one) is None
    CASES.note()
    assert count(interleaved + begin[1:] + ps_one + end) == 1
    CASES.note()
    assert count(interleaved + begin[1:] + zombie + end) == 2
    CASES.note()
    assert count(interleaved + begin[1:] + b"workload: pinned httpd closed and shut down a connected socket on the secondary cpu\n" + zombie + end) == 2
    CASES.note()
    assert count(interleaved + begin[1:] + end) == 0
    CASES.note()
    # An httpd line outside the window (an earlier ps) is not counted.
    assert count(zombie + interleaved + begin[1:] + ps_one + end) == 1


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
        elif data == driver.HTTPD_REAP_LINE:
            answer = (b"\n" + driver.HTTPD_REAP_BEGIN + b"\n1 /bin/httpd -f -p 8080 -h /\n" +
                      driver.HTTPD_REAP_END + b"\n # ")
        elif data == driver.COMMAND_LINE:
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


def starve_case(events, diagnostic, *, driver="kernel_starve_gdb_check"):
    CASES.note()
    path = ROOT / f"scripts/{driver}.py"
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
        with patch.dict(os.environ, env, clear=True), patch.dict(
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
        with patch.dict(os.environ, env, clear=True), contextlib.redirect_stdout(output):
            namespace["main"]()
        text = (root / "verdict").read_text()
        assert diagnostic in text and diagnostic in output.getvalue(), text
        phase = "starve" if driver == "kernel_starve_gdb_check" else "rollover"
        rows = [json.loads(line) for line in
                (root / f"uart.await-{phase}.jsonl").read_text().splitlines()]
        assert all(row["timeout_seconds"] == 28.0 for row in rows), rows
        assert len(rows) == (4 if phase == "starve" else 3), rows
        if text.startswith("PASS "):
            assert clock.now > 8.0, clock.now
            assert sent == ([b"exit\n", b"irqtest\n"] if phase == "starve" else []), sent
            assert all(row["status"] == "arrived" for row in rows), rows
        return clock.now


def uart_wake_case(events, expected, *, boot=True, started=0.0,
                   driver="kernel_uart_wake_check"):
    CASES.note()
    path = ROOT / f"scripts/{driver}.py"
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
        if driver != "kernel_uart_wake_check":
            env = {key.replace("UART_WAKE", "AFFINITY_GDB"): value
                   for key, value in env.items()}
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
            phase = "fixture"
            if driver == "kernel_uart_wake_check":
                result = namespace["seen"](lambda text: b"ready" in text, 8.0,
                                           boot_phase=phase if boot else None,
                                           response_phase=None if boot else phase)
            elif driver == "kernel_affinity_gdb_check":
                result = namespace["seen"](lambda text: b"ready" in text, 8.0,
                                           phase=phase, boot=boot)
            else:
                phase = "first-shell"
                result = namespace["seen"](b"ready", 8.0)
        assert result is expected, (result, clock.now)
        row = json.loads((root / f"uart.await-{phase}.jsonl").read_text())
        assert row["status"] == ("arrived" if expected else "not-arrived"), row
        assert row["timeout_seconds"] == (28.0 - started if boot else 8.0), row
        return clock.now


class FakeBreakpoint:
    """A breakpoint the stalled guest never reaches."""
    def __init__(self, *_args, **_kwargs):
        self.hit_count = 0
        self.condition = None
        self.enabled = True

    def delete(self):
        pass


def stalled_stage_case(driver, outcome):
    """#874 (from #878's audit): a stage that ends STALLED (the guest was not
    given the ticks) is inconclusive, and only a QUIET one is a finding
    (scripts/gdb_progress.py). Runs the driver's first gdb stage with a
    guest that never reaches its breakpoint and returns the verdict."""
    CASES.note()
    path = ROOT / f"scripts/{driver}.py"
    source = path.read_text()
    prefix = "UART_WAKE" if driver == "kernel_uart_wake_check" else "AFFINITY_GDB"
    fake_gdb = SimpleNamespace(
        Breakpoint=FakeBreakpoint,
        execute=lambda *_args, **_kwargs: "",
        parse_and_eval=lambda *_args: 0,
        parameter=lambda *_args: False)
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        env = {f"{prefix}_SERIAL_PORT": "1", f"{prefix}_GDB_PORT": "2",
               f"{prefix}_UART_LOG": str(root / "uart"),
               f"{prefix}_VERDICT": str(root / "verdict"),
               f"{prefix}_INIT_LISTENER": str(root / "init"),
               f"{prefix}_NETWORK_READY": str(root / "net")}
        namespace = {"__file__": str(path), "__name__": "stalled_control"}
        progress = SimpleNamespace(DONE="done", QUIET="quiet", STALLED="stalled",
                                   Counter=FakeBreakpoint,
                                   continue_by_ticks=None, resume_slice=None,
                                   all_threads=lambda: ())
        with patch.dict(os.environ, env, clear=True), patch.dict(
                sys.modules, {"gdb": fake_gdb, "gdb_progress": progress}), \
                contextlib.redirect_stdout(io.StringIO()):
            exec(compile(source[:source.rindex("\ntry:\n    run()")],
                         str(path), "exec"), namespace)
            namespace["seen"] = lambda *_args, **_kwargs: True
            namespace["time"] = SimpleNamespace(sleep=lambda _s: None,
                                                monotonic=lambda: 0.0)
            namespace["uart_tail"] = lambda: ""
            if driver == "kernel_uart_wake_check":
                namespace["step"] = lambda *_args: (outcome, 7)
                namespace["run_peer"](SimpleNamespace(sendall=lambda _d: None))
            else:
                namespace["run_until"] = lambda *_args, **_kwargs: (outcome, 7)
                namespace["connect"] = lambda _deadline: SimpleNamespace(
                    sendall=lambda _d: None)
                namespace["threading"] = SimpleNamespace(
                    Thread=lambda **_kwargs: SimpleNamespace(start=lambda: None),
                    Lock=threading_lock)
                namespace["run"]()
        return (root / "verdict").read_text()


def threading_lock():
    import threading
    return threading.Lock()


def stalled_stage_cases():
    for driver, finding in (
            ("kernel_uart_wake_check", "needs something else runnable"),
            ("kernel_affinity_reap_check", "never reached the kill(2)")):
        stalled = stalled_stage_case(driver, "stalled")
        assert stalled.startswith("FAIL ") and "inconclusive" in stalled, stalled
        quiet = stalled_stage_case(driver, "quiet")
        assert quiet.startswith("FAIL ") and finding in quiet, quiet
        assert "inconclusive" not in quiet, quiet


def churn_wait_case(events, expected, *, broken=False, optional=False):
    CASES.note()
    import run_kernel_churn as driver
    queue = []
    clock = Clock([(at, lambda data=data: queue.append(data)) for at, data in events])

    def select(*_):
        if broken:
            raise OSError("terminal unavailable")
        clock.sleep(0.25)
        return ([7] if queue else [], [], [])

    with tempfile.TemporaryDirectory() as raw:
        root = Path(raw)
        session = driver.Session(42, 7, await_log=str(root / "transcript"))
        captured = io.StringIO()
        with patch.dict(os.environ, {}, clear=True), \
                patch.object(driver, "time", clock), \
                patch.object(driver.select, "select", select), \
                patch.object(driver.os, "read", lambda *_: queue.pop(0)), \
                contextlib.redirect_stdout(captured):
            try:
                result = session.wait_for(lambda text: b"ready" in text, 8.0,
                                          watch_from=0,
                                          await_name=None if optional else "fixture response")
            except OSError as error:
                result = str(error)
        if expected == "failure":
            assert isinstance(result, driver.FailureMarker), result
        else:
            assert result == expected, (result, expected)
        path = root / "transcript.await-0001.jsonl"
        if optional:
            assert not path.exists()
        else:
            row = json.loads(path.read_text())
            assert row["status"] == ("arrived" if result is True else "not-arrived"), row
            assert row["timeout_seconds"] == 8.0 and row["budget_origin"] == "console wait start", row
            assert row["observed_seconds"] == clock.now, row
            assert ("await margin" in captured.getvalue()) == (result is True and clock.now > 4.0)
        return clock.now


def main():
    assert churn_wait_case([(4.0, b"ready\n")], True) == 4.0
    assert churn_wait_case([(6.0, b"ready\n")], True) == 6.0
    assert churn_wait_case([], None) == 8.0
    assert churn_wait_case([(1.0, b"")], None) == 1.0
    assert churn_wait_case([(2.0, b"oops: activity=start-on-owned-stack\nready\n")],
                           "failure") == 2.0
    churn_wait_case([], "terminal unavailable", broken=True)
    assert churn_wait_case([], None, optional=True) == 8.0
    advancing = [(4.0, b"boot\n"), (10.0, b"boot\n"), (16.0, b"boot\n"),
                 (20.0, b"ready\n")]
    assert uart_wake_case(advancing, True) == 20.0
    assert uart_wake_case([], False) == 8.0
    assert uart_wake_case([(4.0, b"boot\n")], False) == 12.0
    assert uart_wake_case([(at, b"boot\n") for at in range(4, 40, 4)], False) == 28.0
    assert uart_wake_case([(24.0, b"boot\n"), (29.0, b"ready\n")],
                          False, started=20.0) == 28.0
    assert uart_wake_case(advancing, False, boot=False) == 8.0
    assert uart_wake_case([(6.0, b"ready\n")], True, boot=False) == 6.0
    for driver in ("kernel_affinity_gdb_check", "kernel_affinity_reap_check"):
        assert uart_wake_case(advancing, True, driver=driver) == 20.0
        assert uart_wake_case([], False, driver=driver) == 8.0
        assert uart_wake_case([(4.0, b"boot\n")], False, driver=driver) == 12.0
        assert uart_wake_case([(at, b"boot\n") for at in range(4, 40, 4)],
                              False, driver=driver) == 28.0
        assert uart_wake_case([(24.0, b"boot\n"), (29.0, b"ready\n")],
                              False, started=20.0, driver=driver) == 28.0
    assert uart_wake_case(advancing, False, boot=False,
                          driver="kernel_affinity_gdb_check") == 8.0
    retried = b"asid rollover: activation retried 2 busy world stops, then rolled over\n"
    cloned = b"asid rollover: clone activation retried 2 busy world stops, then rolled over\n"
    shell = b"interactive shell: uart blocked\n"
    driver = "kernel_rollover_gdb_check"
    assert starve_case([(4.0, b"boot\n"), (10.0, retried), (16.0, cloned),
                        (20.0, shell)], "PASS ", driver=driver) == 20.0
    assert starve_case([], "no exec activation", driver=driver) == 8.0
    assert starve_case([(4.0, b"boot\n")], "no exec activation", driver=driver) == 12.0
    assert starve_case([(at, b"boot\n") for at in range(4, 40, 4)],
                       "no exec activation", driver=driver) == 28.0
    assert starve_case([(4.0, b"boot\n"), (10.0, retried), (16.0, shell)],
                       "no fork child activation", driver=driver) == 24.0
    assert starve_case([(4.0, b"boot\n"), (10.0, shell), (16.0, retried + cloned)],
                       "the boot did not reach", driver=driver) == 24.0
    assert starve_case([(4.0, b"oops: activity=start-on-owned-stack\n")],
                       "fail-stopped", driver=driver) == 4.0
    ready = (b"open in a host browser" + bytes((58, 32))
             + b"http://127.0.0.1:1/\n"
             + b"persistent server: listener ready port=8080\n"
             + b"persistent shell: uart blocked\n"
             + b"interactive shell: uart blocked\n" + b" # ")
    assert pty_case([(4.0, b"boot\n"), (10.0, b"boot\n"), (16.0, ready)], True) < 28.0
    reap_parse_cases()
    stalled_stage_cases()
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
                "PTY and GDB waits accept advancing UART; silence and ceilings "
                "fail; fixed responses, marker order and injected verdicts are preserved; "
                "the httpd reap count reads only echo's marker lines, not a split "
                "command echo, and a second httpd still counts (#856); a STALLED "
                "uart-wake or affinity-reap stage reads as inconclusive, a QUIET "
                "one as a finding (#874)",
                cases=CASES.ran)
    return 0


if __name__ == "__main__":
    sys.exit(main())
