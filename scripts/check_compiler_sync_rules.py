#!/usr/bin/env python3
"""Inventory the type_inf.ml/llvm_gen.ml synchronization obligations.

These comments mark decisions duplicated across the checker and code generator.
The check deliberately keeps the inventory derived from source, so adding or
removing a marker updates the single printed index without a second hand-kept
document. Every marker must name the other implementation explicitly; this
catches an orphan whose counterpart reference was lost during a refactor.
"""

from __future__ import annotations

import pathlib
import re
import sys


ROOT = pathlib.Path(__file__).resolve().parents[1]
FILES = (ROOT / "lib/type_inf.ml", ROOT / "lib/llvm_gen.ml")
SYNC = re.compile(r"\bsync rule\b", re.IGNORECASE)
COMMENT = re.compile(r"\(\*.*?\*\)", re.DOTALL)


def main() -> int:
    quiet = "--quiet" in sys.argv[1:]
    unknown = [arg for arg in sys.argv[1:] if arg != "--quiet"]
    if unknown:
        print(f"usage: {pathlib.Path(sys.argv[0]).name} [--quiet]", file=sys.stderr)
        return 2
    sites: list[tuple[pathlib.Path, int, str]] = []
    errors: list[str] = []
    for path in FILES:
        text = path.read_text(encoding="ascii")
        peer = "llvm_gen" if path.name == "type_inf.ml" else "type_inf"
        for match in COMMENT.finditer(text):
            block = match.group(0)
            if not SYNC.search(block):
                continue
            line = text.count("\n", 0, match.start()) + 1
            summary = " ".join(block[2:-2].split())
            sites.append((path, line, summary))
            # A few type_inf rules explicitly synchronize with parser.mly,
            # not llvm_gen.ml; keep them in the inventory but do not invent a
            # codegen counterpart for them.
            if peer not in block and "parser.mly" not in block:
                errors.append(
                    f"{path.relative_to(ROOT)}:{line}: sync rule must name "
                    f"its {peer}.ml counterpart"
                )

    if not quiet:
        for index, (path, line, summary) in enumerate(sites, 1):
            print(f"{index:02d} {path.relative_to(ROOT)}:{line}: {summary}")

    if errors:
        for error in errors:
            print(f"ERROR: {error}", file=sys.stderr)
        return 1
    if not sites:
        print("ERROR: no compiler sync rules found", file=sys.stderr)
        return 1
    print(f"PASS compiler-sync-rules: {len(sites)} counterpart references indexed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
