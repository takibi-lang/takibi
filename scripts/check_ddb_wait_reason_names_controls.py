#!/usr/bin/env python3
"""Controls for the DDB wait-vocabulary check.

The repository passes today, so a control that only ran the check would prove
nothing. Each rule is exercised against a planted copy of the two files it
reads.

The case that matters is the first: an enum case added and not named. That is
the drift the check exists for, and it is silent in the running kernel -- the
view prints `unknown` and nothing else notices.
"""

import pathlib
import shutil
import subprocess
import sys
import tempfile

from pass_line import CaseCount, report_pass

REPO = pathlib.Path(__file__).resolve().parent.parent
CHECK = "scripts/check_ddb_wait_reason_names.py"
PROCESS = "kernel/kernel/process.tkb"
DEBUGGER = "kernel/arch/arm64/kernel/exception_evidence.tkb"


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
        for script in ("check_ddb_wait_reason_names.py", "pass_line.py"):
            shutil.copy(REPO / "scripts" / script, root / "scripts" / script)
        for relative in (PROCESS, DEBUGGER):
            target = root / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy(REPO / relative, target)
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


def rename_everywhere(relative, old, new):
    """Move a whole encoding, the way a refactor in the other file would."""
    def plant(root):
        target = root / relative
        text = target.read_text(encoding="ascii")
        assert old in text, f"{old!r} matches nothing"
        target.write_text(text.replace(old, new), encoding="ascii")
    return plant


def edit(relative, old, new):
    def plant(root):
        target = root / relative
        text = target.read_text(encoding="ascii")
        assert text.count(old) == 1, f"{old!r} is not a unique anchor"
        target.write_text(text.replace(old, new, 1), encoding="ascii")
    return plant


def main() -> int:
    failures = []

    status, report = run(REPO)
    if status != 0:
        failures.append(f"the repository itself does not pass: {report.strip()!r}")
    elif "12 process state and wait reason(s)" not in report:
        failures.append(f"the repository passed about an unexpected "
                        f"vocabulary size: {report.strip()!r}")

    # A sixth wait reason, encoded and never named. The kernel keeps working
    # and the view prints a word for every reason but this one.
    failures += case(
        "a reason encoded and not named",
        edit(PROCESS,
             "        ProcessWaitReason::Signal => { output[index].wait_reason = 5; }",
             "        ProcessWaitReason::Signal => { output[index].wait_reason = 5; }\n"
             "        ProcessWaitReason::DiskIo => { output[index].wait_reason = 6; }"),
        "names no 6")

    # The word left behind after the enum case it stood for was renamed.
    failures += case(
        "a name that no longer spells its case",
        edit(DEBUGGER, '3 => { return "net-rx"; }', '3 => { return "netrx"; }'),
        "rather than `net-rx`")

    # A word for a code nothing encodes: an inventory entry that outlives its
    # subject, the same failure kernel/tests' own view declarations refuse.
    failures += case(
        "a name for a state that cannot occur",
        edit(DEBUGGER, '5 => { return "signal"; }',
             '5 => { return "signal"; }\n        6 => { return "disk-io"; }'),
        "a word for a state that cannot occur")

    # The check reads process.tkb's own snapshot encoding. If that moves, the
    # check must say so rather than pass having compared nothing.
    failures += case(
        "the encoding moved out from under it",
        rename_everywhere(PROCESS, "output[index].wait_reason =",
                          "output[index].wait_code ="),
        "no ProcessWaitReason -> wait_reason encoding found")

    # And if the namer itself is gone or reshaped.
    failures += case(
        "the namer reshaped",
        edit(DEBUGGER, "private fn ddb_wait_reason_name(reason: usize) -> *u8 {",
             "private fn ddb_wait_reason_name(reason: usize) -> usize {"),
        "no longer returns *u8")

    for failure in failures:
        print(f"ERROR\tddb-wait-reason-names-controls: {failure}")
    if failures:
        print("FAIL ddb-wait-reason-names controls: the vocabulary is not "
              "held to the one the kernel encodes")
        return 1
    report_pass(
        "ddb-wait-reason-names controls",
        "the repository passes, and a reason encoded without a name, a "
        "name that no longer spells its case, a name for a code nothing "
        "encodes, a moved encoding and a reshaped namer are each "
        "refused",
        cases=CASES.ran)
    return 0


if __name__ == "__main__":
    sys.exit(main())
