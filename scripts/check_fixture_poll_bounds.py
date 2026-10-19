#!/usr/bin/env python3
"""GitHub issue #844: EL0 fixture loops that poll WORKLOAD_PROGRESS are bounded.

#841 and #843 stalled the boot into DDB with no line naming the fixture: a
user-side loop asked the kernel for a verdict or a turn with no bound, and
the report it waited on had been refused or lost. Every `while` loop in the
EL0 fixtures (kernel/arch/arm64/kernel/*.tkb) whose condition or body makes
the WORKLOAD_PROGRESS syscall must either

  - count: a local `n = n + 1` in the body compared with an UPPER_CASE
    bound (`n < LIMIT` or `n >= LIMIT`), so a lost report ends the loop and
    the code after it can name the failure; or
  - carry `// poll-bound: <reason>` in the comment block just above the `while`,
    saying what ends it instead (a kernel answer that is guaranteed, or a
    persistent worker that is meant never to stop).

`for` loops over a range are bounded by construction and are not looked at.
Comments and string literals are masked before matching. There are no
WORKLOAD_PROGRESS callers under linux_user/.
"""

from pathlib import Path
import re
import sys

from pass_line import report_pass

ROOT = Path(__file__).resolve().parent.parent
FIXTURES = "kernel/arch/arm64/kernel"
SYSCALL = "WORKLOAD_PROGRESS_SYSCALL"
ANNOTATION = re.compile(r"//\s*poll-bound:\s*\S")


def mask(source: str) -> str:
    """Blank comments and string literals, keeping offsets and newlines."""
    out = []
    i = 0
    n = len(source)
    while i < n:
        if source.startswith("//", i):
            j = source.find("\n", i)
            j = n if j < 0 else j
            out.append(" " * (j - i))
            i = j
        elif source.startswith("/*", i):
            j = source.find("*/", i + 2)
            j = n if j < 0 else j + 2
            out.append(re.sub(r"[^\n]", " ", source[i:j]))
            i = j
        elif source[i] == '"':
            j = i + 1
            while j < n and source[j] != '"':
                j += 2 if source[j] == "\\" else 1
            j = min(j + 1, n)
            out.append('"' + " " * (j - i - 2) + '"' if j - i >= 2 else source[i:j])
            i = j
        else:
            out.append(source[i])
            i += 1
    return "".join(out)


def loops(masked: str):
    """Yield (offset, condition, body) for every while loop."""
    for match in re.finditer(r"\bwhile\s*\(", masked):
        depth, i = 1, match.end()
        while i < len(masked) and depth:
            depth += {"(": 1, ")": -1}.get(masked[i], 0)
            i += 1
        condition = masked[match.end():i - 1]
        brace = masked.find("{", i)
        if brace < 0:
            continue
        depth, j = 1, brace + 1
        while j < len(masked) and depth:
            depth += {"{": 1, "}": -1}.get(masked[j], 0)
            j += 1
        yield match.start(), condition, masked[brace + 1:j - 1]


def counted(condition: str, body: str) -> bool:
    text = condition + "\n" + body
    for name in re.findall(r"\b([a-z_][a-z0-9_]*)\s*=\s*\1\s*\+\s*1\b", body):
        if re.search(rf"\b{name}\s*(<|>=)\s*[A-Z][A-Z0-9_]+\b", text):
            return True
    return False


def problems(files: dict[str, str]) -> tuple[list[str], int]:
    found, examined = [], 0
    for path, source in sorted(files.items()):
        masked = mask(source)
        lines = source.splitlines()
        for offset, condition, body in loops(masked):
            if SYSCALL not in condition and SYSCALL not in body:
                continue
            examined += 1
            line = masked.count("\n", 0, offset) + 1
            k, block = line - 2, []
            while k >= 0 and lines[k].strip().startswith("//"):
                block.append(lines[k])
                k -= 1
            if counted(condition, body) or any(ANNOTATION.search(c) for c in block):
                continue
            found.append(f"{path}:{line}: a loop polls {SYSCALL} with no count bound and no "
                         "`// poll-bound:` reason above it (GitHub issue #844)")
    return found, examined


def sources() -> dict[str, str]:
    return {str(p.relative_to(ROOT)): p.read_text(encoding="utf-8")
            for p in sorted((ROOT / FIXTURES).glob("*.tkb"))}


def main() -> int:
    tree = sources()
    found, examined = problems(tree)
    if found:
        for item in found:
            print(f"FAIL fixture-poll-bounds: {item}")
        return 1
    # Controls: an unbounded verdict poll is refused, also when its only
    # "bound" is a comparison with the kernel's answer or sits in a comment;
    # a counted poll and an annotated one pass.
    poll = "svc5(WORKLOAD_PROGRESS_SYSCALL, 7, 4, 0, 0, 0)"
    controls = {
        "unbounded": (f"fn f() {{ let mut v: usize = 0;\n    while (v == 0) {{ v = {poll}; }}\n}}\n", 1),
        "answer compare": (f"fn f() {{\n    while ({poll} < 4) {{ nap(); }}\n}}\n", 1),
        "counter in comment": (f"fn f() {{\n    while ({poll} == 0) {{ // polls = polls + 1; polls < LIMIT\n    }}\n}}\n", 1),
        "reason in a string": (f"fn f() {{\n    let s = \"// poll-bound: no\";\n    while ({poll} == 0) {{ }}\n}}\n", 1),
        "counted": (f"fn f() {{ let mut polls: usize = 0;\n    while (polls < LIMIT && {poll} == 0) {{ polls = polls + 1; }}\n}}\n", 0),
        "counted in body": (f"fn f() {{ let mut polls: usize = 0;\n    while ({poll} == 0) {{\n        polls = polls + 1;\n        if (polls >= LIMIT) {{ fail(); }}\n    }}\n}}\n", 0),
        "annotated": (f"fn f() {{\n    // poll-bound: the kernel answers 2 within one call\n    while ({poll} != 2) {{ }}\n}}\n", 0),
    }
    for name, (text, wanted) in controls.items():
        got, _ = problems({"control.tkb": text})
        if len(got) != wanted:
            print(f"FAIL fixture-poll-bounds: control {name!r} gave {len(got)} findings, wanted {wanted}")
            return 1
    report_pass("fixture-poll-bounds",
                f"{examined} WORKLOAD_PROGRESS poll loops in {len(tree)} EL0 fixtures are counted "
                f"or carry a poll-bound reason; {len(controls)} controls",
                loops=examined)
    return 0


if __name__ == "__main__":
    sys.exit(main())
