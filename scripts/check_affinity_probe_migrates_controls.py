#!/usr/bin/env python3
"""Controls for the affinity-probe premise check.

The repository passes today, so a control that only ran the check would prove
nothing. Each rule is exercised against a synthetic tree, built here rather
than copied: what is under test is the rules, and a minimal tree makes each
planted defect the only difference between a pass and a fail.

The case that matters is the second: the peer-safety table admitting the very
syscall the probe uses to make the migration gate fire. That is what phase B
entry 6 did to `uname`, and until this check existed the only thing that
noticed was a full QEMU lane reporting it as a gate that stopped working.
"""

import pathlib
import shutil
import subprocess
import sys
import tempfile

from pass_line import CaseCount, report_pass

REPO = pathlib.Path(__file__).resolve().parent.parent
CHECK = "scripts/check_affinity_probe_migrates.py"
PROBE = "kernel/arch/arm64/kernel/affinity_probe.tkb"
WATCHER = "scripts/kernel_affinity_gdb_check.py"
SYSCALL = "kernel/kernel/syscall.tkb"

PROBE_TEXT = '''const WRITE_SYSCALL: usize = 64;
const GETCWD_SYSCALL: usize = 17;

fn affinity_probe() {
    let answer: usize = svc5(GETCWD_SYSCALL, 0, 8, 0, 0, 0);
    affinity_say(bs"affinity: pinned to cpu 1, where getcwd, outside the peer-safe table, still answered\\n");
}
'''

WATCHER_TEXT = "MIGRATED_SYSCALL = 17\n"

SYSCALL_TEXT = '''const AARCH64_NR_UNAME: usize = 160;

fn syscall_peer_safe(number: usize, fd: usize) -> bool {
    if (number == 172 || number == 173 || (number >= 174 && number <= 177)) {
        return true;
    }
    if (number == AARCH64_NR_UNAME) { return true; }
    return false;
}
'''


def build(root, probe=None, watcher=None, syscall=None):
    (root / "scripts").mkdir(parents=True)
    for script in ("check_affinity_probe_migrates.py", "pass_line.py"):
        shutil.copy(REPO / "scripts" / script, root / "scripts" / script)
    (root / "kernel" / "arch" / "arm64" / "kernel").mkdir(parents=True)
    (root / "kernel" / "kernel").mkdir(parents=True)
    (root / PROBE).write_text(PROBE_TEXT if probe is None else probe,
                              encoding="ascii")
    (root / WATCHER).write_text(WATCHER_TEXT if watcher is None else watcher,
                                encoding="ascii")
    (root / SYSCALL).write_text(SYSCALL_TEXT if syscall is None else syscall,
                                encoding="ascii")


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
    elif "migrates" not in report:
        failures.append(f"the repository passed about something else: "
                        f"{report.strip()!r}")

    failures += case("a well-formed tree", "GETCWD_SYSCALL (17) migrates",
                     should_fail=False)

    # Entry 6's own failure mode: the table admits the probe's syscall.
    failures += case(
        "the table admits the syscall the probe migrates",
        "the lane's premise is false",
        syscall=SYSCALL_TEXT.replace(
            "if (number == AARCH64_NR_UNAME) { return true; }",
            "if (number == AARCH64_NR_UNAME || number == 17) { return true; }"))

    # The same, reached through a named constant rather than a literal,
    # because that is how the table is actually written.
    failures += case(
        "the table admits it through a named constant",
        "the lane's premise is false",
        syscall=SYSCALL_TEXT.replace(
            "const AARCH64_NR_UNAME: usize = 160;",
            "const AARCH64_NR_UNAME: usize = 160;\n"
            "const AARCH64_NR_GETCWD: usize = 17;").replace(
            "if (number == AARCH64_NR_UNAME) { return true; }",
            "if (number == AARCH64_NR_UNAME ||\n"
            "        number == AARCH64_NR_GETCWD) { return true; }"))

    # A watcher waiting for a syscall the probe does not issue would let the
    # lane pass only if something else happened to migrate.
    failures += case(
        "the watcher waits for a different syscall",
        "would pass only if some other syscall",
        watcher="MIGRATED_SYSCALL = 160\n")

    failures += case(
        "the printed line names a syscall nothing declares",
        "one of the two was renamed alone",
        probe=PROBE_TEXT.replace("where getcwd, outside", "where uname, outside"))

    failures += case(
        "the constant is declared and never issued",
        "never passed to svc5",
        probe=PROBE_TEXT.replace("svc5(GETCWD_SYSCALL,", "svc5(WRITE_SYSCALL,"))

    failures += case(
        "the probe stops saying what it migrated",
        "no longer prints the pinned line",
        probe=PROBE_TEXT.replace("affinity: pinned to cpu 1, where getcwd, "
                                 "outside the peer-safe table, still answered",
                                 "affinity: done"))

    failures += case(
        "the watcher stops naming the syscall it waits for",
        "no longer names MIGRATED_SYSCALL",
        watcher="WATCHED = 17\n")

    failures += case(
        "the peer-safety table is reshaped",
        "missing or reshaped",
        syscall=SYSCALL_TEXT.replace("fn syscall_peer_safe(number: usize, "
                                     "fd: usize) -> bool {",
                                     "fn syscall_peer_allows(number: usize, "
                                     "fd: usize) -> bool {"))

    for failure in failures:
        print(f"ERROR\taffinity-probe-migrates-controls: {failure}")
    if failures:
        print("FAIL affinity-probe-migrates controls: the affinity lane's "
              "premise can still be falsified silently")
        return 1
    report_pass(
        "affinity-probe-migrates controls",
        "the repository and a well-formed tree pass, and a table that admits "
        "the probe's syscall (by literal or by constant), a watcher waiting "
        "for a different one, a renamed printed line, a constant never "
        "issued, a probe that stops saying what it migrated, a watcher that "
        "stops naming it, and a reshaped table are each refused",
        cases=CASES.ran)
    return 0


if __name__ == "__main__":
    sys.exit(main())
