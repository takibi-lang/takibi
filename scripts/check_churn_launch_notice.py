#!/usr/bin/env python3
"""The churn driver times shell readiness from a notice the runner prints.

GitHub issue #1401: scripts/run_kernel_churn.py spawns `make kernelsh-qemu`,
whose make first waits for the kernel build lock; a 90 s readiness deadline
started at the spawn failed race-window 633 under allcheck. The driver now
waits, under a separate bound, for LAUNCH_NOTICE before it times readiness.
If scripts/run_kernel_shell_qemu.sh stopped printing that notice, or printed
it before the build or after QEMU, every churn would fail (or time the build
again) at run time; this refuses it at once. Lexical, with planted controls.
"""

import pathlib
import re
import sys

from pass_line import report_pass

ROOT = pathlib.Path(__file__).resolve().parents[1]
DRIVER = ROOT / "scripts" / "run_kernel_churn.py"
RUNNER = ROOT / "scripts" / "run_kernel_shell_qemu.sh"


def notice(driver: str) -> str | None:
    match = re.search(r'^LAUNCH_NOTICE = b"([^"]+)"$', driver, re.M)
    return match.group(1) if match else None


def problems(driver: str, runner: str) -> list[str]:
    text = notice(driver)
    if text is None:
        return ["run_kernel_churn.py: no LAUNCH_NOTICE constant"]
    if "LAUNCH_NOTICE in bytes(session.transcript)" not in driver:
        return ["run_kernel_churn.py: LAUNCH_NOTICE is never waited for"]
    lines = runner.splitlines()
    echoed = [i for i, line in enumerate(lines)
              if line.lstrip().startswith("echo ") and text in line]
    if len(echoed) != 1:
        return [f"run_kernel_shell_qemu.sh: echoes '{text}' {len(echoed)} times, not once"]
    qemu = [i for i, line in enumerate(lines) if "resource_lease_vcpu_acquire" in line]
    if not qemu or echoed[0] > qemu[0]:
        return [f"run_kernel_shell_qemu.sh: '{text}' is not printed before QEMU's lease"]
    return []


def main() -> int:
    driver = DRIVER.read_text(encoding="utf-8")
    runner = RUNNER.read_text(encoding="utf-8")
    errors = problems(driver, runner)
    text = notice(driver) or ""
    planted = {
        "a runner that no longer prints the notice":
            (driver, runner.replace(text, "[kernel/qemu] renamed")),
        "a notice printed after the lease":
            (driver, "\n".join(line for line in runner.splitlines()
                               if text not in line) + f'\necho "{text}"\n'),
        "a driver that never waits for it":
            (driver.replace("LAUNCH_NOTICE in bytes(session.transcript)", "True"), runner),
    }
    for name, (planted_driver, planted_runner) in planted.items():
        if not problems(planted_driver, planted_runner):
            errors.append(f"control: {name} was accepted")
    if errors:
        for error in errors:
            print(f"ERROR churn-launch-notice: {error}")
        print("FAIL churn-launch-notice: the churn's readiness clock would include the build")
        return 1
    report_pass("churn-launch-notice",
                "run_kernel_churn.py times readiness from the notice "
                "run_kernel_shell_qemu.sh prints once, before QEMU's lease; "
                "3 planted drifts are refused",
                notices=runner.count(text), controls=len(planted))
    return 0


if __name__ == "__main__":
    sys.exit(main())
