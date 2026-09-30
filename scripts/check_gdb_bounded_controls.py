#!/usr/bin/env python3
"""Controls for the bounded-gdb check, in both directions."""

import pathlib
import shutil
import subprocess
import sys
import tempfile

from pass_line import CaseCount, report_pass

REPO = pathlib.Path(__file__).resolve().parent.parent
CHECK = "check_gdb_bounded.py"
CASES = CaseCount()

GDB = "gdb-multiarch -q -" + "batch"
SAME_LINE = f'timeout 600 {GDB} "$ELF" -x check.py\n'
CONTINUED = f'timeout 600 \\\n    {GDB} "$ELF" -x check.py\n'
BARE = f'{GDB} "$ELF" -x check.py\n'
COMMENTED = f'# {GDB} is how this used to run\ntimeout 60 {GDB} "$ELF"\n'


def run(body):
    CASES.note()
    with tempfile.TemporaryDirectory() as raw:
        root = pathlib.Path(raw)
        (root / "scripts").mkdir()
        for name in (CHECK, "pass_line.py"):
            shutil.copy(REPO / "scripts" / name, root / "scripts" / name)
        (root / "scripts" / "run_kernel_probe.sh").write_text(body)
        done = subprocess.run(
            [sys.executable, f"scripts/{CHECK}"], cwd=root,
            capture_output=True, text=True,
            env={"PATH": "/usr/bin:/bin",
                 "PYTHONPATH": str(root / "scripts")})
        return done.returncode


def main():
    failures = []
    if run(SAME_LINE) != 0:
        failures.append("gdb under timeout on its own line was refused")
    if run(CONTINUED) != 0:
        failures.append("gdb under a continued timeout was refused")
    if run(COMMENTED) != 0:
        failures.append("a comment naming gdb was held to the rule")
    if run(BARE) == 0:
        failures.append("an unbounded gdb passed")
    if failures:
        for line in failures:
            print(f"FAIL gdb-bounded controls: {line}", file=sys.stderr)
        return 1
    report_pass("gdb-bounded controls",
                f"{CASES.ran} cases -- gdb under timeout, on its line or a "
                "continued one, passes; comments are ignored; an unbounded "
                "gdb is refused", cases=CASES.ran)
    return 0


if __name__ == "__main__":
    sys.exit(main())
