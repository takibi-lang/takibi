#!/usr/bin/env python3
"""Every syscall number an in-tree guest program issues is dispatched.

GitHub issue #792 (follow-up of #665). /bin/protocol-trace issued sched_yield
(124) only on a load-dependent path, and the kernel had no arm for 124: the
call fell through to ENOSYS and the unimplemented_syscalls view saw it only
when that path ran, which surfaced as an intermittent DDB stall.

The rule: every syscall number an in-tree EL0 program can issue has an arm in
`kernel_syscall_dispatch_action` (kernel/kernel/syscall.tkb), or is listed in
EXPECTED_ENOSYS below with the reason the guest wants ENOSYS. A listed number
that no guest issues, or that the kernel now dispatches, is stale and refused.

Guest forms collected (lexical, comments stripped):
- `.tkb`: the first argument of every `svcN(...)` call, a decimal or hex
  literal or a `const NAME: usize = N;` of the same file, plus every
  `const *_SYSCALL: usize = N;` whether or not it is used. A first argument
  that is neither is refused, so a new form cannot slip past.
- `.S` and `.c` under kernel/: `mov x8, #N` immediately before `svc #0`, and
  in a C file that contains `svc #0`, `call(N, ...)` of its raw-ABI wrapper.
Kernel side: `number == N` and `number == NAME` inside the dispatch function,
NAME resolved against syscall.tkb's own constants.

Controls: scripts/check_guest_syscalls_dispatched_controls.py.
"""

import pathlib
import re
import sys

from check_lock_rank_wrappers import functions
from pass_line import report_pass

ROOT = pathlib.Path(__file__).resolve().parent.parent
KERNEL = ROOT / "kernel"
SYSCALL_TKB = "kernel/kernel/syscall.tkb"
DISPATCH_FN = "kernel_syscall_dispatch_action"

# syscall number -> why a guest issues it and expects ENOSYS. Reviewed only.
EXPECTED_ENOSYS: dict = {}

NUM = r"(0x[0-9A-Fa-f_]+|[0-9][0-9_]*)"
CONST_RE = re.compile(r"\bconst\s+([A-Z_][A-Z_0-9]*)\s*:\s*u(?:size|64)\s*=\s*" + NUM + r"\s*;")
SVC_RE = re.compile(r"\bsvc[0-9]+\(\s*([^,()]+?)\s*,")
ASM_RE = re.compile(r"mov\s+x8\s*,\s*#?" + NUM + r"\s*(?:\\n\s*)?(?:\n\s*)?svc\s+#0")
C_CALL_RE = re.compile(r"\bcall\(\s*" + NUM + r"\s*,")
DISPATCH_RE = re.compile(r"\bnumber\s*==\s*([A-Za-z_0-9]+)\b")


def to_int(text: str) -> int:
    return int(text.replace("_", ""), 0)


def strip_tkb_comments(text: str) -> str:
    return re.sub(r"//[^\n]*", "", text)


def strip_c_comments(text: str) -> str:
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    return re.sub(r"//[^\n]*", "", text)


def kernel_sources() -> dict:
    out = {}
    for path in sorted(KERNEL.rglob("*")):
        if path.suffix in (".tkb", ".S", ".c") and path.is_file():
            out[str(path.relative_to(ROOT))] = path.read_text(encoding="utf-8")
    return out


def consts(text: str) -> dict:
    return {m.group(1): to_int(m.group(2)) for m in CONST_RE.finditer(text)}


def guest_numbers(sources: dict):
    """(number -> [where], problems) over every guest-issuing source."""
    issued: dict = {}
    problems = []

    def note(number: int, where: str) -> None:
        issued.setdefault(number, []).append(where)

    for path, raw in sources.items():
        if path == SYSCALL_TKB:
            continue
        if path.endswith(".tkb"):
            text = strip_tkb_comments(raw)
            table = consts(text)
            for name, value in table.items():
                if name.endswith("_SYSCALL"):
                    note(value, f"{path}:{name}")
            for m in SVC_RE.finditer(text):
                arg = m.group(1)
                if re.fullmatch(NUM, arg):
                    note(to_int(arg), f"{path}:svc({arg})")
                elif arg in table:
                    note(table[arg], f"{path}:svc({arg})")
                else:
                    line = text.count("\n", 0, m.start()) + 1
                    problems.append(f"{path}:{line}: svc number `{arg}` is not a literal "
                                    "or a const of this file; the check cannot read it")
        else:
            text = strip_c_comments(raw)
            if not re.search(r"svc\s+#0", text):
                continue
            for m in ASM_RE.finditer(text):
                note(to_int(m.group(1)), f"{path}:mov x8,#{m.group(1)}")
            if path.endswith(".c"):
                for m in C_CALL_RE.finditer(text):
                    note(to_int(m.group(1)), f"{path}:call({m.group(1)})")
    return issued, problems


def dispatch_body(text: str) -> str:
    """The dispatch function's body, found as check_lock_rank_wrappers finds
    one: an effect row's or refinement's `{` is not the body."""
    for name, _header, body in functions(text):
        if name == DISPATCH_FN:
            return body
    return ""


def dispatched_numbers(sources: dict):
    text = strip_tkb_comments(sources[SYSCALL_TKB])
    table = consts(text)
    body = dispatch_body(text)
    numbers = set()
    problems = []
    if not body:
        return numbers, [f"{SYSCALL_TKB}: no `fn {DISPATCH_FN}` body found"]
    for m in DISPATCH_RE.finditer(body):
        arg = m.group(1)
        if re.fullmatch(NUM, arg):
            numbers.add(to_int(arg))
        elif arg in table:
            numbers.add(table[arg])
        else:
            problems.append(f"{SYSCALL_TKB}: dispatch compares number with `{arg}`, "
                            "not a literal or a const of the file")
    return numbers, problems


def problems(sources: dict, expected: dict = None):
    expected = EXPECTED_ENOSYS if expected is None else expected
    issued, found = guest_numbers(sources)
    dispatched, more = dispatched_numbers(sources)
    found += more
    for number in sorted(issued):
        if number not in dispatched and number not in expected:
            sites = sorted(set(issued[number]))
            found.append(f"syscall {number} is issued by {', '.join(sites)} "
                         f"but {SYSCALL_TKB} has no `number == {number}` arm in "
                         f"{DISPATCH_FN} (implement it, or list it in EXPECTED_ENOSYS "
                         "with the reason)")
    for number in sorted(expected):
        if number in dispatched:
            found.append(f"EXPECTED_ENOSYS lists {number}, but the kernel dispatches it: stale")
        elif number not in issued:
            found.append(f"EXPECTED_ENOSYS lists {number}, but no guest issues it: stale")
    return found


def main() -> int:
    sources = kernel_sources()
    found = problems(sources)
    if found:
        for line in found:
            print(f"guest-syscalls-dispatched: {line}", file=sys.stderr)
        return 1
    issued, _ = guest_numbers(sources)
    dispatched, _ = dispatched_numbers(sources)
    files = {where.split(":")[0] for sites in issued.values() for where in sites}
    report_pass("guest-syscalls-dispatched",
                f"{len(issued)} guest syscall numbers from {len(files)} files, "
                f"all among {len(dispatched)} dispatched",
                numbers=len(issued), files=len(files), dispatched=len(dispatched))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
