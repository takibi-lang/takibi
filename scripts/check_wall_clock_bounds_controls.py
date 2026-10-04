#!/usr/bin/env python3
"""Controls for check_wall_clock_bounds.py: the tree passes, and an
undeclared bound, a stale row, a wrong count and an unknown class each fail.

Exit code only (0 = pass, 1 = fail).
"""

import contextlib
import io
import pathlib
import sys
import tempfile

import check_wall_clock_bounds as check
from pass_line import report_pass

SOURCE = """fn probe() {
    let window: i64 = read_cntfrq() * 2;
}
"""
ROW = "kernel/a.tkb\tprobe\t1\tpending\ttwo-core window\n"


def run(source: str, table: str) -> int:
    with tempfile.TemporaryDirectory() as tmp:
        root = pathlib.Path(tmp)
        (root / "kernel").mkdir()
        (root / "kernel" / "a.tkb").write_text(source)
        (root / "t.tsv").write_text(table)
        with contextlib.redirect_stdout(io.StringIO()), \
                contextlib.redirect_stderr(io.StringIO()):
            return check.main(root / "kernel", root / "t.tsv")


def main() -> int:
    failures = []
    with contextlib.redirect_stdout(io.StringIO()):
        tree = check.main()
    if tree != 0:
        failures.append("the tree itself fails")
    if run(SOURCE, ROW) != 0:
        failures.append("a declared bound is refused")
    cases = {
        "an undeclared bound": (SOURCE, "# empty\n"),
        "a stale row": ("fn probe() {}\n", ROW),
        "a wrong count": (SOURCE, ROW.replace("\t1\t", "\t2\t")),
        "an unknown class": (SOURCE, ROW.replace("pending", "later")),
    }
    for name, (source, table) in cases.items():
        if run(source, table) == 0:
            failures.append(f"{name} passes")
    if failures:
        for line in failures:
            print("FAIL wall-clock-bounds controls: " + line, file=sys.stderr)
        return 1
    report_pass("wall-clock-bounds controls",
                "the tree and a declared bound pass; an undeclared bound, a "
                "stale row, a wrong count and an unknown class are refused",
                cases=len(cases) + 2)
    return 0


if __name__ == "__main__":
    sys.exit(main())
