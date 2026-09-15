#!/usr/bin/env python3
"""Every kernel file a target compiles is checked for unused functions, or named as exempt.

GitHub issue #540. `--reject-unused-functions` reports a function nothing
reads, but only in the files the Makefile passes to `--check-unused-file`.
A hand-written list silently leaves a new file out, and a file left out is
exactly where an accessor nobody calls goes unnoticed, which is what #540 was
filed about.

This reads the depfile the build just wrote for one target's kernel object.
Every `.tkb` in it must appear in KERNEL_UNUSED_CHECKED, in that target's own
list, in the other target's list (a file QEMU links only so the program
resolves is checked on RPi5, where it is used, and the reverse), in
KERNEL_UNUSED_EXEMPT (whose reasons the Makefile states), or in
KERNEL_UNUSED_NO_FUNCTIONS; `_extern.tkb` files are skipped by name. A listed
file the target no longer compiles is also refused, so the lists cannot keep
names that stopped meaning anything.

Usage: buildcheck_kernel_unused_coverage.py qemu|rpi5 DEPFILE
"""

import re
import sys
from pathlib import Path

from pass_line import report_pass

ROOT = Path(__file__).resolve().parent.parent


def makefile_list(makefile: str, name: str) -> set[str]:
    match = re.search(rf"^{name} :=((?:.*\\\n)*.*)$", makefile, re.M)
    if match is None:
        raise SystemExit(f"FAIL kernel-unused-coverage: Makefile has no {name}")
    return set(match.group(1).replace("\\\n", " ").split())


def compiled(depfile: Path) -> set[str]:
    first = depfile.read_text().replace("\\\n", " ").split("\n", 1)[0]
    _, _, prerequisites = first.partition(":")
    result = set()
    for word in prerequisites.split():
        path = Path(word)
        if path.is_absolute():
            try:
                path = path.relative_to(ROOT)
            except ValueError:
                continue
        text = path.as_posix()
        if text.startswith("kernel/") and text.endswith(".tkb"):
            result.add(text)
    return result


def main() -> int:
    if len(sys.argv) != 3 or sys.argv[1] not in ("qemu", "rpi5"):
        print(__doc__.strip().splitlines()[-1], file=sys.stderr)
        return 2
    target = sys.argv[1]
    makefile = (ROOT / "Makefile").read_text(encoding="utf-8")
    other = "rpi5" if target == "qemu" else "qemu"
    checked = (makefile_list(makefile, "KERNEL_UNUSED_CHECKED") |
               makefile_list(makefile, f"KERNEL_UNUSED_CHECKED_{target.upper()}"))
    elsewhere = makefile_list(makefile, f"KERNEL_UNUSED_CHECKED_{other.upper()}")
    exempt = makefile_list(makefile, "KERNEL_UNUSED_EXEMPT")
    no_functions = makefile_list(makefile, "KERNEL_UNUSED_NO_FUNCTIONS")
    units = {path for path in compiled(Path(sys.argv[2]))
             if not path.endswith("_extern.tkb")}

    problems = []
    for path in sorted(units - checked - elsewhere - exempt - no_functions):
        problems.append(f"{path} is compiled into the {target} kernel and is in "
                        "no list: check it, or say in the Makefile why not")
    for path in sorted(checked - units):
        problems.append(f"{path} is listed as checked for {target} but that "
                        "kernel does not compile it")
    for path in sorted(checked & (exempt | no_functions)):
        problems.append(f"{path} is both checked and exempt")
    if problems:
        for problem in problems:
            print(f"ERROR kernel-unused-coverage: {problem}")
        print(f"FAIL kernel-unused-coverage: {target}")
        return 1
    report_pass("kernel-unused-coverage",
                f"{target}: all {len(units)} compiled kernel files are checked "
                f"for unused functions here ({len(units & checked)}), on the "
                f"other target ({len(units & elsewhere)}), or exempt for a "
                "stated reason",
                files=len(units), checked=len(units & checked))
    return 0


if __name__ == "__main__":
    sys.exit(main())
