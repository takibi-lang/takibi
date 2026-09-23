#!/usr/bin/env python3
"""Negative controls for the fd-clone transaction boundary check."""

from pathlib import Path
import sys

import check_fd_clone_transaction as check
from pass_line import CaseCount, report_pass


ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "kernel/kernel/fd_table.tkb"
CASES = CaseCount()


def replace_once(text: str, old: str, new: str) -> str:
    if text.count(old) != 1:
        raise RuntimeError(f"control anchor occurs {text.count(old)} times: {old}")
    return text.replace(old, new, 1)


def case(name: str, text: str, wanted: str = "") -> list[str]:
    CASES.note()
    failures, _ = check.check(text)
    if not failures:
        return [f"{name}: planted defect passed"]
    if wanted and not any(wanted in failure for failure in failures):
        return [f"{name}: failure did not explain {wanted!r}: {failures}"]
    return []


def main() -> int:
    source = SOURCE.read_text(encoding="ascii")
    failures = []
    CASES.note()
    current, _ = check.check(source)
    if current:
        failures.append(f"current tree failed: {current}")
    failures += case(
        "nonempty begin",
        replace_once(source, "{ child_value, 0 };", "{ child_value, 1 };"),
        "empty prefix",
    )
    failures += case(
        "success omits installed fd",
        replace_once(source, "{ child_value, fd + 1 };",
                     "{ child_value, fd };"),
        "advance the prefix",
    )
    failures += case(
        "failure advances prefix",
        replace_once(source,
                     "UnifiedFdInstallResult::Invalid => {\n"
                     "            let mut next: UnifiedFdCloneTxn[child] = {\n"
                     "                child_value, previous_limit\n"
                     "            };",
                     "UnifiedFdInstallResult::Invalid => {\n"
                     "            let mut next: UnifiedFdCloneTxn[child] = {\n"
                     "                child_value, fd + 1\n"
                     "            };"),
        "Invalid install failure",
    )
    failures += case(
        "rollback uses wrong bound",
        replace_once(source,
                     "transaction.child_value,\n                                     transaction.limit",
                     "transaction.child_value,\n                                     transaction.child_value"),
        "transaction child and prefix",
    )
    failures += case(
        "install function renamed",
        replace_once(source, "private fn unified_fd_clone_install(",
                     "private fn unified_fd_clone_install_lost("),
        "missing or unreadable",
    )
    if failures:
        for failure in failures:
            print(f"FAIL fd-clone-transaction controls: {failure}",
                  file=sys.stderr)
        return 1
    report_pass(
        "fd-clone-transaction controls",
        f"{CASES.ran} cases -- the current boundary passes; nonempty begin, "
        "off-by-one success, advancing failure, wrong rollback bound, and "
        "renamed install are refused",
        cases=CASES.ran,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
