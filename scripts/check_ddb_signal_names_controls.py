#!/usr/bin/env python3
"""Controls for the DDB signal-vocabulary check.

The repository passes today, so a control that only ran the check would prove
nothing. Each rule is exercised against a planted copy of the three files it
reads.

The case that matters is the first: a signal kill(2) accepts and the
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
RUNNER = "scripts/ddb_qemu_checks.py"


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
        for relative in (SYSCALL, DEBUGGER, RUNNER):
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
    elif "27 signal(s) kill(2) accepts" not in report:
        failures.append(f"the repository passed about an unexpected "
                        f"vocabulary size: {report.strip()!r}")

    # A signal kill(2) accepts with no word. The kernel keeps working and
    # the view prints it as a hex remainder.
    failures += case(
        "a signal accepted and not named",
        edit(DEBUGGER, '        10 => { return "sigusr1" as *u8; }\n', ""),
        "has no arm for it")

    # A word beside the wrong number reads as a correct view.
    failures += case(
        "a word that does not spell its number",
        edit(DEBUGGER, '15 => { return "sigterm" as *u8; }',
             '15 => { return "sigkill" as *u8; }'),
        "rather than `sigterm`")

    # A word for a number the renderer never walks.
    failures += case(
        "a word outside the walked signals",
        edit(DEBUGGER, '        _ => { return "sig?" as *u8; }',
             '        32 => { return "sigrtmin" as *u8; }\n'
             '        _ => { return "sig?" as *u8; }'),
        "outside the 31 standard signals")

    # The GDB view spells the constants: one beside the wrong number, or one
    # missing, makes the two debuggers disagree about a bit.
    failures += case(
        "a GDB constant beside the wrong number",
        edit(DEBUGGER, "const DDB_SIGNAL_SIGCHLD: usize = 17;",
             "const DDB_SIGNAL_SIGCHLD: usize = 18;"),
        "not that signal's Linux number")
    failures += case(
        "a GDB constant missing",
        edit(DEBUGGER, "const DDB_SIGNAL_SIGUSR1: usize = 10;\n", ""),
        "no DDB_SIGNAL_SIGUSR1")

    # kill(2) widened past what the view names.
    failures += case(
        "kill accepting real-time signals",
        edit(SYSCALL, "_ => { return signum <= 31; }",
             "_ => { return signum <= 33; }"),
        "renderer names only 1..31")

    # A remainder mask one bit short prints that signal twice; one bit over
    # hides a bit from a view that claims to drop nothing.
    failures += case(
        "a named bit left in the remainder",
        edit(DEBUGGER, "const DDB_STANDARD_SIGNAL_BITS: usize = 0x7FFFFFFF;",
             "const DDB_STANDARD_SIGNAL_BITS: usize = 0x3FFFFFFF;"),
        "print a signal twice")
    failures += case(
        "an unnamed bit subtracted from the remainder",
        edit(DEBUGGER, "const DDB_STANDARD_SIGNAL_BITS: usize = 0x7FFFFFFF;",
             "const DDB_STANDARD_SIGNAL_BITS: usize = 0xFFFFFFFF;"),
        "drop a bit hidden")

    # The check reads syscall.tkb's own match. If that moves, the check
    # must say so rather than pass having compared nothing.
    failures += case(
        "the accepted set moved out from under it",
        edit(SYSCALL, "fn kill_signal_accepted(signum: usize) -> bool {",
             "fn kill_signal_allowed(signum: usize) -> bool {"),
        "no kill_signal_accepted")

    # And if the renderer itself is gone or reshaped.
    failures += case(
        "the renderer reshaped",
        edit(DEBUGGER, "private fn ddb_put_signal_set(set: usize) !{unsafe} {",
             "private fn ddb_put_signal_set(bits: usize) !{unsafe} {"),
        "is missing or reshaped")

    failures += case(
        "a stale signal alternative in the runner",
        edit(RUNNER, 'SIGNALS = (r"(none|sig(hup|int|',
             'SIGNALS = (r"(none|sig(int|'),
        "runner signal vocabulary rejects")
    failures += case(
        "a stale real-state mask gate",
        edit(RUNNER, "masked=sig(hup|int|quit|ill|trap|abrt|bus|fpe|kill|usr1|segv|usr2|pipe|alrm|term|stkflt|chld|cont|stop|tstp|ttin|ttou|urg|xcpu|xfsz|vtalrm|prof|winch|io|pwr|sys)([,+]|$)",
             "masked=sig(term|chld)([,+]|$)"),
        "runner signal vocabulary does not exercise")

    for failure in failures:
        print(f"ERROR\tddb-signal-names-controls: {failure}")
    if failures:
        print("FAIL ddb-signal-names controls: the vocabulary is not held to "
              "the signals the kernel accepts")
        return 1
    report_pass(
        "ddb-signal-names controls",
        "the repository passes, and a signal accepted without a word, a "
        "word beside the wrong number, a GDB constant wrong or missing, a word outside the walked signals, "
        "kill widened past the view, a named bit printed twice, an unnamed "
        "bit dropped, a moved accepted set and a reshaped renderer are each "
        "refused",
        cases=CASES.ran)
    return 0


if __name__ == "__main__":
    sys.exit(main())
