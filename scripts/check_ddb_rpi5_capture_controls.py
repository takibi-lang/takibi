#!/usr/bin/env python3
"""Fast negative controls for the live/offline RPi5 DDB capture predicates.

No terminal or board is opened: the maintained synthetic board's reply bytes
feed the same validator used after a physical run. Timing/retry controls stay
in slowcheck_run_kernel_ddb_rpi5_driver.py.
"""

import importlib.util
import contextlib
import io
import os
import runpy
import sys
import tempfile
from types import SimpleNamespace
from pathlib import Path

from pass_line import CaseCount, report_pass

ROOT = Path(__file__).resolve().parent.parent


def load(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / "scripts" / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class Evidence:
    resume_attempts = 1

    @staticmethod
    def bail(message):
        return SystemExit(message)


def main():
    driver = load("run_kernel_ddb_rpi5_driver")
    fixture = load("slowcheck_run_kernel_ddb_rpi5_driver")
    prefix = fixture.BANNER_HEAD + fixture.PEER_PENDING + fixture.BANNER_TAIL
    for command in (b"xkfault", b"events", b"bt", b"bt cpu 1", b"wait"):
        prefix += fixture.PROMPT + fixture.REPLIES[command]
    continuing = (b"\nddb: continuing\n"
                  b"ddb: console tx=queued\n")
    healthy = prefix + continuing + fixture.PEER_RECORD + fixture.RESUME_ECHO
    marker = fixture.PEER_RECORD
    cases = (
        ("CRLF record", healthy, None),
        ("LF record", healthy.replace(b"\r", b""), None),
        ("all CRLF", healthy.replace(b"\r", b"").replace(b"\n", b"\r\n"), None),
        ("missing guard witness", healthy.replace(fixture.PEER_PENDING, b""),
         "BREAK was not observed during a held console guard"),
        ("unreleased guard", healthy.replace(b"phase=2", b"phase=1"),
         "BREAK was not observed during a held console guard"),
        ("timeout without observed BREAK", healthy.replace(b"release=2", b"release=3"),
         "BREAK was not observed during a held console guard"),
        ("echoed command only", healthy.replace(fixture.RESUME_ECHO, b"echo ddb-resume-ok\r\n"),
         "workload did not resume"),
        ("output before continue", fixture.RESUME_ECHO + healthy.replace(fixture.RESUME_ECHO, b""),
         "workload did not resume"),
        ("missing peer root", healthy.replace(fixture.REPLIES[b"bt cpu 1"], b""),
         "backtrace the stopped peer"),
        ("partial world stop", healthy.replace(b"mask=0x000000000000000e", b"mask=0x0000000000000002"),
         "stop and acknowledge all online peers"),
    )
    # GitHub issue #957: the hung-core session after the resume, entered on
    # cpu 2 while cpu 1 spins masked; the world stop must include cpu 1.
    hung = (b"\nddb: interrupt-safe UART debugger\n"
            b"ddb: world-stop complete mask=0x000000000000000b\n"
            b"ddb: break seq=9 cpu=2 elr=0x00000000400103a0 "
            b"sp_el0=0x000000007ffffdf0\n" + fixture.PROMPT +
            b"continue\n" + continuing)
    hung_cases = (
        ("hung-core session", healthy + hung, None),
        ("no hung-core session", healthy, "no second DDB entry"),
        ("hung-core partial stop",
         healthy + hung.replace(b"complete mask=0x000000000000000b",
                                b"partial mask=0x0000000000000009"),
         "did not reach the masked cpu 1"),
        ("hung-core entered on the masked cpu",
         healthy + hung.replace(b"cpu=2 elr", b"cpu=1 elr"),
         "entered on the masked cpu 1"),
        ("hung-core stop without cpu 1",
         healthy + hung.replace(b"mask=0x000000000000000b", b"mask=0x0000000000000009"),
         "did not include cpu 1"),
    )
    count = CaseCount()
    for name, capture, expected, hung_core in ([(n, c, e, False) for n, c, e in cases] +
                                    [(n, c, e, True) for n, c, e in hung_cases]):
        count.note()
        try:
            driver.validate_capture(capture, capture.count(fixture.PROMPT), Evidence(),
                                    hung_core=hung_core)
        except SystemExit as error:
            if expected is None or expected not in str(error):
                raise SystemExit(f"FAIL ddb-rpi5 capture control {name}: {error}")
        else:
            if expected is not None:
                raise SystemExit(f"FAIL ddb-rpi5 capture control {name}: accepted invalid evidence")
    # A published phase alone is not proof of an actual held guard. Execute
    # the GDB injection observer against independent phase/mutex controls.
    with tempfile.TemporaryDirectory() as temp:
        ready = Path(temp) / "ready"
        release = Path(temp) / "release"
        release.touch()
        saved = {name: os.environ.get(name) for name in
                 ("KERNEL_CONSOLE_HOLD_READY", "KERNEL_CONSOLE_HOLD_RELEASE")}
        previous_gdb = sys.modules.get("gdb")
        os.environ["KERNEL_CONSOLE_HOLD_READY"] = str(ready)
        os.environ["KERNEL_CONSOLE_HOLD_RELEASE"] = str(release)
        try:
            # GitHub issue #867: the observer resumes through
            # gdb_progress.continue_by_ticks, so the fake gdb runs a guest:
            # each `continue` advances every core's tick counter by `step`
            # and hits the hold checkpoint when `hits`. A guest that never
            # reaches it with ticks is a finding (QUIET); one whose ticks
            # stopped is inconclusive (STALLED). Neither may publish ready.
            cases = ((1, 1, True, True, 1, None),
                     (1, 0, False, True, 1, "held guard"),
                     (0, 1, False, True, 1, "held guard"),
                     (1, 1, False, False, 1000, "was not reached within"),
                     (1, 1, False, False, 0, "inconclusive"))
            for phase, held, valid, hits, step, expected in cases:
                count.note()
                ready.unlink(missing_ok=True)
                guest = {"ticks": 0}

                class Breakpoint:
                    def __init__(self, spec, internal=False):
                        self.hit_count = 0
                        guest.setdefault("breakpoints", []).append(self)

                def execute(command, to_string=False, hits=hits, step=step):
                    # #878: the stub's PhyMemMode, queried and set as QEMU
                    # does; the observer's own reads below need it on.
                    if command == "maintenance packet qqemu.PhyMemMode":
                        return f'received: "{guest.get("physical", 0)}"\n'
                    if command.startswith("maintenance packet Qqemu.PhyMemMode:"):
                        guest["physical"] = int(command[-1])
                    if command == "continue":
                        guest["ticks"] += step
                        if hits:
                            for breakpoint in guest["breakpoints"]:
                                breakpoint.hit_count += 1

                def parse_and_eval(expression, phase=phase, held=held):
                    if guest.get("physical") != 1:
                        raise RuntimeError("virtual read: PhyMemMode was turned off")
                    if "secondary_tick_count" in expression:
                        return guest["ticks"]
                    return phase if "console_ddb_phase" in expression else held

                threads = [SimpleNamespace(num=number) for number in (1, 2, 3, 4)]
                sys.modules["gdb"] = SimpleNamespace(
                    execute=execute, parse_and_eval=parse_and_eval,
                    Breakpoint=Breakpoint, GdbError=RuntimeError, error=RuntimeError,
                    selected_inferior=lambda: SimpleNamespace(threads=lambda: threads),
                    selected_thread=lambda: threads[0])
                for module in ("gdb_progress", "gdb_tick_count"):
                    sys.modules.pop(module, None)
                accepted, reason = True, ""
                try:
                    with contextlib.redirect_stdout(io.StringIO()):
                        runpy.run_path(str(ROOT / "scripts/kernel_console_hold_check.py"))
                except RuntimeError as error:
                    accepted, reason = False, str(error)
                if accepted != valid or ready.exists() != valid:
                    raise SystemExit("FAIL console BREAK observer accepted an unheld "
                                     "phase or mutex, or an unreached hold")
                if expected is not None and expected not in reason:
                    raise SystemExit(f"FAIL console BREAK observer: expected {expected!r}, "
                                     f"got {reason!r}")
        finally:
            if previous_gdb is None:
                sys.modules.pop("gdb", None)
            else:
                sys.modules["gdb"] = previous_gdb
            for name, value in saved.items():
                if value is None: os.environ.pop(name, None)
                else: os.environ[name] = value
    software = load("run_kernel_ddb_rpi5_software_driver")
    continued = b"ddb: continuing\n"
    for capture, expected in (
        (continued + b"\nddb-software-resume-ok\n/ # ", True),
        (continued + b"\nddb-software-resume-ok\r\n # \x1b[6n", True),
        (continued + b" # echo ddb-software-resume-ok\n # ", False),
        (b"\nddb-software-resume-ok\n # \n" + continued, False),
        (continued + b"\nddb-software-resume-ok\n", False),
        (b"\nddb-software-resume-ok\n # ", False),
    ):
        count.note()
        if software.shell_resumed(capture) != expected:
            raise SystemExit("FAIL software DDB capture control: prompt or output ordering")
    report_pass("ddb-rpi5 capture controls", "LF/CRLF pass; missing hold, missing release, timeout-only evidence, unheld mutex or phase, an unreached hold (QUIET) and a stalled guest (inconclusive), echoed commands, invalid stopped-world evidence and a missing, partial, wrongly entered or incomplete hung-core stop (#957) fail",
                cases=count.ran)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
