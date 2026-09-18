#!/usr/bin/env python3
"""Controls for the known-intermittent table's rules.

The repository passes today, so a control that only ran the check would prove
nothing. Each rule is exercised against a synthetic tree, built here rather
than copied: what is under test is the rules, and a minimal tree makes each
planted defect the only difference between a pass and a fail.

The case that matters is the second: a row whose symptom string no longer
appears anywhere in the product. That is how a table like this rots -- the
defect is fixed, the row stays, and the next triager reads a claim about
nothing and stops looking.
"""

import pathlib
import shutil
import subprocess
import sys
import tempfile

from pass_line import CaseCount, report_pass

REPO = pathlib.Path(__file__).resolve().parent.parent
CHECK = "scripts/check_known_intermittents.py"

HEADER = ("| Symptom | Rate | Issue | Last seen |\n"
          "| --- | --- | --- | --- |\n")
GOOD_ROW = ("| `process table: records MISSING uses=` | 0 in 16 main-lane "
            "runs | #514 | 2026-09-17 |\n")
SECOND_ROW = ("| `target root FELL BACK TO 0 uses=` | one CI fail-stop, "
              "unmeasured | #516 | 2026-09-17 |\n")

KERNEL_SOURCE = (
    'kernel_boot_log("process table: records MISSING uses=");\n'
    'kernel_boot_log("process image: target root FELL BACK TO 0 uses=");\n')

ROADMAP = ("# Takibi roadmap\n\nThe live intermittents are listed in "
           "`docs/KNOWN_INTERMITTENTS.md`.\n")


def build(root, table=None, kernel=None, roadmap=None):
    """A minimal tree shaped like the one the check reads."""
    (root / "scripts").mkdir(parents=True)
    for script in ("check_known_intermittents.py", "pass_line.py"):
        shutil.copy(REPO / "scripts" / script, root / "scripts" / script)
    (root / "kernel" / "init").mkdir(parents=True)
    (root / "kernel" / "init" / "test_driver.tkb").write_text(
        KERNEL_SOURCE if kernel is None else kernel, encoding="ascii")
    (root / "docs").mkdir(parents=True)
    (root / "docs" / "KNOWN_INTERMITTENTS.md").write_text(
        HEADER + GOOD_ROW + SECOND_ROW if table is None else table,
        encoding="ascii")
    (root / "ROADMAP.md").write_text(
        ROADMAP if roadmap is None else roadmap, encoding="ascii")


def run(root):
    finished = subprocess.run(
        [sys.executable, str(root / CHECK)], cwd=root,
        capture_output=True, text=True,
        env={"PATH": "/usr/bin:/bin", "PYTHONPATH": str(root / "scripts")})
    return finished.returncode, finished.stdout + finished.stderr


# GitHub issue #526: a control asserts the number of scenarios it ran.
CASES = CaseCount()


def case(name, want, should_fail=True, **parts):
    CASES.note()
    failures = []
    with tempfile.TemporaryDirectory() as raw:
        root = pathlib.Path(raw) / "tree"
        build(root, **parts)
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


def main() -> int:
    failures = []

    status, report = run(REPO)
    if status != 0:
        failures.append(f"the repository itself does not pass: {report.strip()!r}")
    elif "known intermittent(s)" not in report:
        failures.append(f"the repository passed about something else: "
                        f"{report.strip()!r}")

    CASES.note()
    with tempfile.TemporaryDirectory() as raw:
        root = pathlib.Path(raw) / "tree"
        build(root)
        status, report = run(root)
        if status != 0:
            failures.append(f"a well-formed table was refused: "
                            f"{report.strip()!r}")
        elif "2 known intermittent(s)" not in report:
            failures.append(f"a two-row table was not counted as two: "
                            f"{report.strip()!r}")

    # The rot this table is most likely to suffer: the defect is fixed, the
    # row stays, and the next triager reads a claim about nothing.
    failures += case(
        "a symptom the tree no longer produces",
        "appears in no kernel source line",
        kernel='kernel_boot_log("process image: target root FELL BACK TO 0 uses=");\n')

    # An empty table is the goal state, not a failure.
    failures += case(
        "an empty table",
        "0 known intermittent(s)", should_fail=False, table=HEADER)

    # One issue, one row: two rows for one issue is a pile, not a map.
    failures += case(
        "two rows owned by one issue",
        "owns two rows",
        table=HEADER + GOOD_ROW + GOOD_ROW.replace(
            "process table: records MISSING uses=",
            "process image: target root FELL BACK TO 0 uses="))

    # A row in a shape nothing reads would be held to nothing, which is worse
    # than a row that is wrong: it looks checked.
    failures += case(
        "a row in an unreadable shape",
        "not in the checked shape",
        table=HEADER + GOOD_ROW + "| no backticks | some rate | 516 | today |\n")

    failures += case(
        "a last-seen date in the future",
        "is in the future",
        table=HEADER + GOOD_ROW.replace("2026-09-17", "2099-01-01"))

    failures += case(
        "a last-seen date that is not a date",
        "is not a real date",
        table=HEADER + GOOD_ROW.replace("2026-09-17", "2026-13-45"))

    failures += case(
        "a row with no rate",
        "has no rate",
        table=HEADER + "| `process table: records MISSING uses=` |  | #514 "
                       "| 2026-09-17 |\n")

    # #565's last acceptance condition: the roadmap points at the table
    # instead of carrying the list, because it is rewritten wholesale.
    failures += case(
        "a roadmap that still carries the list itself",
        "does not point at docs/KNOWN_INTERMITTENTS.md",
        roadmap="# Takibi roadmap\n\nThe intermittent set is #514, #516, "
                "#563.\n")

    failures += case(
        "a table whose columns moved",
        "the table header is not",
        table="| Thing | Issue |\n| --- | --- |\n")

    for failure in failures:
        print(f"ERROR\tknown-intermittents-controls: {failure}")
    if failures:
        print("FAIL known-intermittents controls: a row can still outlive "
              "what it describes")
        return 1
    report_pass(
        "known-intermittents controls",
        "the repository passes, a well-formed table and an empty one are "
        "accepted, and a symptom the tree no longer produces, two rows for "
        "one issue, an unreadable row, a future date, a non-date, a missing "
        "rate, a roadmap still carrying the list, and moved columns are each "
        "refused",
        cases=CASES.ran)
    return 0


if __name__ == "__main__":
    sys.exit(main())
