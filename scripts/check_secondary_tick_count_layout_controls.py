#!/usr/bin/env python3
"""Controls for the secondary_tick_count layout check, in both directions."""

import pathlib
import shutil
import subprocess
import sys
import tempfile

from pass_line import CaseCount, report_pass

REPO = pathlib.Path(__file__).resolve().parent.parent
CHECK = "check_secondary_tick_count_layout.py"
CASES = CaseCount()
SECONDARY = "kernel/arch/arm64/kernel/secondary.tkb"
ATOMIC = "kernel/lib/atomic_word.tkb"
READER = "scripts/gdb_tick_count.py"


def run(edit=None):
    """Copy the real three files, apply `edit` (path, old, new), run."""
    CASES.note()
    with tempfile.TemporaryDirectory() as raw:
        root = pathlib.Path(raw)
        for name in (SECONDARY, ATOMIC, READER, f"scripts/{CHECK}",
                     "scripts/pass_line.py", "scripts/source_scan.py"):
            (root / name).parent.mkdir(parents=True, exist_ok=True)
            shutil.copy(REPO / name, root / name)
        if edit:
            path, old, new = edit
            text = (root / path).read_text()
            if old not in text:
                raise SystemExit(f"control edit target missing in {path}: {old!r}")
            (root / path).write_text(text.replace(old, new, 1))
        done = subprocess.run(
            [sys.executable, f"scripts/{CHECK}"], cwd=root,
            capture_output=True, text=True,
            env={"PATH": "/usr/bin:/bin", "PYTHONPATH": str(root / "scripts")})
        return done.returncode


def main():
    failures = []
    if run() != 0:
        failures.append("the real tree was refused")
    if run((SECONDARY, "secondary_tick_count: [AtomicWord; KERNEL_MAX_CORES]",
            "secondary_tick_count: [AtomicWord; KERNEL_MAX_CORES * 2]")) == 0:
        failures.append("a resized array passed")
    if run((SECONDARY, "secondary_tick_count: [AtomicWord;",
            "secondary_tick_count: [u32Word;")) == 0:
        failures.append("a changed element type passed")
    if run((ATOMIC, "private value: usize;", "private value: usize; pad: usize;")) == 0:
        failures.append("a two-field AtomicWord passed")
    if run((READER, "{8 * core}", "{4 * core}")) == 0:
        failures.append("a 4-byte stride in the reader passed")
    if failures:
        for line in failures:
            print(f"FAIL secondary-tick-count-layout controls: {line}", file=sys.stderr)
        return 1
    report_pass("secondary-tick-count-layout controls",
                f"{CASES.ran} cases -- the real tree passes; a resized array, "
                "another element type, a wider AtomicWord and a 4-byte stride "
                "are refused", cases=CASES.ran)
    return 0


if __name__ == "__main__":
    sys.exit(main())
