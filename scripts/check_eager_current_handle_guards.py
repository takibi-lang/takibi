#!/usr/bin/env python3
"""Refuse a current_live boolean guard that also reads current_handle.

Takibi evaluates both operands of && and ||. A current_live test in the
same expression therefore cannot protect a current_handle read. This is a
narrow source check for the process-slot mistake that reached allcheck; the
language-wide evaluation policy is a separate compiler design question.
"""

from pathlib import Path
import re

from pass_line import report_pass


ROOT = Path(__file__).resolve().parent.parent
LIVE = re.compile(r"execution_here\(\)\.current_live")
HANDLE = re.compile(r"execution_here\(\)\.current_handle")


def findings(source: str) -> list[int]:
    source = re.sub(r"/\*.*?\*/|//[^\n]*", "", source, flags=re.DOTALL)
    found = []
    for statement in re.finditer(r"[^;]*;", source, re.DOTALL):
        text = statement.group()
        live = LIVE.search(text)
        handle = HANDLE.search(text)
        if (live is not None and handle is not None and
                live.end() < handle.start() and
                re.search(r"&&|\|\|", text[live.end():handle.start()])):
            found.append(source.count("\n", 0, statement.start() + live.start()) + 1)
    return found


def main() -> int:
    files = sorted((ROOT / "kernel").rglob("*.tkb"))
    violations = []
    for path in files:
        for line in findings(path.read_text(encoding="ascii")):
            violations.append(f"{path.relative_to(ROOT)}:{line}")
    if violations:
        for violation in violations:
            print(f"ERROR\t{violation}: eager current_live guard reads current_handle")
        print(f"FAIL eager-current-handle-guards: {len(violations)} unsafe expressions")
        return 1
    report_pass("eager-current-handle-guards",
                f"no eager current_live/current_handle guard in {len(files)} kernel files",
                files=len(files))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
