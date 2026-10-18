#!/usr/bin/env python3
"""Reject direct absolute numeric addresses cast to Takibi MMIO pointers."""

from __future__ import annotations

import re
import sys
from pathlib import Path

from pass_line import report_pass
from source_scan import code_skeleton


NUMBER = r"(?:0x[0-9A-Fa-f_]+|[0-9][0-9_]*)"
NUMERIC_ADDRESS = rf"{NUMBER}(?:\s*[+-]\s*{NUMBER})*"
DIRECT_MMIO = re.compile(
    rf"(?:\(\s*{NUMERIC_ADDRESS}\s*\)|"
    rf"(?<![A-Za-z0-9_)]){NUMERIC_ADDRESS})\s+as\s+\*io\b")


def code_without_comments_or_strings(text: str) -> str:
    """Comments and string literals blanked: source_scan's lexer since GitHub
    issue #818, which also keeps a `//` inside a string from opening a
    comment."""
    return code_skeleton(text)


def source_files(arguments: list[str]) -> list[Path]:
    roots = [Path(argument) for argument in arguments] or [Path("kernel")]
    files: list[Path] = []
    for root in roots:
        if root.is_dir():
            files.extend(root.rglob("*.tkb"))
        elif root.suffix == ".tkb":
            files.append(root)
    return sorted(files)


# GitHub issue #526: the fast gate discovers its members by glob and runs
# each with no arguments, so the root the Makefile used to pass is the
# default. Naming one explicitly still works, which is what the control does.
DEFAULT_ROOTS = ("kernel",)


def main() -> int:
    files = source_files(list(sys.argv[1:]) or list(DEFAULT_ROOTS))
    failures: list[str] = []
    for path in files:
        code = code_without_comments_or_strings(path.read_text())
        for match in DIRECT_MMIO.finditer(code):
            line = code.count("\n", 0, match.start()) + 1
            failures.append(f"{path}:{line}: direct absolute MMIO pointer cast")
    if failures:
        print("FAIL direct-mmio-literals:")
        for failure in failures:
            print(f"  {failure}")
        print("Resolve the device base from the boot DTB or derive the address "
              "from an already-validated resource base.")
        return 1
    report_pass("direct-mmio-literals",
                f"no numeric physical address is cast directly to *io in "
                f"{len(files)} files",
                files=len(files))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
