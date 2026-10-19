#!/usr/bin/env python3
"""Controls for the scheduler-locking park check, in both directions."""

import pathlib
import shutil
import subprocess
import sys
import tempfile

from pass_line import CaseCount, report_pass

REPO = pathlib.Path(__file__).resolve().parent.parent
CHECK = "check_gdb_scheduler_locking.py"
CASES = CaseCount()

LOCK = "scheduler-locking"
PARKED = (f'    -ex "set {LOCK} on"\n'
          '    -ex "takibi-park-threads kernel_idle_loop 2 3 4"\n')
WAIVED = ("# scheduler-locking-waiver: cores 2 and 3 are not online yet\n"
          f'    -ex "set {LOCK} on"\n')
EMPTY_WAIVER = ("# scheduler-locking-waiver:\n"
                f'    -ex "set {LOCK} on"\n')
BARE = f'    -ex "set {LOCK} on"\n    -ex "continue"\n'
PYTHON_BARE = f'gdb.execute("set {LOCK} " + ("on" if locked else "off"))\n'
OFF_ONLY = f'    -ex "set {LOCK} off"\n'
COMMENT_ONLY = f"# set {LOCK} on was how this used to run\n"
LATE_PARK = BARE + "\n" * 6 + "    -ex \"takibi-park-threads kernel_idle_loop 2\"\n"


def run(name, body):
    CASES.note()
    with tempfile.TemporaryDirectory() as raw:
        root = pathlib.Path(raw)
        (root / "scripts").mkdir()
        for copied in (CHECK, "pass_line.py"):
            shutil.copy(REPO / "scripts" / copied, root / "scripts" / copied)
        (root / "scripts" / name).write_text(body)
        done = subprocess.run(
            [sys.executable, f"scripts/{CHECK}"], cwd=root,
            capture_output=True, text=True,
            env={"PATH": "/usr/bin:/bin",
                 "PYTHONPATH": str(root / "scripts")})
        return done.returncode


def main():
    failures = []
    if run("run_kernel_probe.sh", PARKED) != 0:
        failures.append("a stage followed by a park was refused")
    if run("run_kernel_probe.sh", WAIVED) != 0:
        failures.append("a stage with a reasoned waiver was refused")
    if run("run_kernel_probe.sh", OFF_ONLY) != 0:
        failures.append("turning scheduler-locking off was held to the rule")
    if run("run_kernel_probe.sh", COMMENT_ONLY) != 0:
        failures.append("a comment naming scheduler-locking was held to the rule")
    if run("run_kernel_probe.sh", BARE) == 0:
        failures.append("a stage with no park and no waiver passed")
    if run("run_kernel_probe.sh", EMPTY_WAIVER) == 0:
        failures.append("a waiver with no reason passed")
    if run("run_kernel_probe.sh", LATE_PARK) == 0:
        failures.append("a park far after the stage passed")
    if run("kernel_probe_check.py", PYTHON_BARE) == 0:
        failures.append("a Python gdb check with a computed lock state passed")
    if failures:
        for line in failures:
            print(f"FAIL gdb-scheduler-locking controls: {line}", file=sys.stderr)
        return 1
    report_pass("gdb-scheduler-locking controls",
                f"{CASES.ran} cases -- a parked or reasoned stage passes; off "
                "and comments are ignored; a bare stage, an empty waiver, a "
                "distant park and a computed Python lock state are refused",
                cases=CASES.ran)
    return 0


if __name__ == "__main__":
    sys.exit(main())
