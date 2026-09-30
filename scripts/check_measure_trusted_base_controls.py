#!/usr/bin/env python3
"""Lexical controls for the trusted-base unsafe-block inventory."""

import tempfile
from pathlib import Path

from measure_trusted_base import (
    lower_raw_deref_budget, raw_deref_problems, read_raw_deref_audit,
    read_raw_deref_budget, unsafe_blocks,
)

from pass_line import CaseCount, report_pass


# GitHub issue #526: a control asserts the number of scenarios it ran.
CASES = CaseCount()


def scan(source: str) -> list[tuple[int, str]]:
    CASES.note()
    with tempfile.TemporaryDirectory() as temporary:
        path = Path(temporary) / "control.tkb"
        path.write_text(source, encoding="ascii")
        return unsafe_blocks(path)


fake_only = scan(
    "// unsafe { fake as *io u32 }\n"
    "/* unsafe { fake as *u8 } and a spare } */\n"
    "let text = \"unsafe { fake as *u8 }\\\" still text\";\n"
    "let open_brace: u8 = '{';\n"
    "let close_brace: u8 = '}';\n"
)
if fake_only:
    raise SystemExit(f"comment/literal-only control reported {len(fake_only)} sites")

real = scan(
    "fn controls() {\n"
    "  let first = unsafe { 1 as *u8 };\n"
    "  let second = unsafe /* trivia between keyword and brace */\n"
    "  {\n"
    "    let text = \"escaped quote \\\" and closing brace }\";\n"
    "    /* neither } nor unsafe { changes the real depth */\n"
    "    if (true) { let byte: u8 = '}'; }\n"
    "    2 as *u8\n"
    "  };\n"
    "}\n"
)
if [line for line, _ in real] != [2, 3]:
    raise SystemExit(f"real unsafe controls have wrong start lines: {real!r}")
if "2 as *u8" not in real[1][1]:
    raise SystemExit("comment/literal brace ended a real unsafe block early")

try:
    scan("fn broken() { let pointer = unsafe { 1 as *u8;\n")
except SystemExit as error:
    if "unterminated unsafe block" not in str(error):
        raise SystemExit(f"unterminated control had wrong diagnostic: {error}")
else:
    raise SystemExit("unterminated real unsafe block unexpectedly passed")

# GitHub issue #639: the raw-pointer dereference ratchet. Each way it can be
# loosened is planted and must be refused for its own reason, and the way it
# is lowered must never raise a number.
def ratchet(audit, budget, compiled, existing=None):
    CASES.note()
    rows = {name: (plain, io, "control") for name, (plain, io) in budget.items()}
    return raw_deref_problems(
        audit, rows, compiled,
        lambda name: name in (existing if existing is not None else budget))


def refused(name, problems, needle):
    if not any(needle in problem for problem in problems):
        raise SystemExit(f"ratchet control '{name}' was not refused for "
                         f"{needle!r}: {problems!r}")


both = {"a.src", "b.src"}
if ratchet({"a.src": [3, 0], "b.src": [0, 5]},
           {"a.src": (3, 0), "b.src": (0, 5)}, both):
    raise SystemExit("ratchet control: an exact match was refused")
refused("a file with no row",
        ratchet({"a.src": [1, 0], "new.src": [2, 0]}, {"a.src": (1, 0)},
                both, existing={"a.src", "new.src"}),
        "new.src: 2 plain and 0 io raw-pointer dereference site(s) and no row")
refused("a file over its budget",
        ratchet({"a.src": [4, 0]}, {"a.src": (3, 0)}, {"a.src"}),
        "a.src: 4 plain dereference site(s), over its budget of 3")
refused("an io dereference over its budget",
        ratchet({"a.src": [3, 6]}, {"a.src": (3, 5)}, {"a.src"}),
        "6 io dereference site(s), over its budget of 5")
refused("a file under its budget",
        ratchet({"a.src": [2, 0]}, {"a.src": (3, 0)}, {"a.src"}),
        "a.src: 2 plain dereference site(s), under its budget of 3")
refused("a compiled file that stopped dereferencing",
        ratchet({}, {"a.src": (3, 0)}, {"a.src"}),
        "0 plain dereference site(s), under its budget of 3")
refused("a row for a file that is gone",
        ratchet({}, {"gone.src": (1, 0)}, set(), existing=set()),
        "gone.src: has a row and no longer exists")
refused("a row of zero",
        ratchet({}, {"a.src": (0, 0)}, set()),
        "a.src: a row of zero")
if ratchet({"a.src": [3, 0]}, {"a.src": (3, 0), "other.src": (9, 0)},
           {"a.src"}):
    raise SystemExit("ratchet control: a file this target does not compile "
                     "was held to the target's audit")

with tempfile.TemporaryDirectory() as temporary:
    audit_file = Path(temporary) / "audit.tsv"
    audit_file.write_text(
        "file\tline\tcolumn\tfunction\tform\tpointer\n"
        "a.src\t1\t1\tf\tfield\tplain\n"
        "a.src\t2\t1\tf\tstore-index\taligned\n"
        "a.src\t3\t1\tf\tderef\tio\n", encoding="ascii")
    CASES.note()
    if read_raw_deref_audit(audit_file) != {"a.src": [2, 1]}:
        raise SystemExit("ratchet control: the audit was not read as "
                         "plain and aligned together, io apart")
    budget_file = Path(temporary) / "budget.tsv"
    budget_file.write_text(
        "# a comment\n"
        "a.src\t5\t2\ta reason\n"
        "b.src\t1\t0\ta second reason\n"
        "c.src\t4\t0\tnot compiled here\n", encoding="ascii")
    CASES.note()
    lowered = lower_raw_deref_budget(
        budget_file, {"a.src": [2, 1], "b.src": [9, 0]}, {"a.src", "b.src"})
    rows = read_raw_deref_budget(budget_file)
    if rows["a.src"][:2] != (2, 1):
        raise SystemExit(f"ratchet control: --lower left {rows['a.src']}")
    if rows["b.src"][:2] != (1, 0):
        raise SystemExit("ratchet control: --lower RAISED a budget")
    if rows["c.src"][:2] != (4, 0):
        raise SystemExit("ratchet control: --lower touched a file the "
                         "build did not compile")
    if len(lowered) != 1 or "a.src" not in lowered[0]:
        raise SystemExit(f"ratchet control: --lower reported {lowered!r}")
    if "# a comment" not in budget_file.read_text():
        raise SystemExit("ratchet control: --lower dropped a comment")
    CASES.note()
    lower_raw_deref_budget(budget_file, {}, {"b.src"})
    if "b.src" in read_raw_deref_budget(budget_file):
        raise SystemExit("ratchet control: --lower kept a row of zero")

report_pass(
    "trusted-base lexical controls",
    "verified; the raw-deref ratchet refuses a file with no row, over, under, "
    "gone or zero, is not held to another target's files, and --lower "
    "lowers, never raises and drops a zero row",
    cases=CASES.ran)
