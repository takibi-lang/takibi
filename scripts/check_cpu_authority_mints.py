#!/usr/bin/env python3
"""Hold the CPU authority's mints to the preempt_off block (#704, #1080).

kernel/kernel/cpu_authority.tkb mints CpuHere, the only index a per-CPU
store accepts. A preempt_off block mints it through the private
preempt_off_enter(), which the compiler checks (#638). A public function of
that file returning CpuHere would bypass the block, and the compiler cannot
tell it from the block's mint at a call, so this check refuses one unless
ALLOWED names it with its reviewed callers. The last one,
cpu_here_for_boot_probe(), named any CPU for a boot probe of execve's
per-CPU argv slot and left with that slot (#1080). (ext2's scratch, held
across block I/O, left per-CPU storage for a slot pool in #638 slice 2,
which retired its mint, cpu_here_across_blocking.)
"""

import re
import sys
from pathlib import Path

from pass_line import report_pass
from source_scan import code_only

ROOT = Path(__file__).resolve().parent.parent
KERNEL = ROOT / "kernel"

# function -> {(file, enclosing function)} allowed to call it.
ALLOWED = {}
MINT_FILE = KERNEL / "kernel" / "cpu_authority.tkb"
PUBLIC_MINT = re.compile(
    r"^\s*(?:noinline\s+|inline\s+)*fn\s+(\w+)\s*\([^)]*\)\s*->\s*CpuHere\b",
    re.M)


def public_mints(text):
    """Names of the non-private functions in `text` that return CpuHere."""
    return PUBLIC_MINT.findall(code_only(text))
FUNCTION = re.compile(r"^\s*(?:private\s+)?(?:noinline\s+)?fn\s+(\w+)", re.M)


def references(text, name):
    """(enclosing function) for every reference to `name` outside comments.

    Any reference counts, not only the call shape `name(`: a function
    pointer taken as `let f = name;` and called later bypasses the review
    just as a direct call does (#638). Text before the first function
    (globals) is scanned as "<top level>". The function's own definition is
    the one reference that is not a use."""
    code = code_only(text)  # GitHub issue #818: block comments too
    starts = [(m.start(), m.group(1)) for m in FUNCTION.finditer(code)]
    spans = [(0, starts[0][0] if starts else len(text), "<top level>")]
    for index, (start, fn) in enumerate(starts):
        end = starts[index + 1][0] if index + 1 < len(starts) else len(text)
        spans.append((start, end, fn))
    found = []
    for start, end, fn in spans:
        body = code[start:end]
        if fn == name:
            body = FUNCTION.sub("", body, count=1)
        if re.search(r"\b" + name + r"\b", body):
            found.append(fn)
    return found


def controls():
    """The check must see the shapes it exists to catch."""
    if public_mints("fn any_cpu(core: usize) -> CpuHere {\n") != ["any_cpu"]:
        print("ERROR cpu-authority-mints: control 'public mint' was not "
              "detected")
        sys.exit(1)
    if public_mints("private fn preempt_slot() -> CpuHere {\n"):
        print("ERROR cpu-authority-mints: a private mint was reported")
        sys.exit(1)
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
    for name in public_mints(MINT_FILE.read_text()):
        if name not in ALLOWED:
            problems.append(f"{MINT_FILE.relative_to(ROOT)}: {name} is a "
                            "public CPU-authority mint outside a preempt_off "
                            "block; add it to ALLOWED with its callers only "
                            "after review")
    for path in sorted(KERNEL.rglob("*.tkb")):
        if "build" in path.parts:
            continue
        scanned += 1
        relative = str(path.relative_to(ROOT))
        text = path.read_text()
        for name, allowed in ALLOWED.items():
            for fn in references(text, name):
                if (relative, fn) not in allowed:
                    problems.append(f"{relative}: {fn} references {name}, a "
                                    "CPU-authority mint outside a preempt_off "
                                    "block; add it to ALLOWED only after "
                                    "review")
    if problems:
        for problem in problems:
            print(f"ERROR cpu-authority-mints: {problem}")
        sys.exit(1)
    report_pass("cpu-authority-mints",
                f"{len(ALLOWED)} public CPU-authority mint(s) outside "
                "preempt_off blocks, each referenced only by its reviewed "
                "callers (calls and function pointers; five controls)",
                files=scanned)


if __name__ == "__main__":
    main()
