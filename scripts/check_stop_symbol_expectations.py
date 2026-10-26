#!/usr/bin/env python3
"""A lane that asserts which function an invariant stop symbolizes to names a
function that still stops (GitHub issue #1079 follow-up).

#1079 moved the debugger switch's stop from kernel_syscall_child_exec_return
into kernel_syscall_child_exec_enter. scripts/invariant_stop_sites.tsv was
updated with it, but run_kernel_oops_qemutest.sh hard-coded the old name in
its symbolization assertion, and only the land's kernelcheck-oops-qemu found
it. This check ties the two together:

  * a lane script may not compare `["function"]` to a string literal; the
    expected names go in a dict whose opening line carries the marker
    comment `# invariant-stop-expectations`;
  * every quoted value in such a dict (up to its closing brace) must be a
    function with a row in scripts/invariant_stop_sites.tsv.

Rung: a build check (rung 3). The names are data in host scripts and the TSV
is checked against the compiled sources by check_invariant_stop_sites.py, so
no compiler or model sees both. In-script negative controls run first.
"""

import re
import sys
from pathlib import Path

from pass_line import report_pass

ROOT = Path(__file__).resolve().parent.parent
LIST = ROOT / "scripts" / "invariant_stop_sites.tsv"
MARKER = "# invariant-stop-expectations"
LITERAL = re.compile(r"""\[["']function["']\]\s*==\s*["']""")
VALUE = re.compile(r""":\s*["']([A-Za-z_][A-Za-z0-9_]*)["']""")


def stopping_functions(text):
    names = set()
    for line in text.splitlines():
        if not line.strip() or line.startswith("#"):
            continue
        parts = line.split("\t")
        if len(parts) >= 4:
            names.add(parts[1])
    return names


def problems_in(name, text, stops):
    problems = []
    expectations = 0
    lines = text.splitlines()
    for number, line in enumerate(lines, 1):
        if LITERAL.search(line):
            problems.append(f"{name}:{number}: compares a stop's function to a literal; "
                            f"name it in a dict marked `{MARKER}`")
        if MARKER in line:
            index = number - 1
            while index < len(lines):
                for found in VALUE.findall(lines[index]):
                    expectations += 1
                    if found not in stops:
                        problems.append(f"{name}:{index + 1}: expects a stop in {found}, "
                                        "which has no row in scripts/invariant_stop_sites.tsv")
                if "}" in lines[index]:
                    break
                index += 1
    return problems, expectations


def controls(stops):
    good = 'expected = {  # invariant-stop-expectations\n    "a": "%s"}\n' % sorted(stops)[0]
    cases = [
        ('assert report["symbol"]["function"] == "x", report\n', True),
        ('expected = {"a": "no_such_stop"}  # invariant-stop-expectations\n', True),
        (good, False),
    ]
    for text, refused in cases:
        found, _ = problems_in("control", text, stops)
        if bool(found) != refused:
            return f"control {'not refused' if refused else 'refused'}: {text!r}"
    return None


def main():
    stops = stopping_functions(LIST.read_text(encoding="utf-8"))
    failed = controls(stops)
    if failed:
        print(f"ERROR\tstop-symbol-expectations: {failed}")
        print("FAIL stop-symbol-expectations")
        return 1
    problems = []
    total = 0
    scanned = 0
    for path in sorted((ROOT / "scripts").iterdir()):
        # Controls plant synthetic symbols, not stops.
        if (path.suffix not in (".sh", ".py") or path.name == Path(__file__).name
                or path.name.endswith("_controls.py")):
            continue
        scanned += 1
        found, count = problems_in(path.relative_to(ROOT), path.read_text(encoding="utf-8"), stops)
        problems += found
        total += count
    for problem in problems:
        print(f"ERROR\tstop-symbol-expectations: {problem}")
    if problems:
        print("FAIL stop-symbol-expectations")
        return 1
    report_pass("stop-symbol-expectations",
                f"{total} expected stop function(s) in {scanned} scripts, each with a row "
                "in invariant_stop_sites.tsv; 3 controls",
                expectations=total, scripts=scanned)
    return 0


if __name__ == "__main__":
    sys.exit(main())
