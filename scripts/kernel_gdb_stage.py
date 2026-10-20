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
release. A vCPU stopped at EL0 also counts as parked: every kernel lock is
released before the return to user mode, and a core running a busy user
process may never reach the idle loop. #757: in the uart-wake lane, core 3
blocked in an exec's block_device_take on the block mutex core 0 held, and
core 0 is the vCPU the lane runs next, never a listed one. So after the
listed vCPUs `-- HELPER...` names vCPUs that may run (to no particular
point) to release what they hold; a helper that stops at a breakpoint of
its own ends the parking with $_takibi_park_helper_stopped set to 1, so the
caller does not run that stage a second time. It fails (gdb exits with
status 3) only if some vCPU is still not parked after every pass.

`takibi-bounded-continue SECONDS` is a `continue` that must end at a
breakpoint within SECONDS; otherwise it interrupts the target, prints where
every vCPU is (`info threads`, `thread apply all bt`) and exits with status
3. The plain `continue` it replaces was bounded only by the outer `timeout`,
which killed gdb and left no record of where the vCPUs were. GitHub issue
#865: SECONDS is one slice, not the whole bound. A stage still short of its
breakpoint after a slice in which every vCPU it runs took scheduler ticks
gets another, up to BOUNDED_SLICES; a guest the host starved is given its
time, and one that stopped taking ticks fails after the first slice as before.
`takibi-park-threads` keeps its fixed PARK_STEP_SECONDS steps on purpose: a
vCPU that does not park in one is retried on a later pass, so a short step
is never a verdict.
"""

import os
import re
import sys

import gdb

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gdb_interrupt import interrupt_after  # noqa: E402
from gdb_progress import TickCounter  # noqa: E402

NO_STOP_STATUS = 3
PARK_STEP_SECONDS = 3.0
# #757: a pass can end with the helper and a listed vCPU each still
# contending (core 0 finishing a block read under the block mutex, core 2
# queued on it); 8 passes ran out once in 9 lane runs while both were still
# making progress. A pass that parks everything returns at once, so the
# larger bound costs time only on the way to a failure.
PARK_PASSES = 24
BOUNDED_SLICES = 4


def _diagnose_and_quit(message: str) -> None:
    print(message)
    for command in ("info threads", "thread apply all bt 12"):
        try:
            gdb.execute(command)
        except gdb.error as error:
            print(f"takibi-stage: {command}: {error}")
    gdb.execute(f"quit {NO_STOP_STATUS}")


def _continue_until_breakpoint(seconds: float) -> bool:
    """Continue; True only when a breakpoint ended it within SECONDS.
    One slice: its callers decide what a slice that ran out means (#865)."""
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
    """GDB thread number -> (pc, halted or at EL0) from QEMU's `info threads`
    text and the thread's CPSR."""
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
        user = (int(gdb.parse_and_eval("$cpsr")) & 0xF) == 0
        current.switch()
        states[number] = (pc, halted or user)
    return states


def _wfi_address(function: str) -> int:
    # Read the code from the ELF, not through the selected vCPU: one
    # stopped at EL0 runs on a user translation table that does not map
    # the kernel, and the read fails (#757).
    trusted = gdb.parameter("trust-readonly-sections")
    gdb.execute("set trust-readonly-sections on", to_string=True)
    try:
        text = gdb.execute(f"disassemble {function}", to_string=True)
    finally:
        gdb.execute("set trust-readonly-sections " + ("on" if trusted else "off"),
                    to_string=True)
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
        current = gdb.selected_thread()
        running = ((current.num,) if gdb.parameter("scheduler-locking") == "on"
                   else tuple(t.num for t in gdb.selected_inferior().threads()))
        ticks = TickCounter(running)
        try:
            for _ in range(BOUNDED_SLICES):
                before = ticks.least()
                if _continue_until_breakpoint(seconds):
                    return
                if ticks.least() == before:
                    break
        finally:
            ticks.delete()
        _diagnose_and_quit(
            f"takibi-bounded-continue: no breakpoint within {seconds:g} s "
            "with no scheduler tick on some running vCPU, or within "
            f"{BOUNDED_SLICES} such slices while every one ticked")


class ParkThreads(gdb.Command):
    """takibi-park-threads FUNCTION THREAD...: run each to FUNCTION's wfi."""

    def __init__(self) -> None:
        super().__init__("takibi-park-threads", gdb.COMMAND_RUNNING)

    def invoke(self, argument: str, from_tty: bool) -> None:
        words = argument.split()
        wfi = _wfi_address(words[0])
        rest = words[1:]
        helpers = []
        if "--" in rest:
            helpers = [int(word) for word in rest[rest.index("--") + 1:]]
            rest = rest[:rest.index("--")]
        threads = [int(word) for word in rest]
        gdb.execute("set $_takibi_park_helper_stopped = 0", to_string=True)
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
            for number in helpers:
                gdb.execute(f"thread {number}", to_string=True)
                if _continue_until_breakpoint(PARK_STEP_SECONDS):
                    gdb.execute("set $_takibi_park_helper_stopped = 1",
                                to_string=True)
                    original.switch()
                    print(f"takibi-park-threads: helper {number} stopped "
                          "at a breakpoint before every vCPU was parked")
                    return
        original.switch()
        _diagnose_and_quit(
            f"takibi-park-threads: not parked after {PARK_PASSES} passes")


BoundedContinue()
ParkThreads()
