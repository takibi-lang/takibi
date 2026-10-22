#!/usr/bin/env python3
"""A process's end reaches wait4 in Linux's form, never as 128+signal.

GitHub issue #882: the kernel recorded a signal's end as exit code
128+signal -- a shell's $? convention -- and wait4 encoded it as an exit, so
WIFSIGNALED was false for a killed child. Three probes and a fixture then
encoded that value as the expectation. kernel/kernel/wait_status.tkb now
owns the encoding and linux_user/wait_status compares it with the host
Linux's wait4.

GitHub issue #886 made the recorded end a variant, ProcessEnd: Exited(u8) |
Signaled(u8). Passing an exit code where a signal's end is meant no longer
type-checks, so this check no longer reviews each
kernel_syscall_exit_current_process argument. What the type cannot see is
an integer that already mixes the two going into process_end_exited, so
this check keeps that out:
- every process_end_exited call outside wait_status.tkb passes a reviewed
  argument (ALLOWED_EXITED);
- no kernel .tkb outside wait_status.tkb adds 128 to a signal or status
  value in code (comments may describe the shell form).
"""

import re
import sys
from pathlib import Path

from pass_line import report_pass
from source_scan import code_only

ROOT = Path(__file__).resolve().parent.parent
OWNER = ROOT / "kernel" / "kernel" / "wait_status.tkb"

CALL = re.compile(r"\bprocess_end_exited\(([^;]*?)\)\s*[;),]", re.S)
ALLOWED_EXITED = {
    "x0": "exit/exit_group: the code; the constructor keeps its low byte",
    "42 - i": "the child-list probe's stamped codes 40..42",
}
SHELL_FORM = re.compile(r"\b128\s*\+|\+\s*128\b")
SIGNAL_WORD = re.compile(r"sig|status", re.I)


def main():
    failures = []
    calls = 0
    for path in sorted((ROOT / "kernel").rglob("*.tkb")):
        if path == OWNER:
            continue
        text = code_only(path.read_text())
        for match in CALL.finditer(text):
            calls += 1
            argument = " ".join(match.group(1).split())
            if argument not in ALLOWED_EXITED:
                line = text.count("\n", 0, match.start()) + 1
                failures.append(
                    f"{path.relative_to(ROOT)}:{line}: exit code `{argument}` "
                    "is not a reviewed form; a signal's end is "
                    "process_end_signaled, and a code is never 128+signal "
                    "(#882, #886)")
    if calls < len(ALLOWED_EXITED):
        failures.append(f"only {calls} process_end_exited call(s) found; the "
                        "pattern no longer matches")
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
                f"{calls} process_end_exited call(s) reviewed, no 128+signal form in "
                f"{scanned} kernel file(s)",
                calls=calls, files=scanned)
    return 0


if __name__ == "__main__":
    sys.exit(main())
