#!/usr/bin/env python3
"""Every unleased CPU-heavy Makefile recipe runs under $(NICE_HEAVY).

GitHub issue #854 (maintainer decision 2026-10-22, option B). Multi-lane QEMU
boots stalled in the lock-step contention probes about every other land: each
probe round needs all of a guest's vCPU threads on a host CPU together, and the
land's own compiles, dune runs and model checks oversubscribed the host, so a
round cost a scheduler slice and a phase overran the UART no-progress budget.
The fix lowers the priority of that work, not of the guests. A heavy command
that runs at normal priority brings the stall back, and nothing else would say
so until a land failed minutes into a lane.

The rule, over the Makefile's recipe lines (backslash continuations joined,
comment-only lines skipped):
- NICE_HEAVY is defined as `nice -n <positive>`.
- A line that runs a heavy command (the compiler $(TAKIBI), dune, the model,
  litmus, fuzz and slowcheck runners, the dune test lister, a build-lock runner)
  names $(NICE_HEAVY), or a variable whose definition starts with it.
- KERNEL_BUILD_LOCK_RUN and LINUX_BUILD_LOCK_RUN start with $(NICE_HEAVY).
- A QEMU lane line (scripts/run_lane.sh) does not name $(NICE_HEAVY): the
  guests are what the priority split protects.
Lexical; the controls plant each shape.
"""

import pathlib
import re
import sys

from pass_line import report_pass

ROOT = pathlib.Path(__file__).resolve().parent.parent

HEAVY = re.compile(
    r"\$\(TAKIBI\)"
    r"|(?:^|[\s;&|@(`])dune\s+(?:build|runtest|test|exec|clean)\b"
    r"|run_check_lane\.sh\s+slowcheck"
    r"|run_model_checks\.sh|run_litmus_checks\.py|list_dune_test_failures\.sh"
    r"|fuzz_compiler\.py"
    r"|run_kernel_build_locked\.sh|run_linux_build_locked\.sh")
NICED_VARS = ("NICE_HEAVY", "KERNEL_BUILD_LOCK_RUN", "LINUX_BUILD_LOCK_RUN")
NICE_DEF = re.compile(r"^NICE_HEAVY\s*:?=\s*nice -n [1-9][0-9]*\s*$", re.M)


def recipe_lines(text: str):
    """(line number, logical recipe line) for each tab-led line."""
    lines = text.split("\n")
    i = 0
    while i < len(lines):
        start = i
        line = lines[i]
        while line.endswith("\\") and i + 1 < len(lines):
            i += 1
            line = line[:-1] + " " + lines[i].lstrip("\t")
        i += 1
        if line.startswith("\t") and not re.match(r"\t@?#", line):
            yield start + 1, line


def problems_in(text: str) -> list:
    found = []
    if not NICE_DEF.search(text):
        found.append("Makefile: no `NICE_HEAVY := nice -n <positive>`")
    for var in ("KERNEL_BUILD_LOCK_RUN", "LINUX_BUILD_LOCK_RUN"):
        m = re.search(r"^" + var + r"\s*:?=\s*(.*)$", text, re.M)
        if m and not m.group(1).startswith("$(NICE_HEAVY)"):
            found.append(f"Makefile: {var} does not start with $(NICE_HEAVY)")
    for number, line in recipe_lines(text):
        niced = any(f"$({v})" in line for v in NICED_VARS)
        if "scripts/run_lane.sh" in line:
            if "$(NICE_HEAVY)" in line:
                found.append(f"Makefile:{number}: a QEMU lane runs under "
                             "$(NICE_HEAVY); the guests must keep normal priority")
            continue
        if HEAVY.search(line) and not niced:
            found.append(f"Makefile:{number}: heavy command without $(NICE_HEAVY): "
                         + line.strip()[:100])
    return found


def control() -> bool:
    head = ("NICE_HEAVY := nice -n 10\n"
            "KERNEL_BUILD_LOCK_RUN := $(NICE_HEAVY) bash scripts/run_kernel_build_locked.sh x\n"
            "LINUX_BUILD_LOCK_RUN := $(NICE_HEAVY) bash scripts/run_linux_build_locked.sh x\n")
    good = head + ("a:\n\t$(NICE_HEAVY) $(TAKIBI) a.tkb -o a.o\n"
                   "\t@$(KERNEL_BUILD_LOCK_RUN) $(MAKE) _k\n"
                   "\t@# dune build in a comment\n"
                   "\tcd d && $(NICE_HEAVY) $(abspath $(TAKIBI)) \\\n\t\tx.tkb\n"
                   "\t@bash scripts/run_lane.sh $@ $(MAKE) _q\n")
    bad_compile = head + "a:\n\t$(TAKIBI) a.tkb -o a.o\n"
    bad_cont = head + "a:\n\tcd d && \\\n\t\t$(abspath $(TAKIBI)) x.tkb\n"
    bad_dune = head + "a:\n\t@dune runtest --force\n"
    bad_slow = head + "a:\n\t@bash scripts/run_check_lane.sh slowcheck\n"
    bad_lock = good.replace("KERNEL_BUILD_LOCK_RUN := $(NICE_HEAVY) bash",
                            "KERNEL_BUILD_LOCK_RUN := bash")
    bad_def = good.replace("nice -n 10", "nice -n 0")
    bad_lane = head + "a:\n\t@$(NICE_HEAVY) bash scripts/run_lane.sh $@ $(MAKE) _q\n"
    return (not problems_in(good)
            and all(len(problems_in(t)) == 1 for t in
                    (bad_compile, bad_cont, bad_dune, bad_slow, bad_lock,
                     bad_def, bad_lane)))


def main() -> int:
    if not control():
        print("FAIL nice-heavy: the control plants an un-niced heavy recipe "
              "and the check did not refuse it (or refused a niced one)",
              file=sys.stderr)
        return 1
    text = (ROOT / "Makefile").read_text(encoding="utf-8")
    problems = problems_in(text)
    if problems:
        for problem in problems:
            print(f"  {problem}", file=sys.stderr)
        print("FAIL nice-heavy: unleased CPU-heavy work at normal priority "
              "starves the QEMU guests' boot probes (#854)", file=sys.stderr)
        return 1
    count = sum(1 for _, line in recipe_lines(text) if HEAVY.search(line))
    report_pass("nice-heavy",
                f"{count} heavy Makefile recipe line(s) run under $(NICE_HEAVY); "
                "QEMU lanes keep normal priority", lines=count)
    return 0


if __name__ == "__main__":
    sys.exit(main())
