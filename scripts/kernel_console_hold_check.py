# Stop at an actual peer ConsoleGuard hold before the host injects UART BREAK.
# GDB owns the stop; the driver injects BREAK while it remains stopped, then
# releases this rendezvous. This is delivery under a held lock, not a claim
# that an IRQ-masking peer can acknowledge world-stop before unlocking.
import os
from pathlib import Path
import sys
import time
import gdb

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gdb_progress import (DONE, QUIET, all_threads,  # noqa: E402
                          continue_by_ticks)

# GitHub issue #867: the hold is reached within the ticks every vCPU takes
# (scripts/gdb_progress.py), about a minute of guest time at 64 Hz, not
# within whatever host time the outer timeout left.
HOLD_TICKS = 64 * 60

ready = Path(os.environ["KERNEL_CONSOLE_HOLD_READY"])
release = Path(os.environ["KERNEL_CONSOLE_HOLD_RELEASE"])
# Physical accesses: the stopped CPU may be running EL0 under a user TTBR0,
# where the kernel's addresses are not mapped and a write to the arm flag
# fails ("Cannot access memory", #701). The kernel is identity-mapped, so a
# physical access names the same bytes on every CPU, as
# run_kernel_ddb_qemutest.sh already does for its checkpoint dump.
gdb.execute("maintenance packet Qqemu.PhyMemMode:1")
hold = gdb.Breakpoint("console_ddb_hold_checkpoint")
gdb.execute("set *(char *)&kernel_ddb_console_hold_armed = 1")
threads = all_threads()
# PhyMemMode stays on for the reads below: continue_by_ticks's tick reads
# restore the caller's mode (#878).
outcome, ticks = continue_by_ticks(lambda: hold.hit_count > 0, threads, HOLD_TICKS)
if outcome == QUIET:
    raise gdb.GdbError(f"console hold checkpoint was not reached within {ticks} "
                       "ticks on every vCPU")
if outcome != DONE:
    raise gdb.GdbError("inconclusive: the guest stalled (a slice in which some "
                       "vCPU took no scheduler tick, or the host-time cap) "
                       "before the console hold checkpoint")
phase = int(gdb.parse_and_eval("*(unsigned long *)&console_ddb_phase"))
held = int(gdb.parse_and_eval("*(unsigned long *)&console_tx_lock"))
if phase != 1 or held != 1:
    raise gdb.GdbError(f"console BREAK injection lacks a held guard: phase={phase}, lock={held}")
print("PASS console BREAK injection: peer guard and phase are held")
ready.touch()
deadline = time.monotonic() + 20.0
while not release.exists():
    if time.monotonic() >= deadline:
        raise gdb.GdbError("console BREAK injection was not released by the host")
    time.sleep(0.01)
gdb.execute("detach")
