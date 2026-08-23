#!/usr/bin/env python3
"""Reject raw Lexing.pos_fname reads outside identity-preserving helpers."""

from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parent.parent

# Exact source lines are intentional: broad file/function exemptions would let
# an unrelated future read silently enter the allowlist.
ALLOWED = {
    ("lib/ast.ml", "match String.index_opt loc.Lexing.pos_fname '#' with"),
    ("lib/ast.ml", "| None -> loc.Lexing.pos_fname"),
    ("lib/ast.ml", "| Some i -> String.sub loc.Lexing.pos_fname 0 i"),
    ("lib/monomorphize.ml",
     "{ loc with Lexing.pos_fname = loc.Lexing.pos_fname ^ \"#\" ^ mangled }"),
    ("lib/types.ml",
     "Printf.sprintf \"%s:%d:%d\" loc.Lexing.pos_fname loc.Lexing.pos_lnum"),
}


def violations() -> list[str]:
    found = []
    for path in sorted((ROOT / "lib").glob("*.ml")):
        relative = str(path.relative_to(ROOT))
        for number, line in enumerate(path.read_text().splitlines(), 1):
            stripped = line.strip()
            if "Lexing.pos_fname" not in stripped:
                continue
            if (relative, stripped) not in ALLOWED:
                found.append(f"{relative}:{number}: {stripped}")
    return found


def main() -> None:
    found = violations()
    if found:
        print("ERROR: raw Lexing.pos_fname access bypasses Ast.source_file_of_loc:")
        for item in found:
            print(f"  {item}")
        return_code = 1
    else:
        print("PASS raw-pos-fname: all direct accesses are identity-key helpers")
        return_code = 0
    sys.exit(return_code)


if __name__ == "__main__":
    main()
