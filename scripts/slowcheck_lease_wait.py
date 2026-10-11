#!/usr/bin/env python3
"""A shell driver does not spend its deadline while its runner waits for vCPUs.

GitHub issue #719: the first four-vCPU allcheck failed race-window 633 as
"the shell never became ready" because run_kernel_churn.py's boot deadline
ran out while scripts/run_kernel_shell_qemu.sh was still waiting for its
lease. A fake runner under a pty prints `[lease] waiting`, stalls past the
driver's deadline, then is granted and becomes ready: the driver must see it
ready. The control, a runner that stalls as long without a lease line, must
still time out, so the deadline is not simply gone.
"""

import os
import pty
import sys

from pass_line import report_pass
from run_kernel_churn import READY_MARKERS, Session

DEADLINE = 1.0
STALL = 3.0


def drive(script):
    pid, terminal = pty.fork()
    if pid == 0:
        os.execvp(sys.executable, [sys.executable, "-c", script])
    session = Session(pid, terminal)
    try:
        return session.wait_for(
            lambda text: any(marker in text for marker in READY_MARKERS), DEADLINE)
    finally:
        os.close(terminal)
        os.waitpid(pid, 0)


def runner(lease_lines):
    ready = READY_MARKERS[0].decode()
    head, tail = ((r"[lease] waiting for 4 more of 4 vCPUs (budget 4): x\n",
                   r"[lease] got 4 vCPUs\n") if lease_lines else ("", ""))
    return (f"import sys, time\n"
            f"sys.stdout.write('{head}'); sys.stdout.flush()\n"
            f"time.sleep({STALL})\n"
            f"sys.stdout.write('{tail}{ready}\\n'); sys.stdout.flush()\n"
            f"time.sleep(0.5)\n")


def main():
    if not drive(runner(True)):
        print(f"FAIL lease-wait: the driver gave up after {DEADLINE:g}s while its "
              f"runner was still waiting for the vCPU lease")
        return 1
    if drive(runner(False)):
        print(f"FAIL lease-wait: a runner silent for {STALL:g}s without a lease "
              f"line was still waited for; the {DEADLINE:g}s deadline is gone")
        return 1
    report_pass("lease-wait",
                f"a runner waiting {STALL:g}s for its lease outlived a {DEADLINE:g}s "
                f"deadline, and one silent as long without a lease line did not",
                cases=2)
    return 0


if __name__ == "__main__":
    sys.exit(main())
