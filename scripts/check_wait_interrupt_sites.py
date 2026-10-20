#!/usr/bin/env python3
"""Every WaitInterrupt producer in the syscall layer is a reviewed one.

SyscallAction::WaitInterrupt keeps the calling process Running while its CPU
waits for an interrupt and reruns the syscall. That is right only for a short,
transient condition another CPU ends on its own (a listener claim, an ext2
mutation in flight, a zombie whose CPU has not left its stack). A wait for an
event -- UART RX or TX, a frame, a deadline, a signal -- must Block on its wake
source instead: a Running process in an EL1 retry loop is the shape behind
#840's DDB failures and #866.

This check counts, per function of kernel/kernel/syscall.tkb, the `return`
statements that produce WaitInterrupt (or SyscallIoResult::InterruptWait or
SyscallDeadlineResult::WaitInterrupt), and requires the counts to equal
ALLOWED below, each with its reason. A new producer fails until someone writes
down why it is not an event wait; a removed one fails until its entry goes.
"""

import re
import sys
from pathlib import Path

from pass_line import report_pass
from source_scan import code_only

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "kernel" / "kernel" / "syscall.tkb"

PRODUCER = re.compile(
    r"return\b[^;]*\b(SyscallAction::WaitInterrupt|SyscallIoResult::InterruptWait"
    r"|SyscallDeadlineResult::WaitInterrupt)\b")
FUNCTION = re.compile(r"^(?:private\s+)?fn\s+([A-Za-z_0-9]+)")

# function -> (count, reason)
ALLOWED = {
    "kernel_syscall_dispatch_action": (
        9, "transient: ext2 mutation in flight, listener claim busy, wait4 "
           "zombie stack held or zombie pick race, and the pass-through of "
           "an exit with no successor and of timed waits"),
    "syscall_deadline_wait": (
        2, "core 0 timed-wait retry; removed by #852"),
    "syscall_signal_wait": (
        2, "core 0 timed-wait retry; removed by #852"),
    "syscall_ppoll_dispatch": (
        4, "ppoll(nfds=0, NULL) (#870), the invalid-slot fallback, and "
           "pass-through of syscall_deadline_wait"),
    "syscall_read_uart": (
        1, "invalid-slot fallback: no scheduled process to block"),
    "syscall_io_action": (
        1, "maps syscall_read_uart's invalid-slot fallback"),
    "syscall_execve_current": (
        2, "pass-through of an exit with no successor"),
    "syscall_signal_deliver": (
        1, "pass-through of an exit with no successor"),
}


def producers(text):
    counts = {}
    function = None
    for line in code_only(text).splitlines():
        match = FUNCTION.match(line)
        if match:
            function = match.group(1)
        if PRODUCER.search(line):
            counts[function] = counts.get(function, 0) + 1
    return counts


def main():
    counts = producers(SOURCE.read_text())
    failures = []
    for function in sorted(set(counts) | set(ALLOWED)):
        found = counts.get(function, 0)
        allowed = ALLOWED.get(function, (0, ""))[0]
        if found != allowed:
            failures.append(
                f"{function}: {found} WaitInterrupt return(s), {allowed} "
                "allowed. An event wait must Block on its wake source "
                "(#866); a transient retry needs an ALLOWED entry with its "
                "reason in scripts/check_wait_interrupt_sites.py")
    if failures:
        for failure in failures:
            print(f"FAIL wait-interrupt-sites: {failure}")
        return 1
    report_pass("wait-interrupt-sites",
                f"{sum(counts.values())} reviewed WaitInterrupt return(s) in "
                f"{len(counts)} function(s)",
                functions=len(counts), returns=sum(counts.values()))
    return 0


if __name__ == "__main__":
    sys.exit(main())
