#!/usr/bin/env python3
"""Controls for the platform-view parity check.

The repository passes, so a control that only ran the check would prove
nothing. Each rule is exercised against a planted copy of the view tree.

The first case is the incident: a view filed under one lane because that is
where it was written. It is planted as a mutation probe on QEMU, which is
what `ext2_mutation` actually was until 2026-09-08.
"""

import pathlib
import shutil
import subprocess
import sys
import tempfile

REPO = pathlib.Path(__file__).resolve().parent.parent
CHECK = "scripts/check_platform_view_parity.py"


def run(root):
    finished = subprocess.run(
        [sys.executable, str(root / CHECK)], cwd=root,
        capture_output=True, text=True,
        env={"PATH": "/usr/bin:/bin", "PYTHONPATH": str(root / "scripts")})
    return finished.returncode, finished.stdout + finished.stderr


def case(name, plant, want, should_fail=True):
    failures = []
    with tempfile.TemporaryDirectory() as raw:
        root = pathlib.Path(raw) / "tree"
        (root / "scripts").mkdir(parents=True)
        for script in ("check_platform_view_parity.py", "pass_line.py"):
            shutil.copy(REPO / "scripts" / script, root / "scripts" / script)
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


def plant_undeclared_view(root):
    """The incident: a view filed where it was written."""
    views = root / "kernel" / "tests" / "qemu" / "views"
    (views / "planted_mutation.filter").write_text(
        "^planted mutation:\n", encoding="ascii")
    (views / "planted_mutation.expected").write_text(
        "planted mutation: ok\n", encoding="ascii")


def plant_duplicate_expected(root):
    """Two platform copies of one expected file, which is not specificity."""
    for lane in ("qemu", "rpi5"):
        views = root / "kernel" / "tests" / lane / "views"
        (views / "boot.expected").write_text(
            "planted: identical on both\n", encoding="ascii")


def plant_stale_declaration(root):
    """A declaration outliving the view it describes."""
    target = root / "scripts" / "check_platform_view_parity.py"
    text = target.read_text(encoding="ascii")
    target.write_text(text.replace(
        "ALLOWED = {",
        'ALLOWED = {\n    ("qemu", "planted_retired"):\n'
        '        "describes a view that is not there",',
        1), encoding="ascii")


def plant_declared_view(root):
    """A new platform view that IS declared must pass."""
    views = root / "kernel" / "tests" / "rpi5" / "views"
    (views / "planted_declared.filter").write_text(
        "^planted declared:\n", encoding="ascii")
    (views / "planted_declared.expected").write_text(
        "planted declared: ok\n", encoding="ascii")
    target = root / "scripts" / "check_platform_view_parity.py"
    text = target.read_text(encoding="ascii")
    target.write_text(text.replace(
        "ALLOWED = {",
        'ALLOWED = {\n    ("rpi5", "planted_declared"):\n'
        '        "a reason a reviewer can read",',
        1), encoding="ascii")


def main() -> int:
    failures = []

    status, report = run(REPO)
    if status != 0:
        failures.append(f"the repository itself does not pass: {report.strip()!r}")
    elif "declared platform-specific" not in report:
        failures.append(f"the repository passed about something else: "
                        f"{report.strip()!r}")

    failures += case("a view filed where it was written",
                     plant_undeclared_view, "nothing says why")
    failures += case("two copies of one expected file",
                     plant_duplicate_expected, "byte-identical")
    failures += case("a declaration that outlives its view",
                     plant_stale_declaration, "no such view exists any more")
    failures += case("a declared platform view is accepted",
                     plant_declared_view, "", should_fail=False)

    for failure in failures:
        print(f"ERROR\tplatform-view-parity-controls: {failure}")
    if failures:
        print("FAIL platform-view-parity controls: the check does not refuse "
              "a test that only one lane runs for no stated reason")
        return 1
    print("PASS platform-view-parity controls: the repository passes, an "
          "undeclared platform view and two copies of one expected file are "
          "each refused, a declaration that outlives its view is refused, and "
          "a declared one is accepted")
    return 0


if __name__ == "__main__":
    sys.exit(main())
