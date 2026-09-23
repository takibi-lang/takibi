#!/usr/bin/env python3
"""Controls for the gdb guest-memory-read check, in both directions."""

import pathlib
import shutil
import subprocess
import sys
import tempfile

from pass_line import CaseCount, report_pass

REPO = pathlib.Path(__file__).resolve().parent.parent
CHECK = "check_gdb_no_guest_memory_read.py"
CASES = CaseCount()

GDB = "import gdb\n"
CLEAN = GDB + "x = int(gdb.parse_and_eval('$x1'))\n"
READS = GDB + "d = gdb.selected_inferior().read_memory(a, 8)\n"
DECLARED = GDB + ("d = gdb.selected_inferior().read_memory(a, 8)  "
                  "# gdb-memory-read: every CPU stopped in root 0\n")
NOT_GDB = "d = obj.read_memory(a, 8)\n"


def run(body):
    CASES.note()
    with tempfile.TemporaryDirectory() as raw:
        root = pathlib.Path(raw)
        (root / "scripts").mkdir()
        for name in (CHECK, "pass_line.py"):
            shutil.copy(REPO / "scripts" / name, root / "scripts" / name)
        (root / "scripts" / "probe.py").write_text(body)
        # One register-only gdb script always present, so a case whose probe
        # is not a gdb script still gives the check something to examine
        # rather than tripping report_pass's refusal of an empty scan.
        (root / "scripts" / "anchor.py").write_text(CLEAN)
        done = subprocess.run(
            [sys.executable, f"scripts/{CHECK}"], cwd=root,
            capture_output=True, text=True,
            env={"PATH": "/usr/bin:/bin",
                 "PYTHONPATH": str(root / "scripts")})
        return done.returncode


def main():
    failures = []
    if run(CLEAN) != 0:
        failures.append("a register-only gdb script was refused")
    if run(READS) == 0:
        failures.append("an undeclared guest-memory read passed")
    if run(DECLARED) != 0:
        failures.append("a declared read was refused")
    if run(NOT_GDB) != 0:
        failures.append("a non-gdb script was held to the gdb rule")
    if failures:
        for line in failures:
            print(f"FAIL gdb-no-guest-memory-read controls: {line}",
                  file=sys.stderr)
        return 1
    report_pass("gdb-no-guest-memory-read controls",
                f"{CASES.ran} cases -- register-only and declared reads pass, "
                "an undeclared read is refused, non-gdb scripts are ignored",
                cases=CASES.ran)
    return 0


if __name__ == "__main__":
    sys.exit(main())
