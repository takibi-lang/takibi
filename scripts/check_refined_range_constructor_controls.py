#!/usr/bin/env python3
"""Controls for check_refined_range_constructor.py (GitHub issue #935)."""

import contextlib
import importlib.util
import io
import sys
import tempfile
from pathlib import Path

from pass_line import CaseCount, report_pass

ROOT = Path(__file__).resolve().parent.parent
CHECKER = ROOT / "scripts" / "check_refined_range_constructor.py"
CASES = CaseCount()


def load():
    sys.path.insert(0, str(ROOT / "scripts"))
    spec = importlib.util.spec_from_file_location(
        "check_refined_range_constructor", CHECKER)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def run(checker, files=None):
    CASES.note()
    output = io.StringIO()
    with contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
        status = checker.main(files)
    return status, output.getvalue()


HEAD = "(* refined-range rules begin (#935) *)\n"
TAIL = "(* refined-range rules end *)\n"

# The rule as it stood before #935: the raw constructor, no base check.
PRE_935_SUB = """\
       | Sub ->
           (match repr t1, repr t2 with
            | TRefinedInt (a, b, base), TRefinedInt (c, d, _) ->
                TRefinedInt (a - d + 1, b - c, base)
            | _ -> refined_or_base t1 None None)
"""

FIXED_SUB = """\
       | Sub ->
           (match repr t1, repr t2 with
            | TRefinedInt (a, b, base), TRefinedInt (c, d, _) ->
                refined_or_base base (checked_sub a (d - 1)) (checked_sub b c)
            | _ -> t1)
"""

SPLIT_PATTERN = """\
        match target_ty, src_ty with
        | (TypeI8|TypeU8),
          TypeRefined (lo, hi, _) ->
            refined_or_base target_ty (Some lo) (Some hi)
"""

CONSTRUCTED_AFTER_ARROW = """\
           (match Const_env.folded_value e with
            | Some k -> TRefinedInt (k, k + 1, ct1)
            | None -> refined_or_base ct1 None None)
"""

COMMENTED = """\
           (* used to read TRefinedInt (a - k, b - k, base) *)
           refined_or_base base (checked_sub a k) (checked_sub b k)
"""


def main() -> int:
    checker = load()
    status, output = run(checker)
    if status != 0 or "PASS refined-range-constructor" not in output:
        print(f"FAIL refined-range-constructor control: the repository "
              f"failed\n{output}")
        return 1

    cases = [
        ("the fixed Sub rule", HEAD + FIXED_SUB + TAIL, "TRefinedInt", 0,
         "PASS refined-range-constructor"),
        ("issue #935's own raw Sub constructor", HEAD + PRE_935_SUB + TAIL,
         "TRefinedInt", 1, "raw TRefinedInt constructed"),
        ("a constructor after a match arrow", HEAD + CONSTRUCTED_AFTER_ARROW
         + TAIL, "TRefinedInt", 1, "raw TRefinedInt constructed"),
        ("a pattern split over two lines", HEAD + SPLIT_PATTERN + TAIL,
         "TypeRefined", 0, "PASS refined-range-constructor"),
        ("a raw constructor named only in a comment", HEAD + COMMENTED + TAIL,
         "TRefinedInt", 0, "PASS refined-range-constructor"),
        ("a raw constructor outside the marked rules",
         PRE_935_SUB + HEAD + FIXED_SUB + TAIL, "TRefinedInt", 0,
         "PASS refined-range-constructor"),
        ("markers removed", FIXED_SUB, "TRefinedInt", 1,
         "no 'refined-range rules begin' markers"),
        ("a region that never ends", HEAD + FIXED_SUB, "TRefinedInt", 1,
         "never ends"),
        ("a region that never calls the helper",
         HEAD + "           t1\n" + TAIL, "TRefinedInt", 1,
         "never call refined_or_base"),
    ]
    with tempfile.TemporaryDirectory() as name:
        for index, (label, text, constructor, expected, needle) in \
                enumerate(cases):
            path = Path(name) / f"case{index}.ml"
            path.write_text(text, encoding="ascii")
            status, output = run(checker, {path: constructor})
            if status != expected or needle not in output:
                print(f"FAIL refined-range-constructor control: {label} "
                      f"exited {status} (expected {expected}) without "
                      f"{needle!r}\n{output}")
                return 1

    report_pass("refined-range-constructor-controls",
                "the repository passes; issue #935's raw Sub constructor, a "
                "constructor after an arrow, a lost marker, an unterminated "
                "region and a helper-free region are refused; patterns, "
                "comments and code outside the rules are not",
                cases=CASES.ran)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
