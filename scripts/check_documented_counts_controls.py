#!/usr/bin/env python3
"""Controls for the documented-count check.

The repository passes today, so a control that only ran the check would prove
nothing. Each rule is exercised against a planted copy of the tree.

Two of the cases matter more than the others. One plants a stale number, which
is the defect four commits in this repository existed to repair. The other
rewords the sentence carrying the number, which is how a check of this shape
stops examining without ever failing -- the number would keep being copied by
hand and nothing would compare it again.
"""

import pathlib
import re
import shutil
import subprocess
import sys
import tempfile

from pass_line import CaseCount, report_pass

REPO = pathlib.Path(__file__).resolve().parent.parent
CHECK = "scripts/check_documented_counts.py"
README = "kernel/README.md"
COUNTED_PATTERN = r"^PASS kernel/rpi5 \((\d+) views, one boot\)$"


def counted():
    """Read the anchor out of the README rather than transcribing it here.

    This file used to carry the number itself, and went stale the first time
    a view moved between directories -- which is the exact failure the check
    it controls exists to prevent, committed by its own control. The number
    still comes from the README and not from the tree: what the check
    compares is those two, so a control that computed it the way the check
    does could agree with a broken check.
    """
    text = (REPO / README).read_text(encoding="ascii")
    match = re.search(COUNTED_PATTERN, text, re.M)
    if match is None:
        raise SystemExit(
            f"{README} no longer carries a `PASS kernel/rpi5 (N views, one "
            f"boot)` line for this control to plant defects in")
    return match.group(0), int(match.group(1))


COUNTED, COUNT = counted()


def run(root):
    finished = subprocess.run(
        [sys.executable, str(root / CHECK)], cwd=root,
        capture_output=True, text=True,
        env={"PATH": "/usr/bin:/bin", "PYTHONPATH": str(root / "scripts")})
    return finished.returncode, finished.stdout + finished.stderr


# GitHub issue #526: a control asserts the number of scenarios it ran.
CASES = CaseCount()


def case(name, plant, want, should_fail=True):
    """Copy what the check reads, plant one defect, require the verdict."""
    CASES.note()
    failures = []
    with tempfile.TemporaryDirectory() as raw:
        root = pathlib.Path(raw) / "tree"
        (root / "scripts").mkdir(parents=True)
        for script in ("check_documented_counts.py", "pass_line.py"):
            shutil.copy(REPO / "scripts" / script, root / "scripts" / script)
        (root / "kernel").mkdir(parents=True, exist_ok=True)
        shutil.copy(REPO / README, root / README)
        shutil.copytree(REPO / "kernel" / "tests", root / "kernel" / "tests")
        plant(root)
        status, report = run(root)
        if should_fail and status == 0:
            failures.append(f"{name}: the planted defect passed")
        elif not should_fail and status != 0:
            failures.append(f"{name}: a legitimate tree was refused: "
                            f"{report.strip()!r}")
        elif want and want not in report:
            failures.append(f"{name}: reported {report.strip()!r}, which does "
                            f"not name {want!r}")
    return failures


def edit_readme(old, new):
    def plant(root):
        target = root / README
        text = target.read_text(encoding="ascii")
        assert text.count(old) == 1, f"{old!r} is not a unique anchor"
        target.write_text(text.replace(old, new, 1), encoding="ascii")
    return plant


def add_a_view(root):
    """A new view changes what the runner counts, so the number must move."""
    views = root / "kernel" / "tests" / "common" / "views"
    (views / "planted_documented_count.filter").write_text(
        "^planted: nothing\n", encoding="ascii")
    (views / "planted_documented_count.expected").write_text("", encoding="ascii")


def main() -> int:
    failures = []

    status, report = run(REPO)
    if status != 0:
        failures.append(f"the repository itself does not pass: {report.strip()!r}")
    elif "1 number(s) transcribed" not in report:
        failures.append(f"the repository passed about an unexpected number of "
                        f"claims: {report.strip()!r}")

    failures += case(
        "stale number",
        edit_readme(COUNTED, f"PASS kernel/rpi5 ({COUNT - 1} views, one boot)"),
        f"says {COUNT - 1} views the RPi5 lane compares; the tree has {COUNT}")

    # The failure this check exists to prevent, applied to the check itself.
    failures += case(
        "the sentence reworded out from under it",
        edit_readme(COUNTED,
                    f"PASS kernel/rpi5 -- {COUNT} views from one boot"),
        "the line was reworded or moved")

    # A count derived from a stale snapshot rather than from the tree would
    # pass this: the number in the file is untouched and the tree is not.
    failures += case("a view added and the number not", add_a_view,
                     f"says {COUNT} views the RPi5 lane compares; the tree "
                     f"has {COUNT + 1}")

    # Numbers this file does not declare are records of what was true at the
    # time, and must stay out of reach. kernel/RESOURCE_LIMITS.md carries four
    # of them; HISTORY.md is full of them.
    def plant_undeclared_number(root):
        (root / "kernel" / "RESOURCE_LIMITS.md").write_text(
            "step (37 views, up from 31 at the start), including two clean "
            "rebuilds.\n", encoding="ascii")

    failures += case("an undeclared number is not touched",
                     plant_undeclared_number, "", should_fail=False)

    for failure in failures:
        print(f"ERROR\tdocumented-counts-controls: {failure}")
    if failures:
        print("FAIL documented-counts controls: a transcribed number is not "
              "held to the tree it counts")
        return 1
    report_pass(
        "documented-counts controls",
        "the repository passes, a stale number and a tree that moved "
        "without it are each refused, a reworded sentence is refused "
        "rather than silently retiring the claim, and a number nothing "
        "declares is left alone",
        cases=CASES.ran)
    return 0


if __name__ == "__main__":
    sys.exit(main())
