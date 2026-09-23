#!/usr/bin/env python3
"""Keep the fd-clone transaction's runtime prefix equal to installed fds.

The linear type checker proves that callers consume the transaction through
rollback or commit. It cannot prove the arithmetic inside the small trusted
implementation boundary: success must advance through the installed fd,
failure must preserve the previous prefix, and rollback must use that prefix.
This check pins those concrete relationships from issue #297.
"""

from pathlib import Path
import sys

from pass_line import report_pass


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
    begin = compact(function(text, "unified_fd_clone_begin"))
    install = compact(function(text, "unified_fd_clone_install"))
    rollback = compact(function(text, "unified_fd_clone_rollback"))
    scanned = sum(len(part.split()) for part in (begin, install, rollback))

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
        failures.append("unified_fd_clone_rollback is missing or unreadable")
    elif ("unified_fd_clone_rollback_prefix(transaction.child_value, "
          "transaction.limit);" not in rollback):
        failures.append("rollback does not use the transaction child and prefix")

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
        "prefix, and rollback consumes that prefix",
        tokens_scanned=scanned,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
