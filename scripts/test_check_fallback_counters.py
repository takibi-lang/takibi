#!/usr/bin/env python3
"""Controls for the dead-slot fallback report check.

The check refuses two things, and both are shapes this tree has actually
held: a counter nothing reads (`process_image_root_fallback_uses`, until
issue #270 hit the case it counted) and a report that adds a line rather than
losing one, which no expected file misses. A control that only ran the
repository would prove neither, since the repository passes -- so each rule is
exercised against a planted defect in a copy of the tree.

The last two cases are the ones that matter most for a check like this: they
plant "the check stopped looking" rather than "the tree is wrong", which is
the failure mode a green build cannot distinguish from success.
"""

import pathlib
import shutil
import subprocess
import sys
import tempfile

REPO = pathlib.Path(__file__).resolve().parent.parent
CHECK = "scripts/check_fallback_counters.py"
GATE_FILE = "kernel/init/test_driver.tkb"
EXPECTED = "kernel/tests/common/views/process_lifecycle.expected"
POSITIVE = "resources: every pooled record resolved to the slot its handle named"


def run(root: pathlib.Path):
    finished = subprocess.run(
        [sys.executable, str(root / CHECK)],
        cwd=root, capture_output=True, text=True,
        env={"PATH": "/usr/bin:/bin", "PYTHONPATH": str(root / "scripts")})
    return finished.returncode, finished.stdout + finished.stderr


def planted(root: pathlib.Path, path: str, old: str, new: str) -> None:
    target = root / path
    text = target.read_text(encoding="ascii")
    assert text.count(old) == 1, f"{path}: {old!r} is not a unique anchor"
    target.write_text(text.replace(old, new, 1), encoding="ascii")


def rename_all(root: pathlib.Path) -> None:
    """Rename every accessor, which is how a check quietly stops looking."""
    for path in sorted((root / "kernel").rglob("*.tkb")):
        text = path.read_text(encoding="ascii")
        renamed = (text.replace("_missing_uses(", "_missing_total(")
                       .replace("_fallback_uses(", "_fallback_total("))
        if renamed != text:
            path.write_text(renamed, encoding="ascii")


def case(name, mutate, want) -> list[str]:
    """Copy the tree, plant one defect, and require the check to name it."""
    failures = []
    with tempfile.TemporaryDirectory() as raw:
        root = pathlib.Path(raw) / "tree"
        # Only what the check reads, so a case costs a few files rather than
        # the whole repository.
        root.mkdir(parents=True)
        for part in ("scripts", "kernel"):
            shutil.copytree(REPO / part, root / part,
                            ignore=shutil.ignore_patterns(
                                "__pycache__", "build", "*.o", "*.elf",
                                "*.img", "*.apk", "busybox-*"))
        mutate(root)
        status, report = run(root)
        if status == 0:
            failures.append(f"{name}: the planted defect passed")
        elif want not in report:
            failures.append(f"{name}: reported {report.strip()!r}, which does "
                            f"not name {want!r}")
    return failures


def main() -> int:
    failures = []

    status, report = run(REPO)
    if status != 0:
        failures.append(f"the repository itself does not pass: {report.strip()!r}")
    elif "6 dead-slot fallback counter" not in report:
        failures.append(f"the repository passed about an unexpected count: "
                        f"{report.strip()!r}")

    failures += case(
        "counter with no reader",
        lambda root: planted(root, GATE_FILE,
                             "        + tcp_absent_fallback_uses();",
                             "        + 0;"),
        "tcp_absent_fallback_uses() is a dead-slot fallback counter")

    failures += case(
        "advisory report",
        lambda root: planted(root, GATE_FILE,
                             "    if (dead_slot_fallback_uses() == 0) {",
                             "    if (dead_slot_fallback_uses() == 99) {"),
        "gates no positive report")

    failures += case(
        "line no view expects",
        lambda root: planted(root, EXPECTED, POSITIVE + "\n", ""),
        "so the boot prints it and nothing notices")

    failures += case(
        "the gate itself deleted",
        lambda root: planted(root, GATE_FILE,
                             "private fn dead_slot_fallback_uses() -> usize {",
                             "private fn retired_fallback_total() -> usize {"),
        "no `fn dead_slot_fallback_uses()`")

    failures += case(
        "every accessor renamed out from under it",
        rename_all,
        "no dead-slot fallback accessor found")

    for failure in failures:
        print(f"ERROR\tfallback-counters-controls: {failure}")
    if failures:
        print("FAIL fallback-counters controls: the check does not refuse a "
              "fallback that cannot fail a lane")
        return 1
    print("PASS fallback-counters controls: the repository passes, a counter "
          "with no reader, an advisory report, an unexpected positive line, a "
          "missing gate, and a wholesale rename are each refused")
    return 0


if __name__ == "__main__":
    sys.exit(main())
