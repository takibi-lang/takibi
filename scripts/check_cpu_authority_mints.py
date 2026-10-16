#!/usr/bin/env python3
"""Hold the CPU authority's mint functions to reviewed callers (#704).

kernel/kernel/cpu_authority.tkb mints CpuHere, the only index a per-CPU
store accepts. A preempt_off block mints it through the private
preempt_off_enter(), which the compiler checks (#638). Two public mints
bypass the block: cpu_here_across_blocking() for ext2's scratch held across
block I/O, and cpu_here_for_boot_probe(), which names any CPU for the boot
probe that holds every CPU's exec handoff at once. The compiler cannot tell
them apart at a call, so this check fixes where each may be called. Adding
a caller is a review of the trusted claim, made here.
"""

import re
import sys
from pathlib import Path

from pass_line import report_pass

ROOT = Path(__file__).resolve().parent.parent
KERNEL = ROOT / "kernel"

# function -> {(file, enclosing function)} allowed to call it.
ALLOWED = {
    # #638: ext2 holds per-CPU scratch across block I/O, so no preempt_off
    # block can cover it; any other caller belongs in a preempt_off block.
    "cpu_here_across_blocking": {
        ("kernel/fs/ext2/ext2.tkb", "*"),
    },
    "cpu_here_for_boot_probe": {
        ("kernel/kernel/syscall.tkb", "kernel_syscall_exec_args_overlap_probe"),
    },
}
FUNCTION = re.compile(r"^\s*(?:private\s+)?(?:noinline\s+)?fn\s+(\w+)", re.M)


def references(text, name):
    """(enclosing function) for every reference to `name` outside comments.

    Any reference counts, not only the call shape `name(`: a function
    pointer taken as `let f = name;` and called later bypasses the review
    just as a direct call does (#638). Text before the first function
    (globals) is scanned as "<top level>". The function's own definition is
    the one reference that is not a use."""
    starts = [(m.start(), m.group(1)) for m in FUNCTION.finditer(text)]
    spans = [(0, starts[0][0] if starts else len(text), "<top level>")]
    for index, (start, fn) in enumerate(starts):
        end = starts[index + 1][0] if index + 1 < len(starts) else len(text)
        spans.append((start, end, fn))
    found = []
    for start, end, fn in spans:
        body = "\n".join(line.split("//", 1)[0]
                         for line in text[start:end].splitlines())
        if fn == name:
            body = FUNCTION.sub("", body, count=1)
        if re.search(r"\b" + name + r"\b", body):
            found.append(fn)
    return found


def controls():
    """The check must see the shapes it exists to catch."""
    name = "cpu_here_for_boot_probe"
    cases = {
        "direct call": "fn f() { let c = cpu_here_for_boot_probe(0); }\n",
        "function pointer": "fn f() { let g = cpu_here_for_boot_probe; g(0); }\n",
        "global initializer": "let g = cpu_here_for_boot_probe;\nfn f() {}\n",
    }
    for label, text in cases.items():
        if not references(text, name):
            print(f"ERROR cpu-authority-mints: control '{label}' was not "
                  "detected")
            sys.exit(1)
    if references("fn f() { } // cpu_here_for_boot_probe\n", name):
        print("ERROR cpu-authority-mints: a comment was reported as a use")
        sys.exit(1)


def main():
    controls()
    problems = []
    scanned = 0
    for path in sorted(KERNEL.rglob("*.tkb")):
        if "build" in path.parts:
            continue
        scanned += 1
        relative = str(path.relative_to(ROOT))
        text = path.read_text()
        for name, allowed in ALLOWED.items():
            for fn in references(text, name):
                if ((relative, fn) not in allowed
                        and (relative, "*") not in allowed):
                    problems.append(f"{relative}: {fn} references {name}, a "
                                    "CPU-authority mint outside a preempt_off "
                                    "block; add it to ALLOWED only after "
                                    "review")
    if problems:
        for problem in problems:
            print(f"ERROR cpu-authority-mints: {problem}")
        sys.exit(1)
    report_pass("cpu-authority-mints",
                "the CPU-authority mints outside preempt_off blocks are "
                "referenced only by their reviewed callers (calls and function "
                "pointers; three controls)", files=scanned)


if __name__ == "__main__":
    main()
