#!/usr/bin/env python3
"""Regression controls for the UART driver's timeout diagnosis.

A capture that hits its deadline has two very different causes, and until
GitHub issue #509 the driver reported only what a downstream check was still
waiting for. That reads as a protocol fault: three clones running the suite at
once produced "interactive HTTPd lifecycle stalled", and the truth was that a
starved host had stopped the guest dead. The note these controls cover is what
tells the two apart.
"""

import importlib.util
import pathlib
import sys

from pass_line import CaseCount, report_pass

REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
DRIVER = REPO_ROOT / "scripts" / "run_kernel_uart_driver.py"

# Two real boot lines, kept as separate literals: scripts/
# check_kernel_log_expectations.py reads a host-side string that looks like a
# kernel line and checks the kernel can emit it, and one literal holding two
# lines is not a line anything emits.
BOOT = (b"takibi kernel: EL1\r\n"
        b"linux socket: listener ready port=8080\r\n")


def load_driver():
    spec = importlib.util.spec_from_file_location("uart_driver", DRIVER)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


# GitHub issue #526: a control asserts the number of scenarios it ran.
CASES = CaseCount()


def main() -> int:
    driver = load_driver()
    failures = []

    def silence_note(*arguments):
        """One scenario: ask the driver to explain one captured silence."""
        CASES.note()
        return driver.silence_note(*arguments)

    stopped = silence_note(67.3, 90.0, BOOT)
    if "stopped rather than ran late" not in stopped:
        failures.append("a guest that went quiet was not reported as stopped")
    if "67.3s" not in stopped:
        failures.append("the silence was not quantified")
    if "listener ready port=8080" not in stopped:
        failures.append("the last line the guest managed was not named")

    slow = silence_note(0.2, 90.0, BOOT)
    if "still sending" not in slow:
        failures.append("a guest still talking was not distinguished from one "
                        "that stopped")
    if "stopped rather than ran late" in slow:
        failures.append("a slow guest was reported as stopped")

    # The boundary is a stated constant, so check it rather than a literal.
    if "still sending" not in silence_note(
            driver.SILENCE_SECONDS - 0.01, 90.0, BOOT):
        failures.append("just under the threshold was treated as stopped")
    if "stopped rather" not in silence_note(
            driver.SILENCE_SECONDS, 90.0, BOOT):
        failures.append("the threshold itself was treated as slow")

    # A guest that never said anything still has to produce a usable line.
    if "(nothing at all)" not in silence_note(90.0, 90.0, b""):
        failures.append("a capture with no output at all named no last line")

    # The main QEMU and RPi5 lanes keep two CPU-bound processes alive after
    # their measurement. Their final profile report can hold the IRQ-masking
    # process lock while emitting much more than the UART RX FIFO can retain.
    # Sending the interactive command before that boundary loses its newline,
    # leaving ash blocked on the remainder forever.
    workload_marker = "workload: busy pair done"
    before_workload = b"persistent shell: uart blocked\n"
    after_workload = (before_workload +
                      b"workload: busy pair done\n")
    if driver.workload_ready(before_workload, workload_marker):
        failures.append("the interactive workload gate opened before its marker")
    if not driver.workload_ready(after_workload, workload_marker):
        failures.append("the interactive workload gate stayed closed after its marker")
    if not driver.workload_ready(before_workload, None):
        failures.append("an ungated lane was made to wait for a workload marker")

    for failure in failures:
        print(f"ERROR\tuart-driver-silence: {failure}")
    if failures:
        print("FAIL uart-driver-silence: a timed-out capture does not explain "
              "itself")
        return 1
    report_pass(
        "uart-driver-silence",
        "a timed-out capture says whether the guest stopped or merely "
        "ran late and names its last line; an interactive command waits "
        "for its requested workload boundary",
        cases=CASES.ran)
    return 0


if __name__ == "__main__":
    sys.exit(main())
