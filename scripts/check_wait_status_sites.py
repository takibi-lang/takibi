#!/usr/bin/env python3
"""A process's end reaches wait4 in Linux's form, never as 128+signal.

GitHub issue #882: the kernel recorded a signal's end as exit code
128+signal -- a shell's $? convention -- and wait4 encoded it as an exit, so
WIFSIGNALED was false for a killed child. Three probes and a fixture then
encoded that value as the expectation. kernel/kernel/wait_status.tkb now
owns the encoding (syscall_status_signaled / syscall_wait_status_word) and
linux_user/wait_status compares it with the host Linux's wait4.

This check keeps the class out:
- every kernel_syscall_exit_current_process call in kernel/kernel/syscall.tkb
  passes a reviewed form of status (ALLOWED_ARGUMENTS);
- no kernel .tkb outside wait_status.tkb adds 128 to a signal or status
  value in code (comments may describe the shell form).
"""

import re
import sys
from pathlib import Path

from pass_line import report_pass
from source_scan import code_only

ROOT = Path(__file__).resolve().parent.parent
SYSCALL = ROOT / "kernel" / "kernel" / "syscall.tkb"
OWNER = ROOT / "kernel" / "kernel" / "wait_status.tkb"

CALL = re.compile(r"kernel_syscall_exit_current_process\(\s*current_authority\s*,\s*([^;]*?)\)\s*[;{]",
                  re.S)
ALLOWED_ARGUMENTS = {
    "syscall_status_signaled(LINUX_SIGSEGV)": "bad or unwritable signal frame",
    "syscall_status_signaled(x1)": "self-directed terminating kill",
    "status": "the taken termination signal, built by syscall_status_signaled",
    "x0 & 0xFF": "exit/exit_group: the code's low byte, as Linux keeps",
}
SHELL_FORM = re.compile(r"\b128\s*\+|\+\s*128\b")
SIGNAL_WORD = re.compile(r"sig|status", re.I)


def main():
    failures = []
    calls = 0
    text = code_only(SYSCALL.read_text())
    for match in CALL.finditer(text):
        calls += 1
        argument = " ".join(match.group(1).split())
        if argument not in ALLOWED_ARGUMENTS:
            line = text.count("\n", 0, match.start()) + 1
            failures.append(
                f"kernel/kernel/syscall.tkb:{line}: exit status `{argument}` "
                "is not a reviewed form; build it with syscall_status_signaled "
                "or an exit code's low byte (#882)")
    if calls < len(ALLOWED_ARGUMENTS):
        failures.append(f"only {calls} exit call(s) found; the pattern no "
                        "longer matches kernel_syscall_exit_current_process")
    scanned = 0
    for path in sorted((ROOT / "kernel").rglob("*.tkb")):
        if path == OWNER:
            continue
        scanned += 1
        for number, line in enumerate(code_only(path.read_text()).splitlines(), 1):
            if SHELL_FORM.search(line) and SIGNAL_WORD.search(line):
                failures.append(
                    f"{path.relative_to(ROOT)}:{number}: 128 + a signal or "
                    "status is a shell's $?, not a wait4 status word; use "
                    "kernel/kernel/wait_status.tkb (#882)")
    if failures:
        for failure in failures:
            print(f"FAIL wait-status-sites: {failure}")
        return 1
    report_pass("wait-status-sites",
                f"{calls} exit-status call(s) reviewed, no 128+signal form in "
                f"{scanned} kernel file(s)",
                calls=calls, files=scanned)
    return 0


if __name__ == "__main__":
    sys.exit(main())
