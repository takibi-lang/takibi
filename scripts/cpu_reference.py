#!/usr/bin/env python3
"""A fixed CPU workload that scripts/run_check_lane.sh times next to a fast-
gate member which went over its CPU budget (GitHub issue #823, reopened).

CPU time is not load-independent on this host: SMT sharing, frequency
scaling and cache contention inflated one member from about 750 ms quiet to
2295 ms under allcheck load. So the lane does not judge a member against an
absolute number alone; it judges it against this reference, run under the
same load a moment later. The work is what the members do -- parse Python,
walk the tree, run regexes over text -- with no file reads, so it depends on
nothing in the tree. It takes about 100 ms of CPU on a quiet host. Do not
change ITERATIONS without re-measuring CHECK_CPU_BUDGET_REFS in the Makefile.
"""

import ast
import re

ITERATIONS = 20
SOURCE = "\n".join(
    f"def f{i}(a, b):\n    if a > {i}:\n        return [x * b for x in range(a)]\n"
    f"    return {{'k{i}': a, 'v': (b, {i})}}\n"
    for i in range(60))
WORD = re.compile(r"\b(\w+)\s*\(")

total = 0
for _ in range(ITERATIONS):
    tree = ast.parse(SOURCE)
    total += sum(1 for _ in ast.walk(tree))
    total += len(WORD.findall(SOURCE * 4))
print(total)
