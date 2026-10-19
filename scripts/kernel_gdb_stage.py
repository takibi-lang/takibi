"""GitHub issue #795: staging commands for a GDB that runs one vCPU at a time.

Sourced into gdb-multiarch by scripts/run_kernel_oops_qemutest.sh. A staged
lane stops the whole machine (GDB all-stop), sets scheduler-locking on, and
then resumes one vCPU at a time. Every vCPU it does not resume stays exactly
where the all-stop caught it -- and the all-stop catches a core wherever it
happens to be, including inside a spinlock. A vCPU frozen holding a lock
leaves the one being run spinning on it for good. #795: concurrent_fault
hung 1 run in 60 under load with core 0's stage never reaching its
breakpoint; core 2 frozen on purpose at process_run_unlock, the run lock
held, made the same hang every time, with core 0 in spin_lock on
scheduled_process_run_lock.

`takibi-park-threads FUNCTION THREAD...` moves each listed vCPU, one at a
time, to a point where it holds nothing: the one `wfi` instruction in
FUNCTION (the idle loop), or already halted in a WFI. A vCPU blocked on a
lock another listed vCPU holds is cut off after a short bound and retried
after the others have run, so a holder frozen anywhere gets its turn to
release. It fails (gdb exits with status 3) only if some vCPU is still not
parked after every pass.

`takibi-bounded-continue SECONDS` is a `continue` that must end at a
breakpoint within SECONDS; otherwise it interrupts the target, prints where
every vCPU is (`info threads`, `thread apply all bt`) and exits with status
3. The plain `continue` it replaces was bounded only by the outer `timeout`,
which killed gdb and left no record of where the vCPUs were.
"""

import os
import re
import sys

import gdb

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gdb_interrupt import interrupt_after  # noqa: E402

NO_STOP_STATUS = 3
PARK_STEP_SECONDS = 3.0
PARK_PASSES = 8


def _diagnose_and_quit(message: str) -> None:
    print(message)
    for command in ("info threads", "thread apply all bt 12"):
        try:
            gdb.execute(command)
        except gdb.error as error:
            print(f"takibi-stage: {command}: {error}")
    gdb.execute(f"quit {NO_STOP_STATUS}")


def _continue_until_breakpoint(seconds: float) -> bool:
    """Continue; True only when a breakpoint ended it within SECONDS."""
    stops = []

    def note(event: gdb.StopEvent) -> None:
        stops.append(isinstance(event, gdb.BreakpointEvent))

    gdb.events.stop.connect(note)
    timer = interrupt_after(seconds)
    try:
        gdb.execute("continue", to_string=True)
    except (gdb.error, KeyboardInterrupt):
        pass
    finally:
        timer.cancel()
        gdb.events.stop.disconnect(note)
    return bool(stops) and stops[-1]


def _thread_states() -> dict:
    """GDB thread number -> (pc, halted) from QEMU's `info threads` text."""
    states = {}
    text = gdb.execute("info threads", to_string=True)
    for thread in gdb.selected_inferior().threads():
        number = thread.num
        line = next((row for row in text.splitlines()
                     if re.match(rf"^\*?\s*{number}\s", row)), "")
        halted = "[halted" in line
        current = gdb.selected_thread()
        thread.switch()
        pc = int(gdb.parse_and_eval("$pc"))
        current.switch()
        states[number] = (pc, halted)
    return states


def _wfi_address(function: str) -> int:
    text = gdb.execute(f"disassemble {function}", to_string=True)
    hits = [int(match.group(1), 16) for match in
            re.finditer(r"^\s*(?:=>\s*)?(0x[0-9a-f]+)\s.*\twfi\s*$", text, re.M)]
    if len(hits) != 1:
        raise gdb.GdbError(f"takibi-park-threads: {function} has {len(hits)} wfi")
    return hits[0]


class BoundedContinue(gdb.Command):
    """takibi-bounded-continue SECONDS: continue; fail unless a breakpoint stops it."""

    def __init__(self) -> None:
        super().__init__("takibi-bounded-continue", gdb.COMMAND_RUNNING)

    def invoke(self, argument: str, from_tty: bool) -> None:
        seconds = float(argument)
        if _continue_until_breakpoint(seconds):
            return
        _diagnose_and_quit(
            f"takibi-bounded-continue: no breakpoint within {seconds:g} s")


class ParkThreads(gdb.Command):
    """takibi-park-threads FUNCTION THREAD...: run each to FUNCTION's wfi."""

    def __init__(self) -> None:
        super().__init__("takibi-park-threads", gdb.COMMAND_RUNNING)

    def invoke(self, argument: str, from_tty: bool) -> None:
        words = argument.split()
        wfi = _wfi_address(words[0])
        threads = [int(word) for word in words[1:]]
        if gdb.parameter("scheduler-locking") != "on":
            raise gdb.GdbError("takibi-park-threads needs scheduler-locking on")
        original = gdb.selected_thread()
        for _ in range(PARK_PASSES):
            states = _thread_states()
            waiting = [number for number in threads
                       if not (states[number][1] or states[number][0] == wfi)]
            if not waiting:
                original.switch()
                print("takibi-park-threads: parked " +
                      " ".join(str(number) for number in threads))
                return
            for number in waiting:
                gdb.execute(f"thread {number}", to_string=True)
                gdb.execute(f"break *{wfi:#x} thread {number}", to_string=True)
                breakpoint = gdb.breakpoints()[-1]
                try:
                    _continue_until_breakpoint(PARK_STEP_SECONDS)
                finally:
                    breakpoint.delete()
        original.switch()
        _diagnose_and_quit(
            f"takibi-park-threads: not parked after {PARK_PASSES} passes")


BoundedContinue()
ParkThreads()
