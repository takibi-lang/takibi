# Stop the real busy worker between its exit reply and exit syscall. A pending
# timer reschedule must preserve peer placement until the stack is released.
import os
import signal
import threading

import gdb

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from gdb_progress import (DONE, QUIET, all_threads,  # noqa: E402
                          continue_by_ticks)

# GitHub issue #867: each boundary is reached within the ticks every vCPU
# takes (scripts/gdb_progress.py), about a minute of guest time at 64 Hz;
# KERNEL_PEER_EXIT_TIMEOUT is only the host-time cap over the whole step.
STEP_TICKS = 64 * 60


def current_record(cpu):
    execution = gdb.parse_and_eval("execution_state")[cpu]
    # GitHub issue #745: a process handle's slot reference is a RegionHeld,
    # and a RegionPool slot is the record itself.
    slot = int(execution["current_handle"]["pool_index"]["address"])
    if not bool(execution["current_live"]) or slot == 0:
        return None
    record_type = gdb.lookup_type("struct ProcessRecord")
    return gdb.Value(slot).cast(record_type.pointer()).dereference()


class PeerExitBoundary(gdb.Breakpoint):
    def __init__(self, name, reply):
        super().__init__(name)
        self.reply = reply
        self.reached = False
        self.cpu = 0

    def stop(self):
        pair = gdb.parse_and_eval("workload_busy_pair")
        cpu = gdb.selected_thread().num - 1
        if int(pair["peer_exit_cpu"]) == 0 or bool(pair["peer_exit_reported"]):
            return False
        expected = 2 if self.reply else 93
        if int(gdb.parse_and_eval("$x1")) != expected:
            return False
        record = current_record(cpu)
        if record is None or int(record["pid"]) != int(pair["peer_exit_pid"]):
            return False
        self.reached = True
        self.cpu = cpu
        return True


def reach(boundary):
    threads = all_threads()
    outcome, ticks = continue_by_ticks(
        lambda: boundary.reached, threads, STEP_TICKS,
        cap_seconds=float(os.environ["KERNEL_PEER_EXIT_TIMEOUT"]))
    if outcome == DONE:
        return
    if outcome == QUIET:
        raise gdb.GdbError(f"peer exit boundary was not reached within {ticks} "
                           "ticks on every vCPU")
    raise gdb.GdbError("inconclusive: the guest stalled (a slice in which some "
                       "vCPU took no scheduler tick, or the host-time cap) "
                       "before the peer exit boundary was reached")


class PeerExitArmed(gdb.Breakpoint):
    # GitHub issue #876: arm the syscall-return breakpoint only once the
    # kernel has chosen the peer that will exit. A conditional breakpoint on
    # kernel_syscall_resume_return for the whole boot stopped the VM for a
    # Python round trip on every syscall return on every core, stretching
    # the guest against the host net peer's wall-clock budgets. Before
    # peer_exit_cpu is written, PeerExitBoundary.stop refuses every hit
    # anyway, so waiting for that write first drops no stop the check uses.
    def __init__(self):
        super().__init__("workload_busy_pair.peer_exit_cpu",
                         gdb.BP_WATCHPOINT, gdb.WP_WRITE)
        self.reached = False

    def stop(self):
        if int(gdb.parse_and_eval("workload_busy_pair.peer_exit_cpu")) == 0:
            return False
        self.reached = True
        return True


armed = PeerExitArmed()
reach(armed)
armed.delete()
reply = PeerExitBoundary("kernel_syscall_resume_return", True)
reach(reply)
record = current_record(reply.cpu)
if os.environ.get("KERNEL_PEER_EXIT_CONTROL") == "unpin":
    # Negative control: restore the formerly wide mask at the real reply.
    gdb.execute(f"set ((struct ProcessRecord *){int(record.address)})->affinity_mask = 3")
mask = int(record["affinity_mask"])
if reply.cpu == 0 or mask != 1 << reply.cpu:
    raise gdb.GdbError("armed peer exit still permits migration before exit syscall")
# Exercise the syscall-return scheduling path in this exact reply window.
gdb.execute(f"set execution_state[{reply.cpu}].reschedule_pending = 1")
reply.delete()
exit_call = PeerExitBoundary("kernel_syscall_dispatch", False)
reach(exit_call)
if exit_call.cpu != reply.cpu:
    raise gdb.GdbError("armed peer exit migrated after its reply")
exit_call.delete()
print("PASS kernel/qemu peer-exit: a pending reschedule preserved peer placement from reply to exit syscall")
