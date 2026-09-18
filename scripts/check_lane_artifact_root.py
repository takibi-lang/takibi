#!/usr/bin/env python3
"""Every kernel lane must hang its capture off one artifact root.

GitHub issue #561. `scripts/repeat_kernel_lane.sh` runs a lane N times and
keeps each sample's evidence apart, which is the whole point of running it:
for a timing-sensitive failure the useful comparison is a passing boot beside
a failing one. It takes an arbitrary command, so it cannot know which lanes
that command will reach, and it cannot name each lane's own
`KERNEL_*_ARTIFACT_DIR`. What it can move is the ROOT they all hang off,
`TAKIBI_LANE_ARTIFACT_ROOT`.

A lane that ignores the root keeps writing its fixed `_build/kernel-<lane>/`
path, and the next sample replaces the failing one's UART log, gdb log and
verdict. That is silent: the repeat run still prints a rate, the sample
directory still exists, and only the person who then opens it finds it holds
nothing but `run.log`. It cost one diagnosis a second reproduction on
2026-09-16.

So this check refuses the lane, not the flake. Three surfaces have to agree:

  - each `scripts/run_kernel_*.sh` derives ARTIFACT_DIR through the root;
  - the Makefile's per-variant overrides use the same root, and define it
    with `?=` so an exported value wins;
  - `repeat_kernel_lane.sh` still sets it per sample.

Every other `$REPO_ROOT/_build/...` literal in a lane runner is classified
rather than ignored, because a new directory written beside ARTIFACT_DIR is
exactly how a lane would leak evidence past the root again. A literal is
allowed when it names a FILE the build produced (a lane reads those; it does
not write them), or when it is this lane's own archive root -- its artifact
directory's name plus `-failures`, handed to archive_kernel_failure.sh. That
one stays outside the root deliberately: it is already timestamped and never
overwritten, and keeping every archived capture under one path is what makes
"show me the failing captures" a single listing rather than a walk over
sample directories.
"""

import pathlib
import re
import sys

from pass_line import report_pass

ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / "scripts"
MAKEFILE = ROOT / "Makefile"
REPEAT = SCRIPTS / "repeat_kernel_lane.sh"

ROOT_VAR = "TAKIBI_LANE_ARTIFACT_ROOT"
EXPANSION = '${' + ROOT_VAR + ':-$REPO_ROOT/_build}'

ARTIFACT_LINE = re.compile(
    r'^ARTIFACT_DIR="\$\{([A-Z0-9_]+):-(.*?)/([a-z0-9-]+)\}"$', re.M)
BUILD_LITERAL = re.compile(r'\$REPO_ROOT/_build/([A-Za-z0-9._-]+)')
ARCHIVE_CALL = "archive_kernel_failure.sh"

# A runner with no capture of its own. Stated rather than skipped: an entry
# here is a claim that can stop being true, and the check says so if the file
# grows an ARTIFACT_DIR later.
NO_CAPTURE = {
    "run_kernel_build_locked.sh":
        "a build lock wrapper: it runs the compiler under a lock and writes "
        "no capture of its own",
}


def check_runner(path):
    """Problems with one lane runner."""
    text = path.read_text(encoding="ascii")
    problems = []
    matches = ARTIFACT_LINE.findall(text)
    exempt = NO_CAPTURE.get(path.name)

    if not matches:
        if exempt is None:
            if "ARTIFACT_DIR=" in text:
                problems.append(
                    f"{path.name} assigns ARTIFACT_DIR in a shape this check "
                    f"cannot read; write it as "
                    f'ARTIFACT_DIR="${{LANE_VAR:-{EXPANSION}/lane-name}}"')
            else:
                problems.append(
                    f"{path.name} defines no ARTIFACT_DIR and is not listed "
                    f"as writing no capture; a lane that writes evidence "
                    f"somewhere this check cannot see loses it on a repeat")
        return problems, None
    if exempt is not None:
        problems.append(
            f"{path.name} is listed as writing no capture ({exempt}), and it "
            f"now defines ARTIFACT_DIR: remove the entry")
    if len(matches) > 1:
        problems.append(f"{path.name} defines ARTIFACT_DIR more than once")

    _, prefix, lane = matches[0]
    if prefix != EXPANSION:
        problems.append(
            f"{path.name} hangs its artifact directory off `{prefix}` rather "
            f"than `{EXPANSION}`: a repeated lane would overwrite each "
            f"sample's capture with the next sample's")
    return problems, lane


def check_literals(path, lane):
    """Every other _build path in a lane runner is classified, not ignored."""
    text = path.read_text(encoding="ascii")
    archives = ARCHIVE_CALL in text
    problems = []
    for name in sorted(set(BUILD_LITERAL.findall(text))):
        if name == lane:
            continue
        if "." in name:
            continue
        if lane is not None and name == f"{lane}-failures":
            if not archives:
                problems.append(
                    f"{path.name} names `_build/{name}` and never calls "
                    f"{ARCHIVE_CALL}: a directory outside the artifact root "
                    f"that nothing archives into")
            continue
        problems.append(
            f"{path.name} writes `$REPO_ROOT/_build/{name}`, which is neither "
            f"its artifact directory, a build file it reads, nor its own "
            f"`{lane}-failures` archive root: route it through "
            f"${ROOT_VAR} or it is lost on the next sample")
    return problems


def main() -> int:
    runners = sorted(SCRIPTS.glob("run_kernel_*.sh"))
    if not runners:
        print("FAIL lane-artifact-root: no scripts/run_kernel_*.sh found")
        return 1

    problems = []
    lanes = 0
    for path in runners:
        found, lane = check_runner(path)
        problems += found
        if lane is not None:
            lanes += 1
            problems += check_literals(path, lane)

    for name, reason in NO_CAPTURE.items():
        if not (SCRIPTS / name).exists():
            problems.append(
                f"scripts/{name} is listed as writing no capture ({reason}) "
                f"and does not exist: remove the entry")

    makefile = MAKEFILE.read_text(encoding="ascii")
    if not re.search(rf"^{ROOT_VAR} \?= ", makefile, re.M):
        problems.append(
            f"the Makefile does not define {ROOT_VAR} with `?=`, so an "
            f"exported root would not win and every lane would write "
            f"_build/ whatever the caller asked for")
    overrides = re.findall(
        r'(KERNEL_[A-Z0-9_]*ARTIFACT_DIR)="([^"]*)/[a-z0-9-]+"', makefile)
    if not overrides:
        problems.append(
            "the Makefile sets no per-variant KERNEL_*_ARTIFACT_DIR; this "
            "check reads those overrides and they have moved")
    for variable, prefix in overrides:
        if prefix != f"$({ROOT_VAR})":
            problems.append(
                f"the Makefile points {variable} at `{prefix}/...` rather "
                f"than `$({ROOT_VAR})/...`, so that variant keeps its fixed "
                f"directory under a repeat")

    repeat = REPEAT.read_text(encoding="ascii")
    if f'"{ROOT_VAR}=$sample_dir"' not in repeat:
        problems.append(
            f"scripts/repeat_kernel_lane.sh no longer points {ROOT_VAR} at "
            f"each sample's own directory, so every lane it runs shares one "
            f"capture again")

    if problems:
        for problem in problems:
            print(f"ERROR\tlane-artifact-root: {problem}")
        print(f"FAIL lane-artifact-root: {len(problems)} lane artifact "
              f"path(s) escape the shared root")
        return 1
    report_pass("lane-artifact-root",
                f"{lanes} lane runner(s) plus "
                f"{len(set(v for v, _ in overrides))} Makefile variant "
                f"override(s) hang their capture off ${ROOT_VAR}, which "
                f"repeat_kernel_lane.sh moves per sample",
                lanes=lanes)
    return 0


if __name__ == "__main__":
    sys.exit(main())
