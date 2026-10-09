#!/usr/bin/env python3
"""Check bounded churn transport and watchdog ordering without a guest or waits."""

from pathlib import Path
import subprocess
import sys
import tempfile
from types import SimpleNamespace
from unittest.mock import patch

import churn_gdb as transport
import run_kernel_churn as driver
from pass_line import CaseCount, report_pass


def main():
    cases = CaseCount()
    with tempfile.TemporaryDirectory() as temporary:
        for running in (False, True):
            for next_asid in (None, 65000):
                for outcome in ("complete", "silent-error", "nonzero", "timeout", "deferred"):
                    cases.note()
                    helper = transport.ChurnGdb(temporary, "fixture.elf")
                    helper.endpoint = "fixture-stub"
                    requests = []

                    def qmp(endpoint, command, arguments=None):
                        requests.append(command)
                        return {"running": running} if command == "query-status" else ""

                    def gdb(argv, **kwargs):
                        assert kwargs["timeout"] == 10
                        assert "disconnect" in argv
                        if outcome == "timeout":
                            raise subprocess.TimeoutExpired(argv, kwargs["timeout"])
                        marker = "churn ASID jump complete: 100 -> 65000" if next_asid else "churn stall dump complete"
                        text = marker if outcome == "complete" else (
                            "churn ASID jump deferred: lock held" if outcome == "deferred" else "Python Exception: failed")
                        return SimpleNamespace(returncode=1 if outcome == "nonzero" else 0, stdout=text)

                    with patch.object(transport, "qmp", qmp), patch.object(transport.subprocess, "run", gdb):
                        try:
                            answer = helper.run(next_asid)
                        except (RuntimeError, subprocess.TimeoutExpired):
                            assert outcome != "complete"
                            assert not (outcome == "deferred" and next_asid is not None)
                        else:
                            assert answer == (outcome == "complete"), "an exit-zero GDB error was accepted"
                            assert outcome == "complete" or (outcome == "deferred" and next_asid is not None), "an exit-zero GDB error was accepted"
                    assert requests == ["query-status", "cont" if running else "stop"], requests
        events = []
        session = driver.Session(0, 0)
        session.gdb_stall_dump = True
        session.gdb = SimpleNamespace(run=lambda: events.append("gdb"))
        session.normalized = lambda: b"ddb> " if "break" in events else b""
        session.send = lambda data: events.append("break" if data == b"\x14b" else "command")
        session.wait_for = lambda *args, **kwargs: True
        driver.ddb_walk_hang(session)
        cases.note()
        assert events[:2] == ["gdb", "break"], events
        session.dump_stall()
        assert events.count("gdb") == 1
        events.clear()
        session.gdb_dumped = False
        session.gdb.run = lambda: (_ for _ in ()).throw(RuntimeError("diagnostic unavailable"))
        driver.ddb_walk_hang(session)
        cases.note()
        assert "break" in events
        for outcome in ("complete", "deferred-once", "held", "failed"):
            cases.note()
            events = []
            session = driver.Session(0, 0)
            session.send = lambda data: events.append("command")
            session.wait_for = lambda *args, **kwargs: driver.VERDICT.search(
                b"\n" + driver.VERDICT_PREFIX + b"300 mismatched=0\n")

            def jump(number):
                assert number == 65000 and events[0] == "command"
                events.append("jump")
                if outcome == "failed":
                    raise RuntimeError("cannot inject")
                return outcome == "complete" or (outcome == "deferred-once" and events.count("jump") > 1)

            session.gdb = SimpleNamespace(run=jump)
            with patch.object(driver, "shell_resync", return_value=True):
                failure = driver.run_phase(session, 300, 65000)
            assert (failure is None) == (outcome in ("complete", "deferred-once")), failure
            assert events.count("command") == 1
            assert events.count("jump") == {"complete": 1, "deferred-once": 2, "held": 8, "failed": 1}[outcome]
        for options in (("--platform", "rpi5", "--gdb-stall-dump"),
                        ("--platform", "qemu", "--asid-jump", "65000"),
                        ("--platform", "qemu", "--long", "--asid-jump", "65536")):
            cases.note()
            with patch.object(sys, "argv", ["churn"] + list(options)), patch.object(driver.pty, "fork") as fork:
                try:
                    driver.main()
                except SystemExit as error:
                    assert error.code == 2
                else:
                    raise AssertionError("invalid GDB options were accepted")
                fork.assert_not_called()
    report_pass("churn-gdb-controls", "bounded failures restore run state; GDB precedes DDB without replacing its verdict", cases=cases.ran)


if __name__ == "__main__":
    main()
