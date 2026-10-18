#!/usr/bin/env python3
"""Controls for ci_time_budget.py (#816)."""

import pathlib

from ci_time_budget import CI, job_limit_minutes, verdict
from pass_line import CaseCount, report_pass


def main() -> int:
    cases = CaseCount()
    text = CI.read_text()
    limit = job_limit_minutes(text)
    assert limit > 0
    cases.note()
    assert verdict(limit * 60 * 0.75, limit)[0], "exactly the budget passes"
    cases.note()
    assert not verdict(limit * 60 * 0.75 + 1, limit)[0], "past the budget fails"
    cases.note()
    assert not verdict(limit * 60, limit)[0], "the hard limit itself fails"
    for name, broken in {
        "no limit": text.replace(f"timeout-minutes: {limit}", ""),
        "two limits": text.replace(f"    timeout-minutes: {limit}\n",
                                   f"    timeout-minutes: {limit}\n    timeout-minutes: 5\n"),
        "job renamed": text.replace("  hardware-free:\n", "  other:\n"),
    }.items():
        assert broken != text, f"control {name} changed nothing"
        cases.note()
        try:
            job_limit_minutes(broken)
        except ValueError:
            continue
        raise AssertionError(name)
    report_pass("ci-time-budget controls",
                f"the {limit} min limit is read from {pathlib.Path(CI)}; the budget boundary "
                f"and {cases.ran} shapes behave", controls=cases.ran)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
