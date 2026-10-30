#!/usr/bin/env python3
"""No slot or generation value reaches user space (GitHub issue #1228).

docs/HANDLE_BOUNDARY_AUDIT_2026-10-29.md (#1224) found that no pool slot
index or generation is written to user memory or returned in a register,
but by inspection only. This check keeps it that way, lexically.

A SINK is a call that hands a value to user space:
  user_write_byte/_u16/_u32/_u64, copy_to_user, copy_to_user_span
  (kernel/mm/user_memory.tkb), SyscallAction::Resume(...) and
  el0_context_set_x0(...).
Each sink's argument text (to its matching parenthesis, comments and
strings stripped by source_scan) must not name a HANDLE-SHAPED word: an
identifier containing `generation`, or a slot or handle identifier
(`slot`, `_slot`, `slot_`, `handle`), outside the reviewed exceptions in
ALLOWED. The rung is 3 because the language has no opaque Generation
type yet (rung 1 is the follow-up the issue names); this sees names, not
data flow, so a value renamed into a neutral local before the sink is
missed -- the audit's trace stays the evidence for those.

A built-in control proves a generation passed to user_write_u64 and a
slot returned through Resume are refused.
"""

import pathlib
import re
import sys

from pass_line import report_pass
from source_scan import code_only

ROOT = pathlib.Path(__file__).resolve().parent.parent
KERNEL = ROOT / "kernel"

SINKS = re.compile(
    r"\b(user_write_(?:byte|u16|u32|u64)|copy_to_user(?:_span)?|"
    r"SyscallAction::Resume|el0_context_set_x0)\s*\(")
HANDLE_WORD = re.compile(
    r"\b[A-Za-z_][A-Za-z0-9_]*\b")


def handle_shaped(word: str) -> bool:
    w = word.lower()
    if "generation" in w:
        return True
    parts = w.split("_")
    return "slot" in parts or "handle" in parts or "slots" in parts


# (file, identifier) -> why it is not a handle. Each is a claim a reviewer
# can disagree with.
ALLOWED = {
}

# The sink definitions themselves, where the words are parameters.
SKIP_FILES = {"mm/user_memory.tkb"}


def arguments(code: str, start: int) -> str:
    depth = 0
    i = start
    while i < len(code):
        c = code[i]
        if c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
            if depth == 0:
                return code[start + 1:i]
        i += 1
    return code[start + 1:]


# A word used only to SELECT what is written is not what is written: an
# array index (`syscall_scratch[slot.index].file_buffer`) and the arguments
# of a call whose result is projected to a field
# (`record_locked(guard, process_slot_of(i)).deadline_result`). Those are
# blanked before the scan; the selected field is still checked.
SELECTOR_INDEX = re.compile(r"\[[^\[\]]*\]")


def written_part(args: str) -> str:
    previous = None
    while previous != args:
        previous = args
        args = SELECTOR_INDEX.sub("[]", args)
    # Blank every parenthesized group whose result is projected (`(...).f`),
    # nested groups included.
    out = list(args)
    stack = []
    for i, c in enumerate(args):
        if c == "(":
            stack.append(i)
        elif c == ")" and stack:
            start = stack.pop()
            rest = args[i + 1:].lstrip()
            if rest.startswith("."):
                for k in range(start + 1, i):
                    out[k] = " "
    return "".join(out)


def violations(files: dict[str, str]) -> list[str]:
    found = []
    for path, text in sorted(files.items()):
        if path in SKIP_FILES:
            continue
        code = code_only(text)
        for m in SINKS.finditer(code):
            args = written_part(arguments(code, m.end() - 1))
            for w in HANDLE_WORD.finditer(args):
                word = w.group(0)
                if handle_shaped(word) and (path, word) not in ALLOWED:
                    line = code.count("\n", 0, m.start()) + 1
                    found.append(f"kernel/{path}:{line}: `{word}` reaches "
                                 f"{m.group(1)}; a slot or generation must "
                                 "not reach user space (#1224)")
    return found


def main() -> int:
    files = {p.relative_to(KERNEL).as_posix(): p.read_text()
             for p in KERNEL.rglob("*.tkb")}
    for (path, _word) in ALLOWED:
        if path not in files:
            print(f"FAIL handle-boundary: allowed file kernel/{path} is gone",
                  file=sys.stderr)
            return 1
    found = violations(files)
    if found:
        print("FAIL handle-boundary:\n  " + "\n  ".join(found), file=sys.stderr)
        return 1
    control = {"kernel/x.tkb":
               "// user_write_u64(p, generation) in a comment\n"
               "let r = user_write_u64(dst, owner_generation(o));\n"
               "return SyscallAction::Resume(proc_slot as u64);\n"
               "return SyscallAction::Resume(count as u64);\n"
               "copy_to_user_span(r, scratch[slot.index].buf as []u8);\n"
               "el0_context_set_x0(f, rec(g, proc_slot_of(i)).result);\n"}
    if len(violations(control)) != 2:
        print("FAIL handle-boundary: control was not refused exactly twice",
              file=sys.stderr)
        return 1
    report_pass("handle-boundary",
                "no slot or generation word reaches a user write or a "
                "syscall return; a planted one is refused",
                files=len(files))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
