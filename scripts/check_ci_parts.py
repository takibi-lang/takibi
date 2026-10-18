#!/usr/bin/env python3
"""CI's parallel parts cover cicheck exactly, and the budget step stays (#816).

`make cicheck` runs on GitHub Actions as one matrix job per part
(`make cicheck-<part>`). A part left out of the matrix, or a lane left out of
every part, would silently drop coverage that allcheck still has. So:

  - the Makefile defines CICHECK_PART_<NAME> for each part, and cicheck's
    lane list CICHECK_LANES is exactly their concatenation;
  - every part has a `cicheck-<part>` target sharing cicheck's recipe;
  - .github/workflows/ci.yml's hardware-free matrix lists exactly those
    parts, runs `make cicheck-${{ matrix.part }}`, and runs
    scripts/ci_time_budget.py with the job start it records.

Also runs its own controls. Exit code only (0 = pass, 1 = fail).
"""

import pathlib
import re
import sys

from pass_line import CaseCount, report_pass

MAKEFILE = pathlib.Path("Makefile")
CI = pathlib.Path(".github/workflows/ci.yml")
PART_DEF = re.compile(r"^CICHECK_PART_([A-Z]+) := ", re.M)
LANES_DEF = re.compile(r"^CICHECK_LANES := (.*)$", re.M)
TARGETS = re.compile(r"^(cicheck(?: cicheck-[a-z]+)*):\n", re.M)
MATRIX = re.compile(r"^\s+part: \[([^\]]*)\]\s*$", re.M)
RUN = "make cicheck-${{ matrix.part }}"
BUDGET = 'python3 scripts/ci_time_budget.py "$CI_JOB_START"'
START = 'echo "CI_JOB_START=$(date +%s)" >> "$GITHUB_ENV"'


def problems(makefile: str, ci: str) -> list:
    found = []
    parts = [p.lower() for p in PART_DEF.findall(makefile)]
    if not parts:
        return [f"{MAKEFILE} defines no CICHECK_PART_<NAME>"]
    lanes = LANES_DEF.search(makefile)
    expected = " ".join(f"$(CICHECK_PART_{p.upper()})" for p in parts)
    if not lanes or lanes.group(1).split() != expected.split():
        found.append(f"{MAKEFILE}: CICHECK_LANES must be exactly `{expected}`")
    targets = TARGETS.search(makefile)
    names = targets.group(1).split() if targets else []
    want = ["cicheck"] + [f"cicheck-{p}" for p in parts]
    if sorted(names) != sorted(want):
        found.append(f"{MAKEFILE}: one recipe must build {' '.join(want)}, found {names}")
    for name in want:
        if not re.search(rf"^cicheck_lanes_{re.escape(name)} := ", makefile, re.M):
            found.append(f"{MAKEFILE}: no cicheck_lanes_{name}")
    matrix = MATRIX.findall(ci)
    if len(matrix) != 1:
        found.append(f"{CI} has {len(matrix)} `part:` matrices, expected 1")
    elif sorted(x.strip() for x in matrix[0].split(",")) != sorted(parts):
        found.append(f"{CI}'s matrix parts {matrix[0]!r} differ from the Makefile's {parts}")
    for needle, what in ((RUN, "run each part"), (BUDGET, "check the time budget"),
                         (START, "record the job start")):
        if needle not in ci:
            found.append(f"{CI} does not {what} (`{needle}`)")
    return found


def controls(makefile: str, ci: str) -> int:
    cases = CaseCount()
    failing = {
        "part missing from matrix": (makefile, ci.replace("[lang, models, qemu]", "[lang, qemu]")),
        "lane list drops a part": (makefile.replace(
            "CICHECK_LANES := $(CICHECK_PART_LANG) $(CICHECK_PART_MODELS) $(CICHECK_PART_QEMU)",
            "CICHECK_LANES := $(CICHECK_PART_LANG) $(CICHECK_PART_QEMU)"), ci),
        "target missing": (makefile.replace(
            "cicheck cicheck-lang cicheck-models cicheck-qemu:\n",
            "cicheck cicheck-lang cicheck-qemu:\n"), ci),
        "back to one serial job": (makefile, ci.replace(RUN, "make cicheck")),
        "budget step removed": (makefile, ci.replace(BUDGET, "true")),
    }
    for name, (mk, yml) in failing.items():
        assert (mk, yml) != (makefile, ci), f"control {name} changed nothing"
        cases.note()
        assert problems(mk, yml), name
    return cases.ran


def main() -> int:
    makefile, ci = MAKEFILE.read_text(), CI.read_text()
    found = problems(makefile, ci)
    for problem in found:
        print(f"FAIL ci-parts: {problem}")
    if found:
        return 1
    ran = controls(makefile, ci)
    parts = len(PART_DEF.findall(makefile))
    report_pass("ci-parts", f"{parts} CI parts cover cicheck exactly and each checks its time "
                f"budget; {ran} drift shapes are refused", parts=parts, controls=ran)
    return 0


if __name__ == "__main__":
    sys.exit(main())
