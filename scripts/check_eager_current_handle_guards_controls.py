#!/usr/bin/env python3
"""Controls for the eager current-handle guard check."""

from pathlib import Path

import check_eager_current_handle_guards as check
from pass_line import report_pass


ROOT = Path(__file__).resolve().parent.parent


def main() -> int:
    controls = []
    source = (ROOT / "kernel/kernel/process.tkb").read_text(encoding="ascii")
    assert not check.findings(source)
    controls.append("current tree")
    for operator in ("&&", "||"):
        unsafe = ("return execution_here().current_live " + operator +
                  " scheduled_process_record_of(" +
                  "execution_here().current_handle).has_parent;")
        assert len(check.findings(unsafe)) == 1
        controls.append(operator)
    safe = ("if (execution_here().current_live == false) { return false; } "
            "return scheduled_process_record_of(" +
            "execution_here().current_handle).has_parent;")
    assert not check.findings(safe)
    controls.append("early return")
    commented = "// " + unsafe + "\n" + safe
    assert not check.findings(commented)
    controls.append("comment")
    report_pass("eager-current-handle-guards controls",
                "both eager operators are refused; early return and "
                "comments are not mistaken for one", controls=len(controls))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
