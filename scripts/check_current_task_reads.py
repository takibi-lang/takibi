#!/usr/bin/env python3
"""Task context reaches current through one accessor (#1321).

execution_state selects by cpu_id(), so at the preemption flip a task moved
between reading current_live and current_handle would read a peer's current.
kernel_process_current_read takes the pair once inside a preempt_off region
and hands back a snapshot, which stays valid because a running task's own
current does not change when it moves.

This check keeps the direct reads closed: every function that indexes
`execution_state[execution_cpu_index()].current_live` or `.current_handle` is
listed with why it does not need the accessor. A new one is refused, and so
is an entry whose function no longer does it. The indexed-by-`core` readers
(DDB, the protocol observation) do not select by this CPU and are not counted.

It does not prove a listed function's authority; kernel/kernel/process.tkb's
comments and the reasons below state it.
"""

import re
import sys
from pathlib import Path

from pass_line import report_pass
from source_scan import code_only

SOURCE = Path("kernel/kernel/process.tkb")

ACCESSOR = "the accessor itself, inside its preempt_off region"
WRITER = "writes current under the run lock (IRQs masked), and its reads are under that lock"
STOPPED = "fail-stop or DDB path: world stopped or IRQs masked, and it must not depend on a region mint, whose check stops the CPU"
EVIDENCE = "a report taken under the run lock (IRQs masked) on the way to a lookup miss"
FIXTURE = "boot fixture rewriting current with process dispatch closed, pinned by the boot sequence"

LISTED = {
    "kernel_process_current_read": ACCESSOR,
    "kernel_process_stopped_entry_generation": STOPPED,
    "kernel_process_stopped_current_slot": STOPPED,
    "kernel_process_crash_frame_usable": STOPPED,
    "kernel_process_current_stopped_crash_detail": STOPPED,
    "kernel_process_crash_state": STOPPED,
    "kernel_process_crash_wait_reason": STOPPED,
    "scheduled_process_record_locked": EVIDENCE,
    "kernel_process_execution_reset": FIXTURE,
    "kernel_process_fanout_probe": FIXTURE,
    "kernel_process_scheduler_probe": FIXTURE,
    "kernel_process_exit_continuation_probe": FIXTURE,
    "kernel_process_boot_handoff": WRITER,
    "kernel_process_core0_leave_excluded": WRITER,
    "kernel_process_migrate_current": WRITER,
    "kernel_process_secondary_start_reserved": WRITER,
    "kernel_process_schedule_reserved": WRITER,
    "kernel_process_tick_leave_excluded": WRITER,
    "kernel_process_block_to_idle": WRITER,
    "kernel_process_block_reserved": WRITER,
    "kernel_process_clone_begin": WRITER,
    "kernel_process_clone_rollback": WRITER,
    "kernel_process_exit_reserved": WRITER,
    "kernel_process_child_exit": WRITER,
}

READ = re.compile(
    r"execution_state\s*\[\s*(?:execution_cpu_index\s*\(\s*\)|index)\s*\]\s*\.\s*current_(?:live|handle)")
FN = re.compile(r"^(?:private\s+|inline\s+|exception\s+)*fn\s+(\w+)", re.M)


def readers_of(text):
    code = code_only(text)
    starts = [(m.start(), m.group(1)) for m in FN.finditer(code)]
    found = set()
    for hit in READ.finditer(code):
        owner = None
        for start, name in starts:
            if start > hit.start():
                break
            owner = name
        found.add(owner)
    return found


def problems_of(text, listed):
    found = readers_of(text)
    problems = []
    for name in sorted(found - set(listed), key=str):
        problems.append(
            f"{name}: reads this CPU's current directly: use "
            "kernel_process_current_read, or list it with its authority (#1321)")
    for name in sorted(set(listed) - found):
        problems.append(f"{name}: listed but reads no current directly: remove its entry")
    return problems


def controls():
    good = "fn a() { let x = execution_state[execution_cpu_index()].current_live; }\n"
    listed = {"a": WRITER}
    if problems_of(good, listed):
        sys.exit("ERROR current-task-reads: control: a listed reader was refused")
    cases = {
        "new reader": (good + "private fn b() -> usize { return execution_state[execution_cpu_index()].current_handle.generation; }\n", listed),
        "spaced reader": ("fn a() { execution_state[ execution_cpu_index() ] . current_handle; }\n", {}),
        "stale entry": ("fn c() {}\n", listed),
    }
    for label, (text, entries) in cases.items():
        if not problems_of(text, entries):
            sys.exit(f"ERROR current-task-reads: control '{label}' was not refused")
    if problems_of("// execution_state[execution_cpu_index()].current_live\n", {}):
        sys.exit("ERROR current-task-reads: control: a comment was refused")
    return len(cases) + 2


def main():
    count = controls()
    problems = problems_of(SOURCE.read_text(encoding="ascii"), LISTED)
    if problems:
        for problem in problems:
            print(f"ERROR current-task-reads: {problem}")
        sys.exit(1)
    report_pass("current-task-reads",
                f"{len(LISTED)} functions read current directly, each with its "
                f"authority; {count} controls", files=1)


if __name__ == "__main__":
    main()
