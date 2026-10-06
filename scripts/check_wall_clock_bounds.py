#!/usr/bin/env python3
"""Every host wall-clock bound in the kernel is declared, and the ones a
starved host can turn into a functional failure only go down (2026-10-04).

A QEMU lane's verdict is meant to be functional (ROADMAP, 2026-10-03), but a
wait bounded by `read_cntfrq() * N` decides by elapsed host time. Under load
that flipped verdicts: a 1 s virtio-blk completion bound timed out every
sector of an ext2 write, and two-core probes reported `incomplete` (#678,
#670). Removing those bounds is staged work, so this pins the inventory in
scripts/wall_clock_bounds.tsv: each site by file and enclosing function, with
a class. A new bound fails until it is declared with a reason; removing one
fails until its row goes too, so the count of `pending` rows is the number
left to remove.

Exit code only (0 = pass, 1 = fail).
"""

import collections
import pathlib
import re
import sys

from pass_line import report_pass

KERNEL = pathlib.Path("kernel")
TABLE = pathlib.Path("scripts/wall_clock_bounds.tsv")
CLASSES = {"pending", "protocol", "backstop"}
FN_RE = re.compile(r"^(?:private )?(?:inline |noinline )?fn (\w+)\(")
SITE_RE = re.compile(r"read_cntfrq\(\)\s*\*")


def main(kernel: pathlib.Path = KERNEL, table: pathlib.Path = TABLE) -> int:
    found = collections.Counter()
    for path in sorted(kernel.rglob("*.tkb")):
        if "build" in path.parts:
            continue
        enclosing = None
        for line in path.read_text().splitlines():
            match = FN_RE.match(line)
            if match:
                enclosing = match.group(1)
            sites = len(SITE_RE.findall(line.split("//", 1)[0]))
            if sites:
                found[(str(path.relative_to(kernel.parent)), enclosing)] += sites
    declared = {}
    failures = []
    for number, line in enumerate(table.read_text().splitlines(), 1):
        if not line.strip() or line.startswith("#"):
            continue
        cols = line.split("\t")
        if len(cols) != 5 or not cols[2].isdigit() or cols[3] not in CLASSES \
                or not cols[4].strip():
            failures.append(f"{table}:{number}: expected file, function, "
                            f"sites, one of {sorted(CLASSES)}, and a reason")
            continue
        declared[(cols[0], cols[1])] = (int(cols[2]), cols[3])
    for key, sites in sorted(found.items()):
        if key not in declared:
            failures.append(f"{key[0]}: {key[1]} bounds a wait by wall-clock "
                            f"time and has no row in {table}")
        elif declared[key][0] != sites:
            failures.append(f"{key[0]}: {key[1]} has {sites} site(s), "
                            f"declared {declared[key][0]}")
    for key in sorted(set(declared) - set(found)):
        failures.append(f"{table}: {key[0]} {key[1]} is declared but has no "
                        f"wall-clock bound any more; remove the row")
    if failures:
        for line in failures:
            print("FAIL wall-clock-bounds: " + line, file=sys.stderr)
        return 1
    pending = sum(s for s, cls in declared.values() if cls == "pending")
    report_pass("wall-clock-bounds",
                f"{sum(found.values())} wall-clock bound(s) declared, "
                f"{pending} still pending removal from functional verdicts",
                sites=sum(found.values()), pending=pending)
    return 0


if __name__ == "__main__":
    sys.exit(main())
