#!/usr/bin/env python3
"""Every z3 constant name in the compiler comes from lib/smt_name.ml.

GitHub issue #1394: two hand-rolled name encoders (#1372) were not
injective, so distinct values became one z3 constant. Smt_name.t is
abstract and its constructors share one injective encoding, but nothing
in OCaml stops a new `Printf.sprintf "x_..."` at a call site. This refuses
a string literal that starts an SMT name ("x_...") in lib/*.ml outside
smt_name.ml. Lexical; planted literals are refused.
"""

import pathlib
import re
import sys

from pass_line import report_pass

ROOT = pathlib.Path(__file__).resolve().parents[1]
LITERAL = re.compile(r'"x_[A-Za-z0-9_%]')
COMMENT = re.compile(r"\(\*.*?\*\)", re.S)


def problems(name: str, text: str) -> list[str]:
    code = COMMENT.sub(lambda m: "\n" * m.group(0).count("\n"), text)
    return [f"{name}:{number}: an SMT name literal outside lib/smt_name.ml; "
            "add a constructor to Smt_name instead"
            for number, line in enumerate(code.splitlines(), 1)
            if LITERAL.search(line)]


def main() -> int:
    files = sorted(path for path in (ROOT / "lib").glob("*.ml")
                   if path.name != "smt_name.ml")
    errors = []
    for path in files:
        errors += problems(f"lib/{path.name}", path.read_text(encoding="utf-8"))
    planted = {
        "a sprintf name": 'let n id = Printf.sprintf "x_q%d" id\n',
        "a concatenated name": 'let n s = "x_g_" ^ s\n',
    }
    for label, text in planted.items():
        if not problems("planted.ml", text):
            errors.append(f"control: {label} was accepted")
    if problems("planted.ml", '(* "x_old" was the spelling *)\nlet x = 1\n'):
        errors.append("control: a literal inside a comment was refused")
    if errors:
        for error in errors:
            print(f"ERROR smt-name-literals: {error}")
        print("FAIL smt-name-literals: a z3 name is spelled outside Smt_name")
        return 1
    report_pass("smt-name-literals",
                "no lib/*.ml outside smt_name.ml spells a z3 constant name; "
                "planted literals are refused",
                files=len(files), controls=len(planted))
    return 0


if __name__ == "__main__":
    sys.exit(main())
