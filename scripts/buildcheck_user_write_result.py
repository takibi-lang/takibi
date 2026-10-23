#!/usr/bin/env python3
"""Compile real kernel overlays to enforce handling of user-memory stores.

GitHub issue #725: a validated write range does not allocate a copy-on-write
page's private copy, so every store into it can still fail. The stores answer
the must_use UserWriteResult; ignoring one, binding it and never matching, or
reading it as a bool must each be a compile error. These controls append to
the maintained kernel/mm/user_memory.tkb, so they exercise the production
signatures rather than a copied fixture.

Run after kernelbuild with the built compiler and the QEMU root source list.
Layout emission performs type checking without generating another kernel.
"""

from __future__ import annotations

import argparse
from pathlib import Path

from kernel_compile_flags import kernel_compile_flags
from overlay_jobs import run_overlay_cases
from pass_line import CaseCount, report_pass


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("compiler", type=Path)
    parser.add_argument("sources", nargs="+")
    args = parser.parse_args()
    repo = Path(__file__).resolve().parent.parent
    compiler = args.compiler.resolve()
    edited = Path("kernel/mm/user_memory.tkb")
    source = (repo / edited).read_text(encoding="ascii")
    cases = [
        ("handled store", """
private fn user_write_control(range: borrow UserWriteRange[process]) -> bool !{unsafe} {
    match user_write_join(user_zero_fill(range), user_write_u32(range, 0, 1)) {
        UserWriteResult::Fault => { return false; }
        UserWriteResult::Written => { return true; }
    }
}
""", None),
        ("ignored store", """
private fn user_write_control(range: borrow UserWriteRange[process]) !{unsafe} {
    user_zero_fill(range);
}
""", ("must-use result of 'user_zero_fill'",)),
        ("store bound and never matched", """
private fn user_write_control(range: borrow UserWriteRange[process], source: borrow []u8) !{unsafe} {
    let copied = copy_to_user_span(range, source, 0, 1);
}
""", ("must-use value 'copied' is never handled",)),
        ("store read as a bool", """
private fn user_write_control(range: borrow UserWriteRange[process], source: []u8) -> bool !{unsafe} {
    let sent: bool = copy_to_user(range, source);
    return sent;
}
""", ("cannot unify", "UserWriteResult", "bool")),
    ]
    def judge(case, result):
        name, _, expected = case
        output = result.stdout + result.stderr
        status_ok = result.returncode == 0 if expected is None else result.returncode != 0
        diagnostic_ok = expected is None or all(part in output for part in expected)
        if status_ok and diagnostic_ok:
            return None
        return f"FAIL user-write-result: {name}: status={result.returncode}; expected={expected}\n{output}"

    failures = run_overlay_cases(
        repo, "takibi-user-write-result-", cases,
        lambda case: (edited, source + case[1]),
        lambda overlay: [str(compiler), *args.sources, *kernel_compile_flags(),
                         "--emit-struct-layout", "UserWriteRange", "-o", str(overlay / "layout")],
        judge)
    ran = CaseCount()
    for failure in failures:
        ran.note()
        if failure is not None:
            print(failure)
    if any(failures):
        return 1
    report_pass("user-write-result", f"{ran.ran} real-kernel cases accept a matched store and reject an ignored, unmatched or bool-read user-memory store", cases=ran.ran)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
