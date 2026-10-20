#!/usr/bin/env python3
"""Controls for the gdb wall-clock continue check, in both directions."""

import pathlib
import shutil
import subprocess
import sys
import tempfile

from pass_line import CaseCount, report_pass

REPO = pathlib.Path(__file__).resolve().parent.parent
CHECK = "check_gdb_wallclock_continue.py"
CASES = CaseCount()

HEAD = "import gdb\nfrom gdb_interrupt import interrupt_after\n\n"
TIMER = HEAD + ("def step():\n"
                "    timer = interrupt_after(10.0)\n"
                "    gdb.execute('info threads')\n"
                "    timer.cancel()\n")
BARE_CONTINUE = "import gdb\n\ngdb.execute(\"continue\")\n"
FSTRING_FINISH = "import gdb\n\ndef back(n):\n    gdb.execute(f\"finish {n}\")\n"
WAIVED = HEAD + ("def step():\n"
                 "    # gdb-wallclock-waiver: positive-only, see #867\n"
                 "    timer = interrupt_after(10.0)\n")
EMPTY_WAIVER = HEAD + ("def step():\n"
                       "    # gdb-wallclock-waiver:\n"
                       "    timer = interrupt_after(10.0)\n")
FAR_WAIVER = HEAD + ("# gdb-wallclock-waiver: too far away\n" + "\n" * 6 +
                     "def step():\n    timer = interrupt_after(10.0)\n")
PRIMITIVE = HEAD + ("def resume_slice(seconds):\n"
                    "    timer = interrupt_after(seconds)\n"
                    "    gdb.execute('continue')\n")
NOT_RESUME = "import gdb\n\ngdb.execute('info threads')\ngdb.execute('set confirm off')\n"
NO_GDB = "def step():\n    interrupt_after(1)\n"
COMMENT_ONLY = "import gdb\n\n# gdb.execute(\"continue\") was how this ran\n"


def run(name, body):
    CASES.note()
    with tempfile.TemporaryDirectory() as raw:
        root = pathlib.Path(raw)
        (root / "scripts").mkdir()
        for copied in (CHECK, "pass_line.py"):
            shutil.copy(REPO / "scripts" / copied, root / "scripts" / copied)
        # A clean gdb check beside the case, so the scan is never empty.
        (root / "scripts" / "kernel_clean_check.py").write_text(NOT_RESUME)
        (root / "scripts" / name).write_text(body)
        done = subprocess.run(
            [sys.executable, f"scripts/{CHECK}"], cwd=root,
            capture_output=True, text=True,
            env={"PATH": "/usr/bin:/bin",
                 "PYTHONPATH": str(root / "scripts")})
        return done.returncode


def main():
    failures = []
    if run("kernel_probe_check.py", TIMER) == 0:
        failures.append("an interrupt_after() outside a slice primitive passed")
    if run("kernel_probe_check.py", BARE_CONTINUE) == 0:
        failures.append("a bare gdb.execute(\"continue\") passed")
    if run("kernel_probe_check.py", FSTRING_FINISH) == 0:
        failures.append("an f-string finish passed")
    if run("kernel_probe_check.py", EMPTY_WAIVER) == 0:
        failures.append("a waiver with no reason passed")
    if run("kernel_probe_check.py", FAR_WAIVER) == 0:
        failures.append("a distant waiver passed")
    if run("kernel_probe_check.py", PRIMITIVE) == 0:
        failures.append("a slice primitive's name in another file passed")
    if run("gdb_progress.py", PRIMITIVE) != 0:
        failures.append("the slice primitive itself was refused")
    if run("kernel_probe_check.py", WAIVED) != 0:
        failures.append("a reasoned waiver was refused")
    if run("kernel_probe_check.py", NOT_RESUME) != 0:
        failures.append("a gdb command that does not resume was refused")
    if run("kernel_probe_check.py", NO_GDB) != 0:
        failures.append("a script that does not import gdb was held to the rule")
    if run("kernel_probe_check.py", COMMENT_ONLY) != 0:
        failures.append("a comment naming continue was held to the rule")
    if failures:
        for line in failures:
            print(f"FAIL gdb-wallclock-continue controls: {line}", file=sys.stderr)
        return 1
    report_pass("gdb-wallclock-continue controls",
                f"{CASES.ran} cases -- interrupt_after, a bare continue, an "
                "f-string finish, empty and distant waivers and a borrowed "
                "primitive name are refused; the primitive, a reasoned waiver, "
                "non-resuming commands, non-gdb scripts and comments pass",
                cases=CASES.ran)
    return 0


if __name__ == "__main__":
    sys.exit(main())
