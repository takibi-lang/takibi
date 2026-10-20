#!/usr/bin/env python3
"""A gdb Python check bounds its continues by guest progress, not host seconds.

GitHub issues #864 and #865: a gdb stage gave the guest one fixed number of
host seconds to reach its breakpoint. The step is deterministic in guest
progress, but its host time depends on how much CPU QEMU gets; under host
load (loadavg 24) the uart-wake peer net stage ran out before CPU1 took the
three ticks its waiter is due after, and the same timeout decided the
negative verdicts ("asleep", "the control left it asleep"), so a starved
guest could read as a defect or as a passing control.

scripts/gdb_progress.py resumes in host-time slices and counts the ticks the
running vCPUs take (or a spin loop's passes), so a verdict tells "it did not
happen in N ticks" from "the guest was not given the time". So in every
scripts/*.py that imports gdb, the only places allowed to start a resume
under a host-time interrupt -- a call to interrupt_after(), or gdb.execute()
of a literal continue/finish/until/advance/step/next -- are the slice
primitives in SLICE_PRIMITIVES, which callers drive by progress. Any other
site says why it may stay in a comment containing
`gdb-wallclock-waiver: <reason>` within WAIVER_WINDOW lines above it.

Exit code only (0 = pass, 1 = fail).
"""

import ast
import pathlib
import re
import sys

from pass_line import report_pass

SCRIPTS = pathlib.Path("scripts")
WAIVER = "gdb-wallclock-waiver:"
WAIVER_WINDOW = 4
# (file, function): one resume each; their callers bound them by progress.
SLICE_PRIMITIVES = {
    ("gdb_progress.py", "resume_slice"),
    ("kernel_gdb_stage.py", "_continue_until_breakpoint"),
}
RESUME = re.compile(r"^\s*(continue|c|finish|fin|until|u|advance|step|s|"
                    r"stepi|si|next|n|nexti|ni)\b")
IMPORTS_GDB = re.compile(r"^import gdb\b", re.M)


def literal_prefix(node: ast.AST):
    if isinstance(node, ast.Constant) and isinstance(node.value, str):
        return node.value
    if isinstance(node, ast.JoinedStr) and node.values:
        first = node.values[0]
        if isinstance(first, ast.Constant) and isinstance(first.value, str):
            return first.value
    return None


def resumes(call: ast.Call) -> bool:
    function = call.func
    if isinstance(function, ast.Name) and function.id == "interrupt_after":
        return True
    if (isinstance(function, ast.Attribute) and function.attr == "interrupt_after"):
        return True
    if (isinstance(function, ast.Attribute) and function.attr == "execute"
            and isinstance(function.value, ast.Name)
            and function.value.id == "gdb" and call.args):
        text = literal_prefix(call.args[0])
        return text is not None and bool(RESUME.match(text))
    return False


def sites(tree: ast.AST):
    """(line, enclosing function name or None) of every resume call."""
    found = []

    def walk(node, function):
        for child in ast.iter_child_nodes(node):
            name = function
            if isinstance(child, (ast.FunctionDef, ast.AsyncFunctionDef)):
                name = child.name
            if isinstance(child, ast.Call) and resumes(child):
                found.append((child.lineno, name))
            walk(child, name)

    walk(tree, None)
    return found


def waived(lines, line: int) -> bool:
    before = lines[max(0, line - 1 - WAIVER_WINDOW):line - 1]
    notes = [row for row in before if row.lstrip().startswith("#") and WAIVER in row]
    return bool(notes) and bool(notes[-1].split(WAIVER, 1)[1].strip())


def main() -> int:
    scanned = 0
    primitive_sites = 0
    waived_sites = 0
    failures = []
    for path in sorted(SCRIPTS.glob("*.py")):
        if path.name.startswith("check_"):
            continue
        text = path.read_text(encoding="utf-8")
        if not IMPORTS_GDB.search(text):
            continue
        scanned += 1
        lines = text.splitlines()
        for line, function in sites(ast.parse(text, str(path))):
            if (path.name, function) in SLICE_PRIMITIVES:
                primitive_sites += 1
            elif waived(lines, line):
                waived_sites += 1
            else:
                failures.append(f"{path}:{line}")
    if failures:
        for where in failures:
            print(f"ERROR\tgdb-wallclock-continue: {where} resumes the guest "
                  "under a host-time bound; under host load that bound ends "
                  "a step the guest had no time for (#864, #865). Drive it "
                  "with scripts/gdb_progress.py continue_by_ticks(), or say "
                  f"why not in a `# {WAIVER} <reason>` comment above it")
        print(f"FAIL gdb-wallclock-continue: {len(failures)} site(s)")
        return 1
    report_pass("gdb-wallclock-continue",
                f"{primitive_sites} slice primitive site(s), {waived_sites} "
                "waived; every other gdb resume is progress-bounded",
                files=scanned)
    return 0


if __name__ == "__main__":
    sys.exit(main())
