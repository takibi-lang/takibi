#!/usr/bin/env python3
"""Controls for the race-window overlay check, in both directions."""

import pathlib
import shutil
import subprocess
import sys
import tempfile

from pass_line import CaseCount, report_pass

REPO = pathlib.Path(__file__).resolve().parent.parent
CHECK = "check_race_window_overlay_only.py"
CASES = CaseCount()

CLEAN = "fn kernel_process_stack_idle_blocked() {\n    let core: usize = 0;\n}\n"
# Assembled, so this file does not carry the marker it plants.
MARKER = "race_window" + "_start"
SPUN = ("fn f() {\n    let " + MARKER + ": i64 = read_cntpct();\n}\n")
BUILT = SPUN


def run(body, relative="kernel/kernel/probe.tkb"):
    CASES.note()
    with tempfile.TemporaryDirectory() as raw:
        root = pathlib.Path(raw)
        (root / "scripts").mkdir()
        for name in (CHECK, "pass_line.py"):
            shutil.copy(REPO / "scripts" / name, root / "scripts" / name)
        (root / "kernel" / "kernel").mkdir(parents=True)
        (root / "kernel" / "kernel" / "anchor.tkb").write_text(CLEAN)
        target = root / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(body)
        done = subprocess.run(
            [sys.executable, f"scripts/{CHECK}"], cwd=root,
            capture_output=True, text=True,
            env={"PATH": "/usr/bin:/bin",
                 "PYTHONPATH": str(root / "scripts")})
        return done.returncode


def main():
    failures = []
    if run(CLEAN) != 0:
        failures.append("a kernel source with no spin was refused")
    if run(SPUN) == 0:
        failures.append("a spin in kernel/ passed")
    if run(BUILT, "kernel/build/overlay/process.tkb") != 0:
        failures.append("a spin under a build output directory was refused")
    if failures:
        for line in failures:
            print(f"FAIL race-window-overlay-only controls: {line}",
                  file=sys.stderr)
        return 1
    report_pass("race-window-overlay-only controls",
                f"{CASES.ran} cases -- a clean tree passes, a spin in kernel/ "
                "is refused, and build output is ignored",
                cases=CASES.ran)
    return 0


if __name__ == "__main__":
    sys.exit(main())
