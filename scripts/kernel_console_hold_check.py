# Stop at an actual peer ConsoleGuard hold before the host injects UART BREAK.
# GDB owns the stop; the driver injects BREAK while it remains stopped, then
# releases this rendezvous. This is delivery under a held lock, not a claim
# that an IRQ-masking peer can acknowledge world-stop before unlocking.
import os
from pathlib import Path
import time
import gdb

ready = Path(os.environ["KERNEL_CONSOLE_HOLD_READY"])
release = Path(os.environ["KERNEL_CONSOLE_HOLD_RELEASE"])
# Physical accesses: the stopped CPU may be running EL0 under a user TTBR0,
# where the kernel's addresses are not mapped and a write to the arm flag
# fails ("Cannot access memory", #701). The kernel is identity-mapped, so a
# physical access names the same bytes on every CPU, as
# run_kernel_ddb_qemutest.sh already does for its checkpoint dump.
gdb.execute("maintenance packet Qqemu.PhyMemMode:1")
gdb.execute("break console_ddb_hold_checkpoint")
gdb.execute("set *(char *)&kernel_ddb_console_hold_armed = 1")
gdb.execute("continue")
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
