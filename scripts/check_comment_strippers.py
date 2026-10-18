#!/usr/bin/env python3
"""Comment rules live in scripts/source_scan.py, not in each check.

GitHub issue #818 (after #815). A check that claims a code property must not
pass on a comment naming the code, and every hand-rolled comment stripper
in scripts/ had its own gap: `line.split("//")` misses block comments and
cuts a string holding `//`, a `//[^\\n]*` regex does the same, and a
character loop forgets the literal `'"'`. source_scan's code_only,
code_skeleton, compact, py_code_only and sh_code_only are the one lexer each.

This refuses, in every scripts/*.py but source_scan.py, a new comment
stripper of the shapes that existed: a literal "//" or "/*" passed to
split/rsplit/partition/find/index/startswith, or a regex literal holding
`//[^\\n]*`, `//.*` or an escaped `/\\*`. A file that strips the comments of
something that is not Takibi, C or shell source -- disassembly, litmus
assembly -- or that reads comments on purpose is listed in ALLOWED with why.

RAW_TEXT records the checks #818 reviewed as matching raw text by intent
(a required reason comment, a header comment, log strings, docs, a recipe):
they are not strippers, and listing them keeps the review where the next
survey finds it. An entry whose file is gone is stale.

Lexical: it reads string literals outside Python comments
(source_scan.py_code_only), so a stripper built from computed strings is
not seen; that stays review. Controls: scripts/check_comment_strippers_controls.py.
"""

import pathlib
import re
import sys

from pass_line import report_pass
from source_scan import per_file, py_code_only

ROOT = pathlib.Path(__file__).resolve().parent.parent
SCRIPTS = ROOT / "scripts"
# The lexer itself, and this check and its controls, which spell the shapes.
HOME = {"source_scan.py", "check_comment_strippers.py",
        "check_comment_strippers_controls.py"}

SHAPES = (
    re.compile(r"""\.(?:r?split|partition|find|r?index|startswith)\(\s*\(?\s*r?(['"])(?://|/\*)\1"""),
    re.compile(r"//\[\^\\n\]\*"),
    re.compile(r"//\.\*"),
    re.compile(r"/\\{1,2}\*"),
)

ALLOWED = {
    "buildcheck_kernel_asm_invariants.py":
        "strips objdump's `//` annotations from disassembled instructions, not source",
    "run_litmus_checks.py":
        "strips `//` from herd litmus assembly operands, not Takibi source",
    "find_stale_issue_workarounds.py":
        "finds comments on purpose: a workaround is named by an issue in a comment",
}

RAW_TEXT = {
    "check_probe_tick_windows.py": "`Deliberate` is a required reason comment",
    "check_kernel_lib_limitations_header.py": "the header comment is the property",
    "check_kernel_log_expectations.py": "matches log strings",
    "check_documented_counts.py": "reads documentation",
    "check_agents_paths.py": "reads AGENTS.md",
    "check_el0_raw_deref_audit.py": "reads Makefile recipe text",
}


@per_file
def hits(text: str) -> tuple:
    """Line numbers of stripper shapes in one script, outside its comments."""
    try:
        code = py_code_only(text)
    except (SyntaxError, ValueError):
        code = text
    found = set()
    for shape in SHAPES:
        for match in shape.finditer(code):
            found.add(code.count("\n", 0, match.start()) + 1)
    return tuple(sorted(found))


def problems(modules: dict, allowed: dict = ALLOWED, raw_text: dict = RAW_TEXT) -> list:
    """`modules` maps a scripts/ file name to its text."""
    found = []
    for name, text in sorted(modules.items()):
        if name in HOME:
            continue
        lines = hits(text)
        if lines and name not in allowed:
            for line in lines:
                found.append(f"scripts/{name}:{line}: hand-rolled comment stripper; use "
                             f"source_scan.code_only (or code_skeleton, compact, "
                             f"py_code_only, sh_code_only), or list the file in "
                             f"ALLOWED with why its text is not source")
        elif not lines and name in allowed:
            found.append(f"ALLOWED lists {name}, which strips no comments: stale")
    for name in sorted(set(allowed) - modules.keys()):
        found.append(f"ALLOWED lists {name}, which does not exist: stale")
    for name in sorted(set(raw_text) - modules.keys()):
        found.append(f"RAW_TEXT lists {name}, which does not exist: stale")
    return found


def tracked_modules() -> dict:
    return {path.name: path.read_text(encoding="utf-8")
            for path in sorted(SCRIPTS.glob("*.py"))}


def main() -> int:
    modules = tracked_modules()
    found = problems(modules)
    for problem in found:
        print(f"ERROR\tcomment-strippers: {problem}")
    if found:
        print(f"FAIL comment-strippers: {len(found)} problem(s)")
        return 1
    report_pass("comment-strippers",
                f"no hand-rolled comment stripper in {len(modules)} scripts outside "
                f"source_scan; {len(ALLOWED)} non-source strippers and "
                f"{len(RAW_TEXT)} raw-text checks reviewed",
                scripts=len(modules))
    return 0


if __name__ == "__main__":
    sys.exit(main())
