#!/usr/bin/env python3
"""Hold the CPU authority's mint functions to reviewed callers (#704).

kernel/kernel/cpu_authority.tkb mints CpuHere, the only index a per-CPU
store accepts. cpu_here() is the CPU it runs on; cpu_here_for_boot_probe()
names any CPU and exists for the boot probe that holds every CPU's exec
handoff at once. The compiler cannot tell the two apart at a call, so this
check fixes where the second may be called. Adding a caller is a review of
the trusted claim, made here.
"""

import re
import sys
from pathlib import Path

from pass_line import report_pass

ROOT = Path(__file__).resolve().parent.parent
KERNEL = ROOT / "kernel"

# function -> {(file, enclosing function)} allowed to call it.
ALLOWED = {
    "cpu_here_for_boot_probe": {
        ("kernel/kernel/syscall.tkb", "kernel_syscall_exec_args_overlap_probe"),
    },
}
FUNCTION = re.compile(r"^\s*(?:private\s+)?(?:noinline\s+)?fn\s+(\w+)", re.M)


def calls(text, name):
    """(enclosing function) for every call of `name` outside comments."""
    starts = [(m.start(), m.group(1)) for m in FUNCTION.finditer(text)]
    found = []
    for index, (start, fn) in enumerate(starts):
        end = starts[index + 1][0] if index + 1 < len(starts) else len(text)
        body = "\n".join(line.split("//", 1)[0]
                         for line in text[start:end].splitlines())
        if fn != name and re.search(r"\b" + name + r"\s*\(", body):
            found.append(fn)
    return found


def main():
    problems = []
    scanned = 0
    for path in sorted(KERNEL.rglob("*.tkb")):
        if "build" in path.parts:
            continue
        scanned += 1
        relative = str(path.relative_to(ROOT))
        text = path.read_text()
        for name, allowed in ALLOWED.items():
            for fn in calls(text, name):
                if (relative, fn) not in allowed:
                    problems.append(f"{relative}: {fn} calls {name}, which "
                                    "names another CPU's per-CPU slot; add it "
                                    "to ALLOWED only after review")
    if problems:
        for problem in problems:
            print(f"ERROR cpu-authority-mints: {problem}")
        sys.exit(1)
    report_pass("cpu-authority-mints",
                "the any-CPU authority mint is called only by its reviewed "
                "boot probe", files=scanned)


if __name__ == "__main__":
    main()
