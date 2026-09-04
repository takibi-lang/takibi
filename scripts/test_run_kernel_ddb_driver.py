#!/usr/bin/env python3
"""Regression controls for the DDB driver's alternative BREAK triggers."""

import importlib.util
import pathlib
import subprocess
import sys


REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
DRIVER = REPO_ROOT / "scripts" / "run_kernel_ddb_driver.py"


def load_driver():
    spec = importlib.util.spec_from_file_location("ddb_driver", DRIVER)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main() -> int:
    driver = load_driver()
    failures = []

    if driver.break_triggered(b"booting\n", None, 0.0, 100.0):
        failures.append("default mode fired without its marker")
    if not driver.break_triggered(driver.BREAK_MARKER, None, 99.9, 100.0):
        failures.append("default mode did not fire on its marker")

    if driver.break_triggered(driver.BREAK_MARKER, 5.0, 98.0, 100.0):
        failures.append("silence mode fired on the marker")
    if driver.break_triggered(b"ordinary output\n", 5.0, 96.0, 100.999):
        failures.append("silence mode fired before its quiet interval")
    if not driver.break_triggered(
            b"ordinary output\n", 5.0, 95.0, 100.0):
        failures.append("silence mode did not fire at its boundary")

    # Receiving ordinary output resets last_activity. The same wall-clock
    # instant must therefore stop satisfying the trigger.
    if driver.break_triggered(b"more output\n", 5.0, 99.0, 100.0):
        failures.append("ordinary output did not postpone the trigger")
    if driver.receive_wait(0.01, 100.0, 100.0) != 0.01:
        failures.append("a short silence interval was quantized to the poll")
    if driver.receive_wait(5.0, 95.0, 100.0) != 0.0:
        failures.append("an elapsed silence interval still waited for input")
    if driver.receive_wait(None, 0.0, 100.0) != 0.25:
        failures.append("default mode changed its serial poll interval")

    too_short = subprocess.run(
        [
            sys.executable, str(DRIVER),
            "--serial-port", "1",
            "--qmp-port", "2",
            "--kernel-address", "0",
            "--log", "/dev/null",
            "--break-on-silence", "0.1",
        ],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        check=False,
    )
    if too_short.returncode == 0:
        failures.append("a sub-second silence interval was accepted")
    if "--break-on-silence must be at least one second" not in too_short.stdout:
        failures.append("sub-second rejection omitted its diagnostic")

    for failure in failures:
        print(f"ERROR\tddb-driver-trigger: {failure}")
    if failures:
        print("FAIL ddb-driver-trigger: BREAK trigger selection is wrong")
        return 1
    print("PASS ddb-driver-trigger: marker remains the default; silence fires "
          "only after a complete quiet interval")
    return 0


if __name__ == "__main__":
    sys.exit(main())
