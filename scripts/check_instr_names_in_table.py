#!/usr/bin/env python3
"""No instruction builtin is named by a string literal outside its table.

GitHub issue #1213. Since #1005 every instruction builtin (`mrs_*`, `msr_*`,
`tlbi_*`, `dsb_*`, `isb`, `wfi`, `smc4`, `hvc4`, `svc5`) is one row of
lib/instr_spec.ml, and the type rule, the emitter, the IRQ flow rule and the
raw-authority sites read the row (shape, role, raw_site). A new reader that
matched `"msr_daifset_irq"` again would bring back the per-name registration
the table replaced, and the two could disagree.

This reads the row names from lib/instr_spec.ml and refuses a string literal
of any of them in lib/*.ml or bin/*.ml other than instr_spec.ml itself. A
quoted name inside an OCaml comment is refused too: a comment can say the
name without quotes.

Usage: check_instr_names_in_table.py [repo_root]
"""

import pathlib
import re
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

from pass_line import report_pass  # noqa: E402

ROW = re.compile(r'(?:\b(?:read|bare|write1)\s+|\bname = )"([a-z0-9_]+)"')


def table_names(text):
    return sorted(set(ROW.findall(text)))


def problems_in(name, text, names):
    found = []
    for number, line in enumerate(text.splitlines(), 1):
        for builtin in names:
            if f'"{builtin}"' in line:
                found.append(f"{name}:{number}: names the instruction builtin "
                             f"{builtin!r} as a literal; read it from "
                             "lib/instr_spec.ml (a row, its role or raw_site) "
                             "instead (#1005, #1213)")
    return found


def controls(names):
    cases = [
        ('  | Call ("msr_daifset_irq", []) -> ()', True),
        ('  if name = "svc5" then x', True),
        ("  (* msr_daifset_irq is the IRQ mask *)", False),
        ('  let s = "msr_daifset_irq_extra"', False),
    ]
    failed = [text for text, refused in cases
              if bool(problems_in("control", text, names)) != refused]
    return failed, len(cases)


def main(argv):
    root = pathlib.Path(argv[1]) if len(argv) > 1 else pathlib.Path(__file__).resolve().parent.parent
    table = root / "lib" / "instr_spec.ml"
    names = table_names(table.read_text(encoding="utf-8"))
    if "msr_daifset_irq" not in names or "svc5" not in names:
        print(f"FAIL instr-names-in-table: could not read the rows of {table} "
              f"(found {names!r})")
        return 1
    failed, ran = controls(names)
    if failed:
        for text in failed:
            print(f"FAIL instr-names-in-table control: {text!r}")
        return 1
    files = sorted(p for d in ("lib", "bin") for p in (root / d).glob("*.ml")
                   if p != table)
    problems = []
    for path in files:
        problems += problems_in(path.relative_to(root), path.read_text(encoding="utf-8"), names)
    if problems:
        for problem in problems:
            print(f"ERROR instr-names-in-table: {problem}")
        print("FAIL instr-names-in-table")
        return 1
    report_pass("instr-names-in-table",
                f"{len(names)} instruction builtins named only in lib/instr_spec.ml "
                f"across {len(files)} compiler files; {ran} controls as specified",
                builtins=len(names), files=len(files), controls=ran)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
