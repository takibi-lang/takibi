"""GitHub issue #865: bound a gdb stage by the guest's progress, not host seconds.

A gdb stage that resumes the guest until a breakpoint used to give it one
fixed number of host seconds. The guest's steps are deterministic in guest
progress, but how many host seconds they take depends on how much CPU QEMU
gets; under host load (#864, loadavg 24) a step that takes milliseconds idle
did not finish within ten seconds. And the same timeout decided the negative
verdicts -- "the reader is asleep", "the control left the waiter asleep" --
so a starved guest could read as a defect, or as a control that passed.

continue_by_ticks() reads the scheduler ticks the vCPUs that matter took
from the kernel's own per-core counter, secondary_tick_count (core 0's tick
bumps entry 0), between host-time slices, and resumes until one of three
outcomes:

  DONE     the stage's own condition holds (its breakpoint was hit);
  QUIET    every listed vCPU took `ticks` ticks and the condition never held:
           the guest had that much time, so "it did not happen" is a finding;
  STALLED  a slice in which some listed vCPU took no tick, or the host-time
           cap: the guest was not given the time, so nothing can be concluded.

A negative verdict may only be drawn from QUIET. A vCPU spinning with its
interrupts masked takes no tick, so a stage whose expected outcome is such a
spin decides from where the vCPU stands once it STALLS.

The ticks are read, not counted by breakpoints: a breakpoint on the tick
handlers stops every vCPU on every tick, and over the ddb uart lane's
workload that perturbation hung the guest (#871, found by #867). The read
goes through QEMU's physical-memory mode, since the selected vCPU may be at
EL0 under a user table that does not map the kernel (#701, #757); the kernel
is identity-mapped, so the address is the same; each read restores the caller's
mode (#878). The counter's layout (one
8-byte word per core) is held by scripts/check_secondary_tick_count_layout.py.

Every gdb Python check bounds its continues through this module or says why
not (scripts/check_gdb_wallclock_continue.py).
"""

import contextlib
import os
import re
import sys

import gdb

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gdb_interrupt import interrupt_after  # noqa: E402
from gdb_tick_count import tick_count_progress  # noqa: E402

# How long one resume may run in host seconds before the ticks are looked at.
SLICE_SECONDS = 10.0
# The whole stage's host-time ceiling, whatever the ticks say. Under the
# outer gdb `timeout`.
CAP_SECONDS = 180.0

DONE = "done"
QUIET = "quiet"
STALLED = "stalled"


class Counter(gdb.Breakpoint):
    """Counts passes of `spec` by the listed gdb threads (all when None)
    without stopping the guest; stops only on reaching a nonzero limit.

    gdb calls stop() before it evaluates a CLI condition, and calls it for
    every thread, so the thread filter lives here, not in `.condition`."""

    def __init__(self, spec: str, threads=None, limit: int = 0):
        super().__init__(spec, internal=True)
        self.threads = None if threads is None else frozenset(threads)
        self.limit = limit
        self.counts = {}

    @property
    def count(self) -> int:
        return sum(self.counts.values())

    def least(self, threads) -> int:
        return min(self.counts.get(number, 0) for number in threads)

    def stop(self) -> bool:
        thread = gdb.selected_thread()
        number = thread.num if thread is not None else 0
        if self.threads is not None and number not in self.threads:
            return False
        self.counts[number] = self.counts.get(number, 0) + 1
        return self.limit != 0 and self.count >= self.limit


def tick_progress(threads):
    """The least ticks any listed gdb thread's core took since this call,
    read from secondary_tick_count (scripts/gdb_tick_count.py) in physical
    mode, without a breakpoint. Each read restores the caller's mode
    (#878), so a caller that keeps physical mode on for its own accesses
    keeps it."""
    with physical():
        read = tick_count_progress(threads)

    def least() -> int:
        with physical():
            return read()
    return least


def physical_mode() -> bool:
    """Whether QEMU's gdbstub reads memory physically now. The stub answers
    `qqemu.PhyMemMode` with 1 or 0; gdb prints the reply as received: "N"."""
    reply = gdb.execute("maintenance packet qqemu.PhyMemMode", to_string=True)
    match = re.search(r'received: "([01])"', reply or "")
    if match is None:
        raise gdb.GdbError(f"QEMU did not report its PhyMemMode: {reply!r}")
    return match.group(1) == "1"


def set_physical(on: bool) -> None:
    gdb.execute(f"maintenance packet Qqemu.PhyMemMode:{1 if on else 0}",
                to_string=True)


@contextlib.contextmanager
def physical():
    """Physical-memory mode for the body, then the caller's mode again
    (#878: it used to be forced off, which made console-hold, whose own
    accesses need it on, bypass tick_progress)."""
    saved = physical_mode()
    if not saved:
        set_physical(True)
    try:
        yield
    finally:
        if not saved:
            set_physical(False)


def resume_slice(seconds: float = SLICE_SECONDS, command: str = "continue") -> bool:
    """One resume, interrupted after `seconds` of host time. False when it
    did not end on its own (the interrupt stopped it, or gdb refused it).
    Only continue_by_ticks() and the slices it drives call this."""
    timer = interrupt_after(max(seconds, 1.0))
    try:
        gdb.execute(command)
    except (gdb.error, KeyboardInterrupt):
        return False
    finally:
        timer.cancel()
    return True


def all_threads() -> tuple:
    return tuple(thread.num for thread in gdb.selected_inferior().threads())


def continue_by_ticks(done, threads, ticks: int, resume=None,
                      slice_seconds: float = SLICE_SECONDS,
                      cap_seconds: float = CAP_SECONDS,
                      progress=None):
    """Resume until done() holds, the listed gdb threads each took `ticks`
    ticks, or the guest stalls. Returns (outcome, least ticks taken).

    `resume` runs one slice (default: resume_slice()). `progress`, when
    given, replaces the tick count as the measure of guest progress: a
    callable returning a number that grows while the listed vCPUs run."""
    measure = tick_progress(threads) if progress is None else progress
    waited = 0.0
    while waited < cap_seconds:
        before = measure()
        if resume is None:
            resume_slice(slice_seconds)
        else:
            resume()
        waited += slice_seconds
        if done():
            return DONE, measure()
        taken = measure()
        if taken >= ticks:
            return QUIET, taken
        if taken == before:
            return STALLED, taken
    return STALLED, measure()
