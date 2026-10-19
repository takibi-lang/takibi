#!/usr/bin/env python3
"""A GDB that runs one vCPU at a time first parks the ones it leaves frozen.

With scheduler-locking on, `continue` resumes only the selected vCPU; every
other one stays wherever GDB's all-stop caught it, and that can be inside a
spinlock. The one being run then spins on that lock for good. GitHub issue
#795: kernelcheck-oops-qemu's concurrent_fault mode hung 1 run in 60 under
load; freezing core 2 inside its idle loop's hold of
scheduled_process_run_lock made core 0 spin on that lock every time. #757 is
the same shape in the uart-wake lane.

So every line under scripts/ that turns scheduler-locking on must be
followed, within PARK_WINDOW lines, by `takibi-park-threads`
(scripts/kernel_gdb_stage.py), which runs each other vCPU alone to the idle
loop's `wfi` first. A site where that is not needed or not yet done says why
in a comment containing `scheduler-locking-waiver:` within WAIVER_WINDOW
lines above it, naming the reason (cores not yet online, a pinned vCPU
count, an open issue).

Exit code only (0 = pass, 1 = fail).
"""

import pathlib
import re
import sys

from pass_line import report_pass

SCRIPTS = pathlib.Path("scripts")
PARK = "takibi-park-threads"
WAIVER = "scheduler-locking-waiver:"
PARK_WINDOW = 4
WAIVER_WINDOW = 8
# A line that may set scheduler-locking to anything but off.
LOCKING = re.compile(r"scheduler-locking(?!\s+off\b)")
COMMENT = re.compile(r"^\s*#")
SELF = {"check_gdb_scheduler_locking.py",
        "check_gdb_scheduler_locking_controls.py",
        "kernel_gdb_stage.py"}


def main() -> int:
    sites = 0
    scanned = 0
    failures = []
    paths = sorted(SCRIPTS.glob("*.sh")) + sorted(SCRIPTS.glob("*.py"))
    for path in paths:
        if path.name in SELF:
            continue
        scanned += 1
        lines = path.read_text(encoding="utf-8").splitlines()
        for index, line in enumerate(lines):
            if COMMENT.match(line) or not LOCKING.search(line):
                continue
            sites += 1
            after = lines[index + 1:index + 1 + PARK_WINDOW]
            before = lines[max(0, index - WAIVER_WINDOW):index]
            if any(PARK in row for row in after):
                continue
            waiver = [row for row in before
                      if COMMENT.match(row) and WAIVER in row]
            if waiver and waiver[-1].split(WAIVER, 1)[1].strip():
                continue
            failures.append(f"{path}:{index + 1}")
    if failures:
        for where in failures:
            print(f"ERROR\tgdb-scheduler-locking: {where} runs one vCPU at a "
                  "time and leaves the others frozen wherever the all-stop "
                  "caught them, possibly holding a lock (#795). Follow it "
                  f"with `{PARK}`, or say why not in a `# {WAIVER} <reason>` "
                  "comment above it")
        print(f"FAIL gdb-scheduler-locking: {len(failures)} site(s)")
        return 1
    report_pass("gdb-scheduler-locking",
                f"all {sites} scheduler-locking stage(s) park the frozen "
                "vCPUs or say why not", files=scanned)
    return 0


if __name__ == "__main__":
    sys.exit(main())
