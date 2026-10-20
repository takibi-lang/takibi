"""GitHub issue #865: bound a gdb stage by the guest's progress, not host seconds.

A gdb stage that resumes the guest until a breakpoint used to give it one
fixed number of host seconds. The guest's steps are deterministic in guest
progress, but how many host seconds they take depends on how much CPU QEMU
gets; under host load (#864, loadavg 24) a step that takes milliseconds idle
did not finish within ten seconds. And the same timeout decided the negative
verdicts -- "the reader is asleep", "the control left the waiter asleep" --
so a starved guest could read as a defect, or as a control that passed.

continue_by_ticks() counts the scheduler ticks the vCPUs that matter take
(timer_irq_handler on CPU0; kernel_secondary_timer_schedule on a secondary,
whose tick never enters timer_irq_handler) and resumes in host-time slices
until one of three outcomes:

  DONE     the stage's own condition holds (its breakpoint was hit);
  QUIET    every listed vCPU took `ticks` ticks and the condition never held:
           the guest had that much time, so "it did not happen" is a finding;
  STALLED  a slice in which some listed vCPU took no tick, or the host-time
           cap: the guest was not given the time, so nothing can be concluded.

A negative verdict may only be drawn from QUIET. A vCPU spinning with its
interrupts masked takes no tick, so a stage whose expected outcome is such a
spin measures that spin itself (Counter on the loop instruction) instead.

Every gdb Python check bounds its continues through this module or says why
not (scripts/check_gdb_wallclock_continue.py).
"""

import os
import sys

import gdb

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gdb_interrupt import interrupt_after  # noqa: E402

TICK_FUNCTIONS = ("timer_irq_handler", "kernel_secondary_timer_schedule")
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


class TickCounter:
    """Scheduler ticks taken by each listed gdb thread."""

    def __init__(self, threads) -> None:
        self.threads = tuple(threads)
        self._counters = [Counter(name, self.threads) for name in TICK_FUNCTIONS]

    def least(self) -> int:
        return min(sum(counter.counts.get(number, 0) for counter in self._counters)
                   for number in self.threads)

    def delete(self) -> None:
        for counter in self._counters:
            counter.delete()


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
    counter = TickCounter(threads) if progress is None else None
    measure = counter.least if counter is not None else progress
    waited = 0.0
    try:
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
    finally:
        if counter is not None:
            counter.delete()
