#!/usr/bin/env python3
"""GitHub issue #878: the gdb_progress users keep STALLED inconclusive.

scripts/gdb_progress.py continue_by_ticks() ends a stage DONE, QUIET (every
listed vCPU took its ticks and the condition never held: a finding) or
STALLED (the guest was not given the time: inconclusive). Only QUIET may
become a negative verdict. console-hold's controls live in
check_ddb_rpi5_capture_controls.py; these drive the other three users --
affinity-gdb's run(), peer-exit's top level and exec-enomem's reach() --
against a fake gdb whose guest stops taking ticks (STALLED) or keeps taking
them without reaching the breakpoint (QUIET), at each stage in turn, and
require the inconclusive wording exactly for STALLED.

The fake stub also keeps QEMU's PhyMemMode, and every tick read must find
the caller's mode restored after it (#878).
"""

import contextlib
import io
import os
from pathlib import Path
import runpy
import sys
import tempfile
from types import SimpleNamespace
from unittest.mock import patch

from pass_line import CaseCount, report_pass

ROOT = Path(__file__).resolve().parent.parent
CASES = CaseCount()
INCONCLUSIVE = "inconclusive"


class Guest:
    """A fake gdb module over a guest whose breakpoints are hit in creation
    order: the first `reachable` stages are reached within one tick; at the
    next, each `continue` takes `after` ticks (0: STALLED, many: QUIET)."""

    def __init__(self, reachable: int, after: int, physical: int = 0):
        self.reachable = reachable
        self.after = after
        self.ticks = 0
        self.physical = physical
        self.created = []
        guest = self

        class Breakpoint:
            def __init__(self, spec, kind=None, access=None, internal=False):
                self.hit_count = 0
                self.reached = False
                self.condition = None
                self.thread = None
                self.stage = len(guest.created)
                guest.created.append(self)

            def delete(self):
                pass

        self.module = SimpleNamespace(
            Breakpoint=Breakpoint, BP_WATCHPOINT=1, WP_WRITE=1,
            GdbError=RuntimeError, error=RuntimeError,
            execute=self.execute, parse_and_eval=self.parse_and_eval,
            selected_inferior=lambda: SimpleNamespace(
                threads=lambda: [SimpleNamespace(num=n) for n in (1, 2)]),
            selected_thread=lambda: SimpleNamespace(num=1, global_num=1))

    def execute(self, command, to_string=False):
        if command == "maintenance packet qqemu.PhyMemMode":
            return f'sending: "qqemu.PhyMemMode"\nreceived: "{self.physical}"\n'
        if command.startswith("maintenance packet Qqemu.PhyMemMode:"):
            self.physical = int(command[-1])
            return "received: \"OK\"\n"
        if command == "continue":
            stage = self.created[-1]
            if stage.stage < self.reachable:
                stage.hit_count += 1
                stage.reached = True
                self.ticks += 1
            else:
                self.ticks += self.after
        if command.startswith("info symbol"):
            return "somewhere in section .text"
        return ""

    def parse_and_eval(self, expression):
        if "secondary_tick_count" in expression:
            if self.physical != 1:
                raise RuntimeError("tick read outside PhyMemMode")
            return self.ticks
        return 0


def fresh(guest):
    for module in ("gdb_progress", "gdb_tick_count"):
        sys.modules.pop(module, None)
    return patch.dict(sys.modules, {"gdb": guest.module})


def prefix(path: Path, footer: str) -> str:
    source = path.read_text()
    return source[:source.rindex(footer)]


def affinity_case(reachable: int, after: int, expected: str):
    CASES.note()
    path = ROOT / "scripts/kernel_affinity_gdb_check.py"
    guest = Guest(reachable, after)
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        env = {"AFFINITY_GDB_SERIAL_PORT": "1", "AFFINITY_GDB_GDB_PORT": "2",
               "AFFINITY_GDB_UART_LOG": str(root / "uart"),
               "AFFINITY_GDB_VERDICT": str(root / "verdict"),
               "AFFINITY_GDB_INIT_LISTENER": str(root / "init"),
               "AFFINITY_GDB_NETWORK_READY": str(root / "net")}
        namespace = {"__file__": str(path), "__name__": "affinity_progress_control"}
        with patch.dict(os.environ, env, clear=True), fresh(guest), \
                contextlib.redirect_stdout(io.StringIO()):
            exec(compile(prefix(path, "\ntry:\n    run()"), str(path), "exec"),
                 namespace)
            namespace["connect"] = lambda *_: SimpleNamespace(sendall=lambda _: None)
            namespace["threading"] = SimpleNamespace(
                Thread=lambda **_: SimpleNamespace(start=lambda: None))
            namespace["seen"] = lambda *_, **__: True
            namespace["run"]()
            text = (root / "verdict").read_text()
    check("affinity-gdb", reachable, after, text, expected, guest)


def peer_exit_case(reachable: int, after: int, expected: str):
    CASES.note()
    guest = Guest(reachable, after)
    with patch.dict(os.environ, {"KERNEL_PEER_EXIT_TIMEOUT": "180"}), fresh(guest):
        try:
            with contextlib.redirect_stdout(io.StringIO()):
                runpy.run_path(str(ROOT / "scripts/kernel_peer_exit_check.py"))
            text = "PASS"
        except RuntimeError as error:
            text = str(error)
    check("peer-exit", reachable, after, text, expected, guest)


def exec_enomem_case(after: int, expected: str):
    CASES.note()
    path = ROOT / "scripts/kernel_exec_enomem_check.py"
    guest = Guest(0, after, physical=1)
    with tempfile.TemporaryDirectory() as directory:
        env = {"AFFINITY_GDB_UART_LOG": str(Path(directory) / "uart"),
               "AFFINITY_GDB_VERDICT": str(Path(directory) / "verdict")}
        namespace = {"__file__": str(path), "__name__": "enomem_progress_control"}
        with patch.dict(os.environ, env, clear=True), fresh(guest):
            exec(compile(prefix(path, "\ntry:\n    run()"), str(path), "exec"),
                 namespace)
            try:
                namespace["reach"](guest.module.Breakpoint("x"), "cpu-0-marker")
                text = "reached"
            except RuntimeError as error:
                text = str(error)
    check("exec-enomem", 0, after, text, expected, guest, physical=1)


def check(name, reachable, after, text, expected, guest, physical=0):
    stalled = after == 0
    if expected not in text or (INCONCLUSIVE in text) != stalled:
        raise SystemExit(f"FAIL gdb_progress verdict control {name} stage "
                         f"{reachable} ({'STALLED' if stalled else 'QUIET'}): "
                         f"expected {expected!r}, got {text!r}")
    if guest.physical != physical:
        raise SystemExit(f"FAIL gdb_progress verdict control {name}: the tick "
                         f"reads left PhyMemMode {guest.physical}, the caller "
                         f"had {physical}")


def main():
    for after in (0, 1000):
        stalled = after == 0
        for stage, quiet in ((0, "never asked"), (1, "did not fire"),
                             (2, "never dispatched it again")):
            affinity_case(stage, after, INCONCLUSIVE + " at the " +
                          ("ask", "gate", "rerun")[stage] if stalled else quiet)
        for stage in (0, 1):
            peer_exit_case(stage, after, INCONCLUSIVE if stalled
                           else "was not reached within")
        exec_enomem_case(after, INCONCLUSIVE if stalled else
                         "was not reached within")
    report_pass("gdb_progress verdict controls",
                "affinity-gdb (ask, gate, rerun), peer-exit (armed, reply) and "
                "exec-enomem read a stalled guest as inconclusive and a quiet "
                "one as a finding, and every tick read restores the caller's "
                "PhyMemMode (#878)", cases=CASES.ran)
    return 0


if __name__ == "__main__":
    sys.exit(main())
