#!/usr/bin/env python3
"""Controls for the standalone EL0 audit recipe's coverage and dependencies."""
import re
from pathlib import Path

from check_el0_raw_deref_audit import audit_recipe_problems
from pass_line import CaseCount, report_pass

ROOT = Path(__file__).resolve().parent.parent
CASES = CaseCount()
text = (ROOT / "Makefile").read_text()
# The payload's compile call, read from the Makefile so a new probe entry
# point does not need this file edited (#1172 and #1176 each had to).
EL0_CALL = re.search(r"\$\(call KERNEL_EL0_COMPILE,initial_user_payload[^)]*\)", text).group(0)


def check(source, needle=None):
    CASES.note()
    objects, problems = audit_recipe_problems(source)
    if needle is None:
        if problems or not objects:
            raise SystemExit(f"valid EL0 audit recipes refused: {problems}")
    elif not any(needle in problem for problem in problems):
        raise SystemExit(f"EL0 audit control missed {needle!r}: {problems}")


check(text)
check(text.replace(EL0_CALL,
                   "$(TAKIBI) $< -o $@"), "KERNEL_RPI5_USER_PAYLOAD_TKB_O must use")
check(text.replace("--facts $@.facts -o", "-o"), "must contain --facts")
check(text.replace("--check-raw-deref el0 $@.facts/rawderef.tsv $@.facts/deps.d", "--verbose"), "must contain python3")
check(text.replace("$(TAKIBI) $(KERNEL_RAW_DEREF_DEPS) |", "$(TAKIBI) |"), "must depend")
check(text.replace("Makefile scripts/measure_trusted_base.py scripts/raw_deref_budget.tsv",
                   "Makefile scripts/measure_trusted_base.py"), "must contain scripts/raw_deref_budget.tsv")
check(text.replace("$(LLD) -pie", "$(LLD)"), "no standalone EL0")

report_pass("el0-raw-deref-audit controls",
            "the real recipes pass; bypassed compilation, missing audit, "
            "gate, depfile or rebuild dependency, and empty coverage are refused",
            cases=CASES.ran)
