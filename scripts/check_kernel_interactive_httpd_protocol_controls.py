#!/usr/bin/env python3
"""Controls for check_kernel_interactive_httpd_protocol.py.

GitHub issue #818: every fragment that check requires is a code property of
a shell runner, a Python driver, an inittab or a .tkb file, and a step left
only in a comment performs nothing. Each case copies the files the check
reads into a temporary tree, plants one step inside a comment in that
file's own comment syntax, and requires the check (run in-process, no
child) to refuse it; a forbidden name mentioned only in a comment passes.
"""

import contextlib
import io
import pathlib
import sys
import tempfile

import check_kernel_interactive_httpd_protocol as check
from pass_line import CaseCount, report_pass

REPO = check.ROOT
FILES = (
    "kernel/tests/ext2/inittab", "kernel/tests/ext2/inittab.shell",
    "kernel/kernel/syscall.tkb", "kernel/net/tcp.tkb",
    "scripts/run_kernel_shell_console.py", "scripts/run_kernel_shell_qemu.sh",
    "scripts/run_kernel_shell_rpi5.sh", "scripts/kernel_net_test.py",
    "scripts/run_kernel_uart_driver.py",
) + check.RUNNERS
CASES = CaseCount()


def verdict(plants) -> tuple[int, str]:
    with tempfile.TemporaryDirectory() as raw:
        root = pathlib.Path(raw)
        for relative in FILES:
            target = root / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text((REPO / relative).read_text(encoding="utf-8"),
                              encoding="utf-8")
        for relative, old, new in plants:
            target = root / relative
            text = target.read_text(encoding="utf-8")
            assert text.count(old) == 1, f"{relative}: {old!r} is not unique"
            target.write_text(text.replace(old, new, 1), encoding="utf-8")
        report = io.StringIO()
        with contextlib.redirect_stdout(report):
            status = check.main(root)
        return status, report.getvalue()


def main() -> int:
    failures = []
    CASES.note()
    status, report = verdict(())
    if status != 0:
        failures.append(f"the copied tree does not pass: {report.strip()!r}")
    refused = {
        "inittab respawn only in a comment":
            (("kernel/tests/ext2/inittab", "null::respawn:/bin/taskset",
              "# null::respawn:/bin/taskset"), "does not respawn"),
        "listener gate only in a Python comment":
            (("scripts/run_kernel_shell_console.py", "LISTENER_MARKERS = (b",
              "# LISTENER_MARKERS = (b"), "exact listener readiness"),
        "idle sleep only in a Python comment":
            (("scripts/kernel_net_test.py", "time.sleep(HTTPD_IDLE_SECONDS)",
              "pass  # time.sleep(HTTPD_IDLE_SECONDS)"), "after the accept deadline"),
        "runner listener argument only in a shell comment":
            (("scripts/run_kernel_qemutest.sh",
              '    --interactive-httpd-listener-file "$INTERACTIVE_HTTPD_LISTENER" \\',
              '    \\\n    # --interactive-httpd-listener-file "$INTERACTIVE_HTTPD_LISTENER" \\'),
             "missing init-managed HTTPd protocol step"),
        "accept deadline only in a .tkb comment":
            (("kernel/net/tcp.tkb", "accept_deadline_ticks = counter_frequency",
              "// accept_deadline_ticks = counter_frequency"),
             "after the accept deadline"),
    }
    for name, (plant, want) in refused.items():
        CASES.note()
        status, report = verdict((plant,))
        if status == 0:
            failures.append(f"{name}: passed")
        elif want not in report:
            failures.append(f"{name}: reported {report.strip()!r}, not {want!r}")
    CASES.note()
    status, report = verdict((("kernel/kernel/syscall.tkb",
                               "KernelTcpAcceptStep::GaveUp(next) => {",
                               "KernelTcpAcceptStep::GaveUp(next) => { "
                               "// foreground_server_should_bound"),))
    if status != 0:
        failures.append(f"a forbidden name mentioned only in a comment was "
                        f"refused: {report.strip()!r}")
    for failure in failures:
        print(f"ERROR\tkernel-interactive-httpd-protocol-controls: {failure}")
    if failures:
        print("FAIL kernel-interactive-httpd-protocol controls")
        return 1
    report_pass("kernel-interactive-httpd-protocol controls",
                "the copied tree passes, a protocol step kept only in a shell, "
                "Python, inittab or .tkb comment is refused, and a forbidden "
                "name in a comment is not", cases=CASES.ran)
    return 0


if __name__ == "__main__":
    sys.exit(main())
