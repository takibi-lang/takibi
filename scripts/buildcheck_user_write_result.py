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
import subprocess
import tempfile

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
    ran = CaseCount()
    with tempfile.TemporaryDirectory(prefix="takibi-user-write-result-") as tmp:
        overlay = Path(tmp)
        # Symlink files individually so changing one source cannot touch the
        # real tree. Generated kernel files remain available after kernelbuild.
        for original in (repo / "kernel").rglob("*"):
            relative = original.relative_to(repo)
            target = overlay / relative
            if original.is_dir():
                target.mkdir(parents=True, exist_ok=True)
            elif original.is_file():
                target.parent.mkdir(parents=True, exist_ok=True)
                target.symlink_to(original)
        target = overlay / edited
        for name, addition, expected in cases:
            target.unlink()
            target.write_text(source + addition, encoding="ascii")
            result = subprocess.run(
                [str(compiler), *args.sources, "--regions", "--forbid-trap",
                 "--target", "aarch64-none-elf", "--cpu", "cortex-a53",
                 "--emit-struct-layout", "UserWriteRange", "-o", str(overlay / "layout")],
                cwd=overlay, capture_output=True, text=True, check=False)
            ran.note()
            output = result.stdout + result.stderr
            status_ok = result.returncode == 0 if expected is None else result.returncode != 0
            diagnostic_ok = expected is None or all(part in output for part in expected)
            if not status_ok or not diagnostic_ok:
                print(f"FAIL user-write-result: {name}: status={result.returncode}; expected={expected}\n{output}")
                return 1
        target.unlink()
        target.symlink_to(repo / edited)
    report_pass("user-write-result", f"{ran.ran} real-kernel cases accept a matched store and reject an ignored, unmatched or bool-read user-memory store", cases=ran.ran)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
