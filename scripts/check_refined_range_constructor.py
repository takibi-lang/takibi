#!/usr/bin/env python3
"""Refuse a raw refined-range constructor in the compiler's arithmetic rules.

GitHub issue #935: the range-propagation rules for `+`, `-`, `* k` and casts
each built their result with the raw constructor (`TRefinedInt (lo, hi,
base)` in lib/type_inf.ml, `TypeRefined (...)` in lib/llvm_gen.ml), and each
had to remember on its own that the machine operation wraps at the base's
width. Unsigned Sub forgot: `{0..<100} - {20..<61}` on usize kept the range
{-60..<80}, so `max(a - b, 0)` -- an unsigned compare that returns the
wrapped value -- proved an out-of-bounds index under --forbid-trap.

Every result range in those rules now goes through `refined_or_base`, which
drops a range its base cannot hold (an unsigned base needs lo >= 0). This
check keeps it that way: between the `refined-range rules begin` and `end`
markers, the raw constructor may appear only as a pattern (left of `->` in a
match arm), never as a constructed value.

GitHub issue #952: each refined_or_base call there also passes `~ob` (or
`?ob`), the operation and operands its range was derived from, so z3
re-checks it under --facts rangeobl
(scripts/buildcheck_range_obligations.py). A call that cannot describe its
operation says why in a `no-range-obligation:` comment just above it.

GitHub issue #984: min/max derived its range with min_max_range and built
it with the raw constructor outside every marked region, so no obligation
was emitted and #961's unsound {0..<10^9} placeholder on u64 was never
re-checked. A call of a range-deriving helper (DERIVERS) must now sit
inside a marked region, where its result reaches refined_or_base.
"""

from __future__ import annotations

import pathlib
import re
import sys

from pass_line import report_pass

ROOT = pathlib.Path(__file__).resolve().parents[1]
FILES = {
    ROOT / "lib/type_inf.ml": "TRefinedInt",
    ROOT / "lib/llvm_gen.ml": "TypeRefined",
}
BEGIN = "refined-range rules begin"
END = "refined-range rules end"
HELPER = "refined_or_base"
OBLIGATION_EXEMPT = "no-range-obligation:"
# Functions whose result is a derived range: called only inside the rules.
DERIVERS = ("min_max_range", "refined_product_range")
DERIVER = re.compile(r"\b(" + "|".join(DERIVERS) + r")\b")
COMMENT = re.compile(r"\(\*.*?\*\)", re.DOTALL)


def blank_comments(text: str) -> str:
    """Replace comment bodies with spaces, keeping line numbers."""
    return COMMENT.sub(lambda m: re.sub(r"[^\n]", " ", m.group(0)), text)


def is_pattern(prefix: str, suffix: str) -> bool:
    """True when the occurrence sits left of `->` in a match arm.

    A pattern split over lines (`| (TypeI8|...),` then `TypeRefined (lo,
    hi, _) ->`) is recognised by the arrow after it on its own line.
    """
    stripped = prefix.lstrip()
    if "->" not in stripped and "->" in suffix:
        return True
    if stripped.startswith("|"):
        return "->" not in stripped
    for opener in ("with ", "function "):
        at = stripped.rfind(opener)
        if at >= 0 and "->" not in stripped[at:]:
            return True
    return False


def scan(path: pathlib.Path, constructor: str, text: str) -> tuple[int, int, list[str]]:
    """Return (regions, helper uses, errors) for one source file."""
    errors: list[str] = []
    lines = text.split("\n")
    code = blank_comments(text).split("\n")
    regions = helpers = 0
    inside = False
    start = 0
    token = re.compile(r"\b" + constructor + r"\s*\(")
    for number, (raw, line) in enumerate(zip(lines, code), 1):
        if BEGIN in raw:
            if inside:
                errors.append(f"{path.name}:{number}: nested '{BEGIN}' marker")
            inside, start = True, number
            regions += 1
            continue
        if END in raw:
            if not inside:
                errors.append(f"{path.name}:{number}: '{END}' without a begin")
            inside = False
            continue
        if not inside:
            for match in DERIVER.finditer(line):
                if line[:match.start()].strip() == "let":
                    continue   # the definition itself
                errors.append(
                    f"{path.name}:{number}: {match.group(1)} called outside "
                    f"the marked rules; derive a range only inside "
                    f"'{BEGIN}' ... '{END}' so it is built through {HELPER} "
                    f"with ~ob (#984)")
            continue
        helpers += line.count(HELPER)
        for _ in re.finditer(r"\b" + HELPER + r"\b", line):
            window = " ".join(code[number - 1:number + 2])
            exempt = any(OBLIGATION_EXEMPT in l
                         for l in lines[max(0, number - 4):number])
            if "~ob" not in window and "?ob" not in window and not exempt:
                errors.append(
                    f"{path.name}:{number}: {HELPER} without ~ob; pass the "
                    f"rule and operands so z3 re-checks the range (#952), "
                    f"or say why not in a '{OBLIGATION_EXEMPT}' comment")
        for match in token.finditer(line):
            if not is_pattern(line[:match.start()], line[match.end():]):
                errors.append(
                    f"{path.name}:{number}: raw {constructor} constructed in "
                    f"a range-propagation rule; build it with {HELPER} so a "
                    f"range its base cannot hold is dropped (#935)")
    if inside:
        errors.append(f"{path.name}:{start}: '{BEGIN}' never ends")
    if regions == 0:
        errors.append(f"{path.name}: no '{BEGIN}' markers; the rules this "
                      f"check guards have lost them")
    elif helpers == 0:
        errors.append(f"{path.name}: the marked rules never call {HELPER}")
    return regions, helpers, errors


def main(files: dict[pathlib.Path, str] | None = None) -> int:
    files = FILES if files is None else files
    total_regions = total_helpers = 0
    errors: list[str] = []
    for path, constructor in files.items():
        regions, helpers, found = scan(
            path, constructor, path.read_text(encoding="ascii"))
        total_regions += regions
        total_helpers += helpers
        errors.extend(found)
    if errors:
        for error in errors:
            print(f"ERROR refined-range-constructor: {error}", file=sys.stderr)
        return 1
    report_pass("refined-range-constructor",
                f"{total_regions} marked rule regions build every range "
                f"through {HELPER} ({total_helpers} uses)",
                regions=total_regions, uses=total_helpers)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
