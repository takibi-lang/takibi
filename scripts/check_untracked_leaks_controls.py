#!/usr/bin/env python3
"""GitHub issue #1391: the untracked-leak report compares its lists right."""
from pass_line import report_pass
import untracked_leaks

cases = untracked_leaks.controls()
report_pass("untracked-leaks controls",
            f"{cases} planted before/after lists compared", cases=cases)
