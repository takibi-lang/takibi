#!/usr/bin/env python3
"""lease_wait reads a runner's transcript the way the shell drivers need.

GitHub issue #719: a driver that restarts its deadline, or names the vCPU
lease in its timeout, decides from scripts/lease_wait.py whether the runner
under it is still waiting. Synthetic transcripts only; the timing control is
scripts/slowcheck_lease_wait.py.
"""

import sys

from lease_wait import lease_pending, timed_out_waiting
from pass_line import report_pass

WAIT = b"[lease] waiting for 2 more of 4 vCPUs (budget 24): x\n"
ALLOC = b"[lease] waiting for the vCPU allocator (another runner is waiting for slots)\n"
GOT = b"[lease] got 4 vCPUs\n"
BOOT = b"[kernel/qemu] interactive UART session\n"

CASES = (
    ("neither", BOOT, False),
    ("empty", b"", False),
    ("waiting only", BOOT + WAIT, True),
    ("allocator wait only", BOOT + ALLOC, True),
    ("waiting then got", WAIT + GOT + BOOT, False),
    ("allocator, slots, then got", ALLOC + WAIT + GOT, False),
    ("got then waiting again", WAIT + GOT + BOOT + WAIT, True),
    ("got alone", GOT, False),
)


def main():
    problems = []
    for name, transcript, pending in CASES:
        for form in (transcript, bytearray(transcript), transcript.replace(b"\n", b"\r\n")):
            if lease_pending(form) != pending:
                problems.append(f"{name}: lease_pending was {not pending}")
            message = timed_out_waiting(form)
            if pending and (message is None or "vCPU lease" not in message):
                problems.append(f"{name}: a timeout during the wait does not name the lease")
            if not pending and message is not None:
                problems.append(f"{name}: a boot timeout was blamed on the lease")
    if problems:
        print("FAIL lease-wait controls:")
        for problem in problems:
            print(f"  {problem}")
        return 1
    report_pass("lease-wait controls",
                "waiting, allocator waits, waits after a grant and transcripts without a "
                "wait are each classified, and only a pending wait is named in a timeout",
                cases=len(CASES))
    return 0


if __name__ == "__main__":
    sys.exit(main())
