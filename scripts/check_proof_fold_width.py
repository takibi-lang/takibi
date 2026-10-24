#!/usr/bin/env python3
"""Refuse a raw Const_env.folded_value or bound_value outside const_env.ml
(GitHub issues #956, #961).

Const_env.folded_value computes on the checker's native ints. An integer
literal is a 64-bit pattern, so 0xFFFFFFFFFFFFFFFF folds as -1, and nothing
wraps at the operand's width: the fold is the machine's value only when no
leaf or step leaves the operand's base. #952's z3 range obligations found
`0xFFFFFFFFFFFFFFFF / 64` on u64 proved {0..<1}; #956 found the same fold in
a dozen more proof paths (a Band mask, a Mod divisor, comparison narrowing,
`!=` exclusions, for-loop bounds, the signed-division overflow proof) and
each proved an index or elided a check the machine value breaks.

Every proof path now folds through Type_inf.fold_at_base / fold_at_ty (or
llvm_gen.ml's fold_at_ty), which call Const_env.folded_value_within at the
base's width. This check keeps it that way: in lib/ and bin/ (const_env.ml
itself excepted) a raw `Const_env.folded_value` is allowed only with a
`fold-not-proof:` comment on its line or within the four lines above it,
saying why the fold proves nothing (a rejection, or the value emitted).

#961: Const_env.bound_value reads a bare literal or const leaf the same
native way (0xFFFFFFFFFFFFFFFF as -1), and an unannotated for-loop counter,
a min/max operand and a singleton literal each proved a range the machine
value breaks. Proof paths read a leaf through Type_inf.bound_at_base; a raw
Const_env.bound_value takes the same `fold-not-proof:` exemption.
"""

from __future__ import annotations

import pathlib
import re
import sys

from pass_line import report_pass

ROOT = pathlib.Path(__file__).resolve().parents[1]
DIRS = ("lib", "bin")
EXCLUDED = {"const_env.ml"}
EXEMPT = "fold-not-proof:"
RAW = re.compile(r"\bConst_env\s*\.\s*(folded_value|bound_value)\b(?!_)")
COMMENT = re.compile(r"\(\*.*?\*\)", re.DOTALL)
WINDOW = 4


def blank_comments(text: str) -> str:
    """Replace comment bodies with spaces, keeping line numbers."""
    return COMMENT.sub(lambda m: re.sub(r"[^\n]", " ", m.group(0)), text)


def default_files() -> list[pathlib.Path]:
    files: list[pathlib.Path] = []
    for directory in DIRS:
        for path in sorted((ROOT / directory).glob("*.ml")):
            if path.name not in EXCLUDED:
                files.append(path)
    return files


def scan(path: pathlib.Path, text: str) -> tuple[int, list[str]]:
    """Return (exempted raw folds, errors) for one source file."""
    errors: list[str] = []
    lines = text.split("\n")
    code = blank_comments(text).split("\n")
    exempted = 0
    for number, line in enumerate(code, 1):
        for match in RAW.finditer(line):
            window = lines[max(0, number - 1 - WINDOW):number]
            if any(EXEMPT in raw for raw in window):
                exempted += 1
            else:
                errors.append(
                    f"{path.name}:{number}: raw Const_env.{match.group(1)}; "
                    f"read it at the operand's base with fold_at_base/"
                    f"fold_at_ty/bound_at_base (#956, #961), or say why it "
                    f"proves nothing in a '{EXEMPT}' comment")
    return exempted, errors


def main(files: list[pathlib.Path] | None = None) -> int:
    files = default_files() if files is None else files
    errors: list[str] = []
    exempted = 0
    for path in files:
        count, found = scan(path, path.read_text(encoding="ascii"))
        exempted += count
        errors.extend(found)
    if errors:
        for error in errors:
            print(f"ERROR proof-fold-width: {error}", file=sys.stderr)
        return 1
    report_pass("proof-fold-width",
                f"{len(files)} compiler sources fold proof-path constants at "
                f"the base width; {exempted} raw folds say why they prove "
                f"nothing",
                files=len(files))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
