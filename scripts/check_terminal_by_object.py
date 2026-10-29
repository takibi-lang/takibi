#!/usr/bin/env python3
"""The terminal is recognized by its descriptor's object, never by fd number.

GitHub issue #1222. Before #902, poll, the ppoll UART wait, read and the
peer-safety read admission each recognized the terminal as `fd == 0 &&
kernel_syscall_terminal_is_open(fd)`, so a dup of the terminal (the tty ash
saves) was never ready and could not be read. The descriptor table already
knows what a descriptor names; the number is incidental.

This refuses, in kernel/kernel/*.tkb, a comparison of a descriptor name
(`fd`, or a name ending in `_fd`) with 0, 1 or 2. A comparison with any
other literal (mmap's 0xFFFFFFFFFFFFFFFF "no descriptor") is not a terminal
test and is left alone; a line that has a real reason to compare with a
standard number can say so with `fd-number-ok: <reason>` in a comment.

Usage: check_terminal_by_object.py [kernel_dir]
"""

import pathlib
import re
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

from pass_line import report_pass  # noqa: E402
from source_scan import code_only  # noqa: E402

ROOT = pathlib.Path(__file__).resolve().parent.parent
FD_NUMBER = re.compile(r"\b(?:fd|\w+_fd)\s*(?:==|!=)\s*[012]\b(?!x)")
ALLOW = "fd-number-ok:"


def problems_in(name, text):
    found = []
    code_lines = code_only(text).splitlines()
    for number, line in enumerate(text.splitlines(), 1):
        code = code_lines[number - 1] if number <= len(code_lines) else ""
        if FD_NUMBER.search(code) and ALLOW not in line:
            found.append(f"{name}:{number}: compares a descriptor with a standard "
                         f"number ({line.strip()}); ask what the descriptor names "
                         "(kernel_syscall_terminal_is_open(fd)) instead (#902, #1222)")
    return found


def controls():
    """Each case and whether it must be refused."""
    cases = [
        ("if (fd == 0 && kernel_syscall_terminal_is_open(fd)) {", True),
        ("if (out_fd != 1) { return; }", True),
        ("if (kernel_syscall_terminal_is_open(fd)) {", False),
        ("fd != 0xFFFFFFFFFFFFFFFF || (prot & 0x4) != 0) {", False),
        ("if (fd == 2) { // fd-number-ok: stderr is the console by ABI", False),
        ("// fd == 0 in a comment only", False),
    ]
    failed = [text for text, refused in cases
              if bool(problems_in("control", text)) != refused]
    return failed, len(cases)


def main(argv):
    kernel = pathlib.Path(argv[1]) if len(argv) > 1 else ROOT / "kernel" / "kernel"
    failed, ran = controls()
    if failed:
        for text in failed:
            print(f"FAIL terminal-by-object control: {text!r}")
        return 1
    files = sorted(kernel.glob("*.tkb"))
    problems = []
    for path in files:
        problems += problems_in(path.relative_to(ROOT) if path.is_relative_to(ROOT)
                                else path, path.read_text(encoding="utf-8"))
    if problems:
        for problem in problems:
            print(f"ERROR terminal-by-object: {problem}")
        print("FAIL terminal-by-object")
        return 1
    report_pass("terminal-by-object",
                f"{len(files)} kernel files compare no descriptor with 0, 1 or 2; "
                f"{ran} controls refused or passed as specified",
                files=len(files), controls=ran)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
