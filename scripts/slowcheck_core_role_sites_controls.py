#!/usr/bin/env python3
"""Controls for the core-role site check (GitHub issue #775).

The repository passes, so a control that only ran the check would prove
nothing. The cases below plant the defect the check exists for -- the #497
shape, a secondary-only branch with no recorded reason -- and the ways a
check of this shape stops examining: a declaration outliving its file, and
the inventory section it points to disappearing.
"""

import pathlib
import shutil
import subprocess
import sys
import tempfile

from pass_line import CaseCount, report_pass

REPO = pathlib.Path(__file__).resolve().parent.parent
CHECK = "scripts/check_core_role_sites.py"


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
        for script in ("check_core_role_sites.py", "pass_line.py", "source_scan.py"):
            shutil.copy(REPO / "scripts" / script, root / "scripts" / script)
        shutil.copytree(REPO / "kernel", root / "kernel",
                        ignore=shutil.ignore_patterns(
                            "__pycache__", "build", "*.o", "*.elf", "*.img",
                            "*.apk", "busybox-*"))
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


def planted(path, old, new):
    def plant(root):
        target = root / path
        text = target.read_text(encoding="ascii")
        assert text.count(old) == 1, f"{path}: {old!r} is not a unique anchor"
        target.write_text(text.replace(old, new, 1), encoding="ascii")
    return plant


def main() -> int:
    failures = []

    status, report = run(REPO)
    if status != 0:
        failures.append(f"the repository itself does not pass: {report.strip()!r}")
    elif "none is special without saying why" not in report:
        failures.append(f"the repository passed about something else: "
                        f"{report.strip()!r}")

    # GitHub issue #497's shape: a branch only secondaries take, with no
    # sentence saying why core 0 is different.
    failures += case(
        "a new secondary-only branch with no reason",
        planted("kernel/arch/arm64/kernel/timer.tkb",
                "fn timer_irq_handler() !{interrupt, unsafe} {\n",
                "fn timer_irq_handler() !{interrupt, unsafe} {\n"
                "    if (cpu_id() != 0) { return; }\n"),
        "kernel/arch/arm64/kernel/timer.tkb")

    # The reversed operand order is the same comparison.
    failures += case(
        "a reversed comparison",
        planted("kernel/arch/arm64/kernel/timer.tkb",
                "fn timer_irq_handler() !{interrupt, unsafe} {\n",
                "fn timer_irq_handler() !{interrupt, unsafe} {\n"
                "    if (1 == cpu_id()) { return; }\n"),
        "kernel/arch/arm64/kernel/timer.tkb")

    # A marker in a comment is accepted; the same site with a reason passes.
    failures += case(
        "a site with a recorded reason is not reported",
        planted("kernel/arch/arm64/kernel/timer.tkb",
                "fn timer_irq_handler() !{interrupt, unsafe} {\n",
                "fn timer_irq_handler() !{interrupt, unsafe} {\n"
                "    // core-role: planted, with a reason\n"
                "    if (cpu_id() != 0) { return; }\n"),
        "", should_fail=False)

    # The marker inside a string is not a comment.
    failures += case(
        "a marker in code, not a comment, is not a reason",
        planted("kernel/arch/arm64/kernel/timer.tkb",
                "fn timer_irq_handler() !{interrupt, unsafe} {\n",
                "fn timer_irq_handler() !{interrupt, unsafe} {\n"
                "    if (cpu_id() != 0) { kernel_boot_log(\"core-role: x\"); }\n"),
        "kernel/arch/arm64/kernel/timer.tkb")

    # A file declaration that outlives its sites.
    def remove_file(root):
        (root / "kernel/kernel/tcp_connection_contention_evidence.tkb").unlink()
    failures += case("a file declaration that outlives its file", remove_file,
                     "Remove the declaration")

    # The inventory every reason points to.
    failures += case(
        "the inventory section is gone",
        planted("kernel/CONCURRENCY.md", "## Core roles", "## Core places"),
        "Core roles")

    for failure in failures:
        print(f"ERROR\tcore-role-controls: {failure}")
    if failures:
        print("FAIL core-role controls: the check does not refuse a fixed "
              "core named without a reason")
        return 1
    report_pass(
        "core-role controls",
        "the repository passes, a secondary-only branch and its reversed "
        "comparison are refused without a reason and accepted with one, a "
        "marker outside a comment is not a reason, and a stale file "
        "declaration or a missing inventory is refused",
        cases=CASES.ran)
    return 0


if __name__ == "__main__":
    sys.exit(main())
