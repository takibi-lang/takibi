#!/usr/bin/env python3
"""CI's parallel parts cover cicheck exactly, and set up only what they use (#816).

`make cicheck` runs on GitHub Actions as one matrix job per part
(`make cicheck-<part>`). A part left out of the matrix, or a lane left out of
every part, would silently drop coverage that allcheck still has; a lane in
two parts costs its minutes twice; and a part that sets up a tool none of its
lanes runs pays for it on every run (the herd7 build cost the lang and QEMU
parts seven minutes each in run 39108650565). So:

  - the Makefile defines CICHECK_PART_<NAME> for each part, and cicheck's
    lane list CICHECK_LANES is exactly their concatenation;
  - expanded by make itself, the parts hold every hardware-free lane of
    allcheck exactly once (allcheck's lane list with kernelcheck replaced by
    KERNELCHECK_QEMU_LANES);
  - every part has a `cicheck-<part>` target sharing cicheck's recipe;
  - .github/workflows/ci.yml's hardware-free matrix lists exactly those
    parts, runs `make cicheck-${{ matrix.part }}`, records the job start,
    runs scripts/ci_time_budget.py, and uploads the failure evidence (lane
    timing) on cancellation as well as failure;
  - each tool step (Java, the model-tools cache, the herd7 cache and build,
    the kernel-image prebuild) has an `if:` that admits exactly the parts
    whose lanes use it, derived from the expanded part lists below.

Also runs its own controls. Exit code only (0 = pass, 1 = fail).
"""

import pathlib
import re
import subprocess
import sys

from pass_line import CaseCount, report_pass

MAKEFILE = pathlib.Path("Makefile")
CI = pathlib.Path(".github/workflows/ci.yml")
PART_DEF = re.compile(r"^CICHECK_PART_([A-Z]+) := ", re.M)
LANES_DEF = re.compile(r"^CICHECK_LANES := (.*)$", re.M)
TARGETS = re.compile(r"^(cicheck(?: cicheck-[a-z]+)*):\n", re.M)
MATRIX = re.compile(r"^\s+part: \[([^\]]*)\]\s*$", re.M)
ALLCHECK = re.compile(r"resource_lease_run_suite allcheck \\\n\t+\$\(MAKE\) ([a-z ]+?) \|\|")
RUN = "make cicheck-${{ matrix.part }}"
BUDGET = 'python3 scripts/ci_time_budget.py "$CI_JOB_START"'
UPLOAD = "      - name: Preserve failure evidence\n        if: failure() || cancelled()\n"
START = 'echo "CI_JOB_START=$(date +%s)" >> "$GITHUB_ENV"'
STEP = re.compile(r"^      - ", re.M)
QEMU_LANE = re.compile(r"^kernelcheck-.*qemu.*$")


def uses_qemu(lanes):
    return any(QEMU_LANE.match(lane) for lane in lanes)


# Which parts need each tool, as a function of a part's expanded lanes, and
# how to recognise the step that sets it up. Java and the model tools: TLC
# and Apalache in modelcheck, and every QEMU lane's boot replays its protocol
# trace under TLC (scripts/run_kernel_qemutest.sh, #606). herd7: litmuscheck,
# a prerequisite of modelcheck only.
TOOLS = {
    "java": ("uses: actions/setup-java@",
             lambda lanes: "modelcheck" in lanes or uses_qemu(lanes)),
    "model-tools cache": ("path: /home/runner/model-tools",
                          lambda lanes: "modelcheck" in lanes or uses_qemu(lanes)),
    "herd7 cache": ("path: /home/runner/herd7", lambda lanes: "modelcheck" in lanes),
    "herd7 build": ("scripts/build_herd7.sh /home/runner/herd7",
                    lambda lanes: "modelcheck" in lanes),
    "kernel-image prebuild": ("make kernelbuild-images", uses_qemu),
}


def expand(names, makefile_path=MAKEFILE):
    """{VAR: [words]} as make expands them."""
    recipe = "; ".join(f"echo '{n}='$({n})" for n in names)
    out = subprocess.run(
        ["make", "-s", "--no-print-directory", "-f", str(makefile_path),
         "--eval", f"_ci_parts_print: ; @{recipe}", "_ci_parts_print"],
        capture_output=True, text=True, check=True, timeout=10).stdout
    return {k: v.split() for k, v in (line.split("=", 1) for line in out.splitlines())}


def admits(condition, part):
    """Evaluate a step's `if:` for one matrix part; None means unparseable."""
    if condition is None:
        return True
    expr = re.sub(r"steps\.[\w.-]+", "'step'", condition)
    expr = expr.replace("matrix.part", repr(part)).replace("||", " or ").replace("&&", " and ")
    if not re.fullmatch(r"(\s|'[\w-]*'|==|!=|\(|\)|or|and)*", expr):
        return None
    return bool(eval(expr, {"__builtins__": {}}))  # noqa: S307 -- tokens checked above


def tool_problems(ci, part_lanes):
    found = []
    steps = STEP.split(ci)[1:]
    for tool, (needle, needs) in TOOLS.items():
        blocks = [s for s in steps if needle in s]
        if len(blocks) != 1:
            found.append(f"{CI}: {len(blocks)} steps set up {tool} (`{needle}`), expected 1")
            continue
        cond = re.search(r"^        if: (.*)$", blocks[0], re.M)
        cond = cond.group(1).strip() if cond else None
        for part, lanes in part_lanes.items():
            got = admits(cond, part)
            if got is None:
                found.append(f"{CI}: cannot read the {tool} step's `if: {cond}`")
                break
            if got != needs(lanes):
                found.append(f"{CI}: the {tool} step {'runs' if got else 'does not run'} "
                             f"for part {part}, whose lanes {'do not ' if got else ''}use it")
    return found


def problems(makefile, ci, part_lanes, qemu_lanes):
    found = []
    parts = [p.lower() for p in PART_DEF.findall(makefile)]
    if not parts:
        return [f"{MAKEFILE} defines no CICHECK_PART_<NAME>"]
    lanes = LANES_DEF.search(makefile)
    expected = " ".join(f"$(CICHECK_PART_{p.upper()})" for p in parts)
    if not lanes or lanes.group(1).split() != expected.split():
        found.append(f"{MAKEFILE}: CICHECK_LANES must be exactly `{expected}`")
    allcheck = ALLCHECK.search(makefile)
    if not allcheck:
        found.append(f"{MAKEFILE}: cannot find allcheck's lane list")
    else:
        want = []
        for lane in allcheck.group(1).split():
            want += qemu_lanes if lane == "kernelcheck" else [lane]
        got = [lane for p in parts for lane in part_lanes.get(p, [])]
        for lane in sorted(set(want) - set(got)):
            found.append(f"{MAKEFILE}: allcheck lane {lane} is in no CI part")
        for lane in sorted({x for x in got if got.count(x) > 1}):
            found.append(f"{MAKEFILE}: lane {lane} is in more than one CI part")
        for lane in sorted(set(got) - set(want)):
            found.append(f"{MAKEFILE}: CI part lane {lane} is not an allcheck lane")
    targets = TARGETS.search(makefile)
    names = targets.group(1).split() if targets else []
    want_t = ["cicheck"] + [f"cicheck-{p}" for p in parts]
    if sorted(names) != sorted(want_t):
        found.append(f"{MAKEFILE}: one recipe must build {' '.join(want_t)}, found {names}")
    for name in want_t:
        if not re.search(rf"^cicheck_lanes_{re.escape(name)} := ", makefile, re.M):
            found.append(f"{MAKEFILE}: no cicheck_lanes_{name}")
    matrix = MATRIX.findall(ci)
    if len(matrix) != 1:
        found.append(f"{CI} has {len(matrix)} `part:` matrices, expected 1")
    elif sorted(x.strip() for x in matrix[0].split(",")) != sorted(parts):
        found.append(f"{CI}'s matrix parts {matrix[0]!r} differ from the Makefile's {parts}")
    for needle, what in ((RUN, "run each part"), (BUDGET, "check the time budget"),
                         (START, "record the job start"),
                         (UPLOAD, "keep failure evidence on cancellation too")):
        if needle not in ci:
            found.append(f"{CI} does not {what} (`{needle}`)")
    found += tool_problems(ci, {p: part_lanes.get(p, []) for p in parts})
    return found


def swap(text, old, new):
    assert old in text, f"control text {old!r} not found"
    return new.join(text.split(old))


def controls(makefile, ci, part_lanes, qemu_lanes):
    cases = CaseCount()
    race = part_lanes["race"]
    moved = dict(part_lanes, qemu=part_lanes["qemu"] + race[:1])
    dropped = dict(part_lanes, race=race[1:])
    failing = {
        "part missing from matrix": (makefile, swap(ci, "[lang, models, qemu, race]",
                                                    "[lang, models, qemu]"), part_lanes),
        "lane list drops a part": (swap(
            makefile, "$(CICHECK_PART_QEMU) $(CICHECK_PART_RACE)\n", "$(CICHECK_PART_QEMU)\n"),
            ci, part_lanes),
        "target missing": (swap(makefile, " cicheck-race:\n", ":\n"), ci, part_lanes),
        "one serial run": (makefile, swap(ci, RUN, "make cicheck"), part_lanes),
        "budget step removed": (makefile, swap(ci, BUDGET, "true"), part_lanes),
        "evidence on failure only": (makefile, swap(ci, "failure() || cancelled()",
                                                    "failure()"), part_lanes),
        "lane in two parts": (makefile, ci, moved),
        "lane in no part": (makefile, ci, dropped),
        "herd7 built for every part": (makefile, swap(
            ci, "cache-hit != 'true' && matrix.part == 'models'",
            "cache-hit != 'true'"), part_lanes),
        "herd7 restored for qemu": (makefile, swap(
            ci, "        if: matrix.part == 'models'\n        uses: actions/cache@v4",
            "        if: matrix.part != 'lang'\n        uses: actions/cache@v4"), part_lanes),
        "java for lang": (makefile, swap(
            ci, "        if: matrix.part != 'lang'\n        uses: actions/setup-java@",
            "        uses: actions/setup-java@"), part_lanes),
        "java missing for a QEMU part": (makefile, swap(
            ci, "        if: matrix.part != 'lang'\n        uses: actions/setup-java@",
            "        if: matrix.part == 'models'\n        uses: actions/setup-java@"), part_lanes),
        "kernel images for models": (makefile, swap(
            ci, "if: matrix.part == 'qemu' || matrix.part == 'race'",
            "if: matrix.part != 'lang'"), part_lanes),
        "unreadable condition": (makefile, swap(
            ci, "if: matrix.part == 'qemu' || matrix.part == 'race'",
            "if: startsWith(matrix.part, 'q')"), part_lanes),
    }
    for name, (mk, yml, lanes) in failing.items():
        assert (mk, yml, lanes) != (makefile, ci, part_lanes), f"control {name} changed nothing"
        cases.note()
        assert problems(mk, yml, lanes, qemu_lanes), name
    return cases.ran


def main():
    makefile, ci = MAKEFILE.read_text(), CI.read_text()
    parts = [p.lower() for p in PART_DEF.findall(makefile)]
    values = expand([f"CICHECK_PART_{p.upper()}" for p in parts] + ["KERNELCHECK_QEMU_LANES"])
    part_lanes = {p: values[f"CICHECK_PART_{p.upper()}"] for p in parts}
    qemu_lanes = values["KERNELCHECK_QEMU_LANES"]
    found = problems(makefile, ci, part_lanes, qemu_lanes)
    for problem in found:
        print(f"FAIL ci-parts: {problem}")
    if found:
        return 1
    ran = controls(makefile, ci, part_lanes, qemu_lanes)
    lanes = sum(len(v) for v in part_lanes.values())
    report_pass("ci-parts", f"{len(parts)} CI parts hold {lanes} lanes, each exactly once, "
                f"check their time budget and set up only the {len(TOOLS)} tools their lanes "
                f"use; {ran} drift shapes are refused",
                parts=len(parts), lanes=lanes, controls=ran)
    return 0


if __name__ == "__main__":
    sys.exit(main())
