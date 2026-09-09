#!/usr/bin/env python3
"""Controls for the IRQ-restore site check.

The repository passes, so a control that only ran the check would prove
nothing. The cases below plant the defect the check exists for and the two
ways a check of this shape stops examining.

The first case is the real incident, reconstructed: GitHub issue #454's
console called `enable_irq()` unconditionally from a path DDB reaches with
interrupts already masked, and RPi5's debugger stopped coming up. It is
planted in the file it actually happened in.
"""

import pathlib
import shutil
import subprocess
import sys
import tempfile

REPO = pathlib.Path(__file__).resolve().parent.parent
CHECK = "scripts/check_irq_restore_sites.py"


def run(root):
    finished = subprocess.run(
        [sys.executable, str(root / CHECK)], cwd=root,
        capture_output=True, text=True,
        env={"PATH": "/usr/bin:/bin", "PYTHONPATH": str(root / "scripts")})
    return finished.returncode, finished.stdout + finished.stderr


def case(name, plant, want, should_fail=True):
    """Copy what the check reads, plant one defect, require the verdict."""
    failures = []
    with tempfile.TemporaryDirectory() as raw:
        root = pathlib.Path(raw) / "tree"
        (root / "scripts").mkdir(parents=True)
        for script in ("check_irq_restore_sites.py", "pass_line.py"):
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
    elif "none unmasks underneath a caller" not in report:
        failures.append(f"the repository passed about something else: "
                        f"{report.strip()!r}")

    # Issue #454's actual defect, in the file it actually happened in.
    failures += case(
        "the console unmasks under its caller",
        planted("kernel/printk/log.tkb",
                "    let irq_flags: usize = mutex_irq_save();\n"
                "    while (kernel_log_tx_full()) {",
                "    enable_irq();\n"
                "    let irq_flags: usize = mutex_irq_save();\n"
                "    while (kernel_log_tx_full()) {"),
        "kernel/printk/log.tkb")

    # The guard dropped from a site that had one: the seventeen hand-written
    # restores are one edit away from being absolute, which is the likeliest
    # route back to the incident.
    failures += case(
        "a guard dropped from a restore that had one",
        planted("kernel/kernel/profile_timeline.tkb",
                "    if (irq_was_masked == 0) { enable_irq(); }\n"
                "}",
                "    enable_irq();\n}"),
        "profile_timeline.tkb")

    # A declaration outliving its site: every entry left in the list reads as
    # current, so one that names nothing is worse than no list.
    failures += case(
        "a declaration that outlives its site",
        planted("kernel/platform/qemu/intc.tkb",
                "    enable_irq();",
                "    let irq_state: usize = mutex_irq_save();\n"
                "    mutex_irq_restore(irq_state);"),
        "no such line is there any more")

    # A NEW site written the sanctioned way must pass without being declared,
    # or the check would push people toward the declaration list instead of
    # toward the fix -- which is how an exemption list becomes an inventory.
    failures += case(
        "a new restore written the sanctioned way is not reported",
        planted("kernel/printk/log.tkb",
                "fn kernel_log_tx_pending() -> bool {",
                "fn planted_restore_probe(saved_flags: usize) {\n"
                "    if (saved_flags == 0) { enable_irq(); }\n}\n\n"
                "fn kernel_log_tx_pending() -> bool {"),
        "", should_fail=False)

    for failure in failures:
        print(f"ERROR\tirq-restore-controls: {failure}")
    if failures:
        print("FAIL irq-restore controls: the check does not refuse an "
              "unmask that consults nothing")
        return 1
    print("PASS irq-restore controls: the repository passes, issue #454's own "
          "defect and a guard dropped from a restore that had one are each "
          "refused, a declaration that outlives its site is refused, and the "
          "canonical mutex_irq_restore needs no declaration")
    return 0


if __name__ == "__main__":
    sys.exit(main())
