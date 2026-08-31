#!/usr/bin/env python3
"""Reject direct absolute numeric addresses cast to Takibi MMIO pointers."""

from __future__ import annotations

import re
import sys
from pathlib import Path


NUMBER = r"(?:0x[0-9A-Fa-f_]+|[0-9][0-9_]*)"
NUMERIC_ADDRESS = rf"{NUMBER}(?:\s*[+-]\s*{NUMBER})*"
DIRECT_MMIO = re.compile(
    rf"(?:\(\s*{NUMERIC_ADDRESS}\s*\)|"
    rf"(?<![A-Za-z0-9_)]){NUMERIC_ADDRESS})\s+as\s+\*io\b")
STRING = re.compile(r'"(?:\\.|[^"\\])*"')


def code_without_comments_or_strings(text: str) -> str:
    output: list[str] = []
    index = 0
    in_block = False
    while index < len(text):
        if in_block:
            end = text.find("*/", index)
            if end < 0:
                output.append("\n" * text[index:].count("\n"))
                break
            output.append("\n" * text[index:end + 2].count("\n"))
            index = end + 2
            in_block = False
        elif text.startswith("/*", index):
            in_block = True
            index += 2
        elif text.startswith("//", index):
            end = text.find("\n", index)
            if end < 0:
                break
            output.append("\n")
            index = end + 1
        else:
            output.append(text[index])
            index += 1
    return STRING.sub(lambda match: " " * len(match.group(0)), "".join(output))


def source_files(arguments: list[str]) -> list[Path]:
    roots = [Path(argument) for argument in arguments] or [Path("kernel")]
    files: list[Path] = []
    for root in roots:
        if root.is_dir():
            files.extend(root.rglob("*.tkb"))
        elif root.suffix == ".tkb":
            files.append(root)
    return sorted(files)


def main() -> int:
    failures: list[str] = []
    for path in source_files(sys.argv[1:]):
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
    print("PASS direct-mmio-literals: no numeric physical address is cast "
          "directly to *io")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
