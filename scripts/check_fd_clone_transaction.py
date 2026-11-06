#!/usr/bin/env python3
"""Keep the fd-clone transaction's runtime prefix equal to installed fds.

The linear type checker proves that callers consume the transaction through
rollback or commit. It cannot prove the arithmetic inside the small trusted
implementation boundary: success must advance through the installed fd,
failure must preserve the previous prefix, and rollback must use that prefix.
This check pins those concrete relationships from issue #297.

GitHub issue #1350 slice 4: the rollback no longer closes below the prefix
inside the clone window. unified_fd_clone_detach takes the child's whole
descriptor-block chain into the undo and clears it from the child, and the
caller releases the chain after its PreemptOff span. The whole chain is the
installed prefix only because the clone refuses a child that already has an
open descriptor before it begins, so that refusal is pinned too.
"""

from pathlib import Path
import sys

from pass_line import report_pass
from source_scan import code_only


SOURCE = Path("kernel/kernel/fd_table.tkb")


def compact(text: str) -> str:
    return " ".join(text.split())


def function(text: str, name: str) -> str:
    for prefix in (f"private fn {name}(", f"fn {name}("):
        start = text.find(prefix)
        if start >= 0:
            break
    else:
        return ""
    # Effect rows contain braces in the signature (`!{unsafe}`), so the body
    # opener is specifically the brace followed by the source newline.
    brace = text.find("{\n", start)
    if brace < 0:
        return ""
    depth = 0
    for offset in range(brace, len(text)):
        if text[offset] == "{":
            depth += 1
        elif text[offset] == "}":
            depth -= 1
            if depth == 0:
                return text[start:offset + 1]
    return ""


def check(text: str) -> tuple[list[str], int]:
    failures = []
    # Comments blanked first: a commented-out arm or a function named only in
    # a comment must not satisfy a fragment (GitHub issue #815).
    text = code_only(text)
    begin = compact(function(text, "unified_fd_clone_begin"))
    install = compact(function(text, "unified_fd_clone_install"))
    rollback = compact(function(text, "unified_fd_clone_detach"))
    run = compact(function(text, "unified_fd_clone_run"))
    scanned = sum(len(part.split()) for part in (begin, install, rollback, run))

    if not begin:
        failures.append("unified_fd_clone_begin is missing or unreadable")
    elif "UnifiedFdCloneTxn[child] = { child_value, 0 };" not in begin:
        failures.append("clone transaction does not begin with an empty prefix")

    if not install:
        failures.append("unified_fd_clone_install is missing or unreadable")
    else:
        required = [
            ("let previous_limit: usize = transaction.limit;",
             "install does not preserve the incoming prefix"),
            ("UnifiedFdInstallResult::Ok, next);",
             "install has no successful replacement transaction"),
            ("{ child_value, fd + 1 };",
             "successful install does not advance the prefix through fd"),
        ]
        for fragment, message in required:
            if fragment not in install:
                failures.append(message)
        if install.count("{ child_value, fd + 1 };") != 1:
            failures.append("exactly one successful arm must advance the prefix")
        for result in ("Invalid", "RefOverflow", "NoMemory"):
            expected = (
                f"UnifiedFdInstallResult::{result} => {{ let mut next: "
                "UnifiedFdCloneTxn[child] = { child_value, previous_limit }; "
                f"return (UnifiedFdInstallResult::{result}, next); }}")
            if expected not in install:
                failures.append(
                    f"{result} install failure does not preserve the prefix")

    if not rollback:
        failures.append("unified_fd_clone_detach is missing or unreadable")
    else:
        for fragment in (
                "UnifiedFdCloneUndo[child] = { child_ctx.block_head, "
                "child_ctx.block_head_generation, installs };",
                "child_ctx.block_head = 0;",
                "child_ctx.block_head_generation = 0;"):
            if fragment not in rollback:
                failures.append(
                    "rollback does not take and clear the child's whole chain")
                break

    if not run:
        failures.append("unified_fd_clone_run is missing or unreadable")
    else:
        empty = ("match unified_fd_next_open(child, 0) { "
                 "UnifiedFdScanResult::Found(taken) => {")
        at = run.find(empty)
        begin_at = run.find("unified_fd_clone_begin(child)")
        if (at < 0 or begin_at < at or
                "UnifiedFdCloneRunResult::Invalid" not in run[at:at + 250]):
            failures.append(
                "clone does not refuse a child with an open descriptor first")

    return failures, scanned


def main() -> int:
    if not SOURCE.exists():
        print(f"FAIL fd-clone-transaction: {SOURCE} is missing", file=sys.stderr)
        return 1
    failures, scanned = check(SOURCE.read_text(encoding="ascii"))
    if failures:
        for failure in failures:
            print(f"ERROR: {failure}", file=sys.stderr)
        print(f"FAIL fd-clone-transaction: {len(failures)} invariant(s) lost",
              file=sys.stderr)
        return 1
    report_pass(
        "fd-clone-transaction",
        "begin is empty, success advances through fd, failures preserve the "
        "prefix, the child starts empty, and rollback takes its whole chain",
        tokens_scanned=scanned,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
