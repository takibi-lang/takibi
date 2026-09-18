#!/usr/bin/env python3
"""Controls for the DDB signal-vocabulary check.

The repository passes today, so a control that only ran the check would prove
nothing. Each rule is exercised against a planted copy of the two files it
reads.

The case that matters is the first: a signal kill(2) starts accepting and the
process view does not name. That is the drift the check exists for, and it is
silent in the running kernel -- the view prints a hex remainder where a word
should be, and nothing else notices.
"""

import pathlib
import shutil
import subprocess
import sys
import tempfile

from pass_line import CaseCount, report_pass

REPO = pathlib.Path(__file__).resolve().parent.parent
CHECK = "scripts/check_ddb_signal_names.py"
SYSCALL = "kernel/kernel/syscall.tkb"
DEBUGGER = "kernel/arch/arm64/kernel/exception_evidence.tkb"


def run(root):
    finished = subprocess.run(
        [sys.executable, str(root / CHECK)], cwd=root,
        capture_output=True, text=True,
        env={"PATH": "/usr/bin:/bin", "PYTHONPATH": str(root / "scripts")})
    return finished.returncode, finished.stdout + finished.stderr


# GitHub issue #526: a control asserts the number of scenarios it ran.
CASES = CaseCount()


def case(name, plants, want, should_fail=True):
    """Copy what the check reads, plant one defect, require the verdict."""
    CASES.note()
    failures = []
    with tempfile.TemporaryDirectory() as raw:
        root = pathlib.Path(raw) / "tree"
        (root / "scripts").mkdir(parents=True)
        for script in ("check_ddb_signal_names.py", "pass_line.py"):
            shutil.copy(REPO / "scripts" / script, root / "scripts" / script)
        for relative in (SYSCALL, DEBUGGER):
            target = root / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy(REPO / relative, target)
        for plant in plants if isinstance(plants, tuple) else (plants,):
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
    elif "2 signal(s) kill(2) accepts" not in report:
        failures.append(f"the repository passed about an unexpected "
                        f"vocabulary size: {report.strip()!r}")

    # A third signal, accepted by kill(2) and never named. The kernel keeps
    # working and every signal but this one prints as a word.
    failures += case(
        "a signal accepted and not named",
        (edit(SYSCALL, "const LINUX_SIGCHLD: usize = 17;",
              "const LINUX_SIGCHLD: usize = 17;\n"
              "const LINUX_SIGUSR1: usize = 10;"),
         edit(SYSCALL,
              "if (x1 != 0 && x1 != LINUX_SIGTERM && x1 != LINUX_SIGCHLD) {",
              "if (x1 != 0 && x1 != LINUX_SIGTERM && x1 != LINUX_SIGCHLD &&\n"
              "            x1 != LINUX_SIGUSR1) {")),
        "declares no DDB_SIGNAL_SIGUSR1")

    # The word left behind after the constant it stood for was renamed.
    failures += case(
        "a word that no longer spells its constant",
        edit(DEBUGGER, 'ddb_puts("sigterm");', 'ddb_puts("sigkill");'),
        "rather than `sigterm`")

    # A word for a signal that cannot be set: an inventory entry that
    # outlives its subject, the same failure the wait vocabulary refuses.
    failures += case(
        "a word for a signal kill(2) does not accept",
        edit(DEBUGGER, "const DDB_SIGNAL_SIGTERM: usize = 15;",
             "const DDB_SIGNAL_SIGHUP: usize = 1;\n"
             "const DDB_SIGNAL_SIGTERM: usize = 15;"),
        "names a signal kill(2) does not accept")

    # The number drifting apart is the defect that reads as a correct view:
    # a word beside the wrong bit is worse than no word at all.
    failures += case(
        "a number that drifted from the ABI constant",
        edit(DEBUGGER, "const DDB_SIGNAL_SIGCHLD: usize = 17;",
             "const DDB_SIGNAL_SIGCHLD: usize = 18;"),
        "the view would name the wrong bit")

    # A named bit left in the remainder prints twice: once as its word and
    # once inside the hex the view claims is what it could not name.
    failures += case(
        "a named bit left in the remainder",
        edit(DEBUGGER, "set & ~(sigterm | sigchld);", "set & ~(sigterm);"),
        "print that signal twice")

    # And a remainder that subtracts something no constant derives, which
    # drops that bit from a view whose whole claim is that nothing is lost.
    failures += case(
        "an unnamed bit subtracted from the remainder",
        edit(DEBUGGER, "set & ~(sigterm | sigchld);",
             "set & ~(sigterm | sigchld | set);"),
        "a bit hidden from a view")

    # The check reads syscall.tkb's own guard. If that moves, the check must
    # say so rather than pass having compared nothing.
    failures += case(
        "the accepted set moved out from under it",
        edit(SYSCALL, "if (number == AARCH64_NR_KILL) {",
             "if (number == AARCH64_NR_KILL || false) {"),
        "no kill(2) arm found")

    # And if the renderer itself is gone or reshaped.
    failures += case(
        "the renderer reshaped",
        edit(DEBUGGER, "private fn ddb_put_signal_set(set: usize) !{unsafe} {",
             "private fn ddb_put_signal_set(bits: usize) !{unsafe} {"),
        "is missing or reshaped")

    for failure in failures:
        print(f"ERROR\tddb-signal-names-controls: {failure}")
    if failures:
        print("FAIL ddb-signal-names controls: the vocabulary is not held to "
              "the signals the kernel accepts")
        return 1
    report_pass(
        "ddb-signal-names controls",
        "the repository passes, and a signal accepted without a word, a "
        "word that no longer spells its constant, a word for a signal that "
        "cannot be set, a drifted number, a named bit printed twice, an "
        "unnamed bit dropped, a moved accepted set and a reshaped renderer "
        "are each refused",
        cases=CASES.ran)
    return 0


if __name__ == "__main__":
    sys.exit(main())
