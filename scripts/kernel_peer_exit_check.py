# Stop the real busy worker between its exit reply and exit syscall. A pending
# timer reschedule must preserve peer placement until the stack is released.
import os
import signal
import threading

import gdb

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from gdb_interrupt import interrupt_after  # noqa: E402


def current_record(cpu):
    execution = gdb.parse_and_eval("execution_state")[cpu]
    slot = int(execution["current_handle"]["pool_index"])
    if not bool(execution["current_live"]) or slot == 0:
        return None
    slot_type = gdb.lookup_type("struct IntrusiveSlot$ProcessRecord")
    storage = gdb.Value(slot).cast(slot_type.pointer()).dereference()["storage"]
    return storage.address.cast(gdb.lookup_type("struct ProcessRecord").pointer()).dereference()


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
    timer = interrupt_after(float(os.environ["KERNEL_PEER_EXIT_TIMEOUT"]))
    try:
        gdb.execute("continue")
    except (gdb.error, KeyboardInterrupt):
        pass
    finally:
        timer.cancel()
    if not boundary.reached:
        raise gdb.GdbError("peer exit boundary was not reached")


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
