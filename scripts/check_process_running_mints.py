#!/usr/bin/env python3
"""Every caller of process_running_here is declared here (GitHub issue #693).

process_running_here turns "this CPU's current process" into
ProcessRunning[p], the evidence a process reads its own record through. It is
the one trusted point of that evidence: a running process is not reaped
(kernel/models/StackOwnership.tla), so the record cannot go while the
evidence lives. What can go wrong is the set of callers growing quietly, one
convenient mint at a time. Step 2b of #693 moves the mint to the syscall
entry and passes the evidence down, which shrinks this list; until then the
list is the number.

Exit code only (0 = pass, 1 = fail).
"""

import pathlib
import re
import sys

from pass_line import report_pass

ROOT = pathlib.Path("kernel")
DEFINING = "process_running_here"

ALLOWED = {
    "kernel_process_block_wait4",
    "kernel_process_child_exit",
    "kernel_process_clone_begin",
    "kernel_process_clone_context_install",
    "kernel_process_clone_evidence",
    "kernel_process_clone_rollback",
    "kernel_process_current_arm_deadline",
    "kernel_process_current_clear_deadline",
    "kernel_process_current_deadline_ticks",
    "kernel_process_current_exit_has_waiter",
    "kernel_process_current_has_relative",
    "kernel_process_current_pending_block_reason",
    "kernel_process_current_prepare_signal_wait",
    "kernel_process_current_set_pending_block",
    "kernel_process_current_set_sigchld_action",
    "kernel_process_current_set_sigchld_ignored",
    "kernel_process_current_set_wait4_pid",
    "kernel_process_current_sigchld_action",
    "kernel_process_current_sigchld_ignored",
    "kernel_process_is_child",
    "kernel_process_last_reaped_pid",
    "kernel_process_parent_is_root",
    "kernel_process_uart_record_parent_progress",
}

FN_RE = re.compile(r"^(?:private )?fn (\w+)\(")
CALL_RE = re.compile(r"\bprocess_running_here\(\)")


def main() -> int:
    found = set()
    scanned = 0
    for path in sorted(ROOT.rglob("*.tkb")):
        if "build" in path.parts:
            continue
        scanned += 1
        enclosing = None
        for line in path.read_text().splitlines():
            match = FN_RE.match(line)
            if match:
                enclosing = match.group(1)
            if CALL_RE.search(line) and not FN_RE.match(line):
                found.add(enclosing)
    found.discard(DEFINING)
    failures = []
    for name in sorted(found - ALLOWED):
        failures.append(f"{name} mints ProcessRunning and is not declared here")
    for name in sorted(ALLOWED - found):
        failures.append(f"{name} is declared here but no longer mints; remove it")
    if failures:
        for line in failures:
            print("FAIL process-running-mints: " + line, file=sys.stderr)
        return 1
    report_pass("process-running-mints",
                f"{len(found)} declared caller(s) of process_running_here "
                f"across {scanned} files", files=scanned, callers=len(found))
    return 0


if __name__ == "__main__":
    sys.exit(main())
