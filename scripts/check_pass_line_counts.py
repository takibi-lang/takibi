#!/usr/bin/env python3
"""Every `scripts/check_*.py` must report PASS through `pass_line`.

A check that reports PASS while checking nothing is worse than no check,
because PASS is read as "the property holds" and not as "I never looked".
GitHub issue #513 collected six of them in one week: a lock check whose tags
had all been renamed, a probe that visited no slot, a depfile check with a
whole directory outside its scan roots, a memory-map check whose table parse
stopped at a conflict marker, and two more.

Every one had the same repair available and unused: compute the number that
is zero when nothing was examined, and ASSERT it. Several checks in this
directory had already written that guard by hand -- `check_dead_slot_peek`'s
`calls == 0`, `check_kernel_asm_invariants`'s `total_switches == 0`,
`check_qemu_lane_ports`'s `not claimed` -- which is the evidence that the
rule is right and that remembering it case by case is what fails.

So the guard moves into `scripts/pass_line.py`, and this check enforces that
no verdict goes around it:

  1. a check script prints its PASS line only through `report_pass`;
  2. every `report_pass` call names at least one count;
  3. that count is an expression, not an integer literal, because a literal
     is the same silence in a shape that satisfies rule 2.

What this does NOT establish is that the count is the RIGHT one, or that the
scanned set was complete. `report_pass`'s docstring carries that part; it is
a judgement, and this check is deliberately only the mechanical floor under
it.

Usage: check_pass_line_counts.py [scripts_dir]
Exit code only (0 = pass, 1 = fail).
"""

from __future__ import annotations

import ast
import pathlib
import sys

from pass_line import report_pass

SCRIPTS = pathlib.Path(__file__).resolve().parent

# `report_pass` keywords that steer the report rather than count anything.
RESERVED = {"stream"}

# (script, leading text) -> why this PASS line does not go through the helper.
ALLOWED_BARE_PASS = {
    ("check_suite_output.py", "PASS\t"):
        "a per-case result row in the batched UART report, not the check's "
        "verdict; the verdict is the aggregate report_pass below it",
}


def leading_text(node: ast.AST) -> str:
    """The literal text a print starts with, or "" when it starts dynamic."""
    if isinstance(node, ast.Constant):
        return node.value if isinstance(node.value, str) else ""
    if isinstance(node, ast.JoinedStr):
        if node.values and isinstance(node.values[0], ast.Constant):
            return str(node.values[0].value)
        return ""
    if isinstance(node, ast.BinOp):
        return leading_text(node.left)
    return ""


def called_name(node: ast.Call) -> str:
    if isinstance(node.func, ast.Name):
        return node.func.id
    if isinstance(node.func, ast.Attribute):
        return node.func.attr
    return ""


def problems_in(path: pathlib.Path) -> list[str]:
    found: list[str] = []
    tree = ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
    reports = 0

    for node in ast.walk(tree):
        if not isinstance(node, ast.Call):
            continue
        name = called_name(node)

        if name == "print" and node.args:
            text = leading_text(node.args[0])
            if text.lstrip().startswith("PASS"):
                declared = any(
                    path.name == script and text.startswith(prefix)
                    for script, prefix in ALLOWED_BARE_PASS)
                if not declared:
                    found.append(
                        f"{path.name}:{node.lineno}: prints its own PASS line. "
                        "Report through pass_line.report_pass so the count it "
                        "rests on is asserted, or declare the line in "
                        "ALLOWED_BARE_PASS with the reason."
                    )
            continue

        if name != "report_pass":
            continue
        reports += 1
        counts = [word for word in node.keywords
                  if word.arg is not None and word.arg not in RESERVED]
        if any(word.arg is None for word in node.keywords):
            found.append(
                f"{path.name}:{node.lineno}: report_pass takes its counts "
                "through **kwargs, so nothing here can see what is asserted. "
                "Name them."
            )
        if not counts:
            found.append(
                f"{path.name}:{node.lineno}: report_pass names no count. Pass "
                "the number that is zero when the check examined nothing -- "
                "usually the size of the set it scanned, not the number of "
                "findings."
            )
        for word in counts:
            if isinstance(word.value, ast.Constant):
                found.append(
                    f"{path.name}:{node.lineno}: `{word.arg}` is the literal "
                    f"{word.value.value!r}, which is nonzero no matter what "
                    "the check looked at. Assert a count derived from the "
                    "scan."
                )

    if reports == 0:
        found.append(
            f"{path.name}: never calls pass_line.report_pass, so it has no "
            "asserted verdict. A check that only ever returns 0 quietly is "
            "indistinguishable from one that is not running."
        )
    return found


def main() -> int:
    scripts_dir = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else SCRIPTS
    checks = sorted(scripts_dir.glob("check_*.py"))
    problems: list[str] = []
    # This script matches its own glob, and is deliberately not skipped: it
    # reports through the helper like every other check.
    for path in checks:
        problems.extend(problems_in(path))

    if problems:
        print("ERROR: a check script can report PASS without asserting that "
              "it examined anything:")
        for problem in problems:
            print(f"  {problem}")
        return 1

    report_pass(
        "pass-line-counts",
        f"{len(checks)} check scripts report PASS through pass_line, each "
        "asserting a count that is zero when nothing was examined",
        check_scripts=len(checks),
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
