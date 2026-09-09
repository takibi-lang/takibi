#!/usr/bin/env python3
"""A number the documentation transcribes, checked against the tree it counts.

`kernel/README.md` shows what a successful hardware run prints:

    PASS kernel/rpi5 (44 views, one boot)

That count is not a decision. It is what the runner counts, copied by hand, and
it changes whenever a view is added or removed. Four commits reachable from
`git log -L 401,401:kernel/README.md` existed only to repair it -- 21 to 25, 31
to 37, 37 to 38, 38 to 43 -- and two of the four were found by a deliberate
audit rather than by anything failing. It moved a fifth time on 2026-09-09,
when the board started running the ext2 mutation probes, and again it was a
person who noticed. Between audits the file states a number that is simply
untrue, and a wrong count and a right one look identical (GitHub issue #522).

A transcribed number is a verdict with no verifier. This is the verifier, and
it is the same instrument `scripts/check_agents_paths.py` points at paths.

WHAT IS DECLARED IS CHECKED, AND NOTHING ELSE. A number is opted in by
appearing in CLAIMS below, with its derivation written beside it, because the
alternative -- finding numbers in prose and guessing what they count -- cannot
tell an inventory from a measurement. `kernel/RESOURCE_LIMITS.md` records that
a step finished at "37 views, up from 31", and `HISTORY.md` is full of such
numbers: those are records of what was true at the time, they are SUPPOSED to
go stale, and rewriting them would destroy what those files are for.
"""

import pathlib
import re
import sys

from pass_line import report_pass

REPO = pathlib.Path(__file__).resolve().parent.parent
VIEW_ROOT = REPO / "kernel" / "tests"


def lane_view_count(platform: str) -> int:
    """The number a lane runner prints, derived the way the runner derives it.

    This mirrors `scripts/run_kernel_hwtest_rpi5.sh` and
    `scripts/run_kernel_qemutest.sh`, which build `view_names` as the union of
    the BASENAMES of `common/*.filter` and `<platform>/*.filter` -- a platform
    filter overriding a common one of the same name is one view, not two --
    and then count the views that pass.

    Counting `*.expected` instead agrees today and is still the wrong rule. The
    expected file is what a view is compared against; the filter is what makes
    it exist. `kernel/tests/qemu-debug/views/` holds expected files and no
    filters at all, because it is an overlay selected by
    KERNEL_QEMU_EXPECTED_VIEW_DIR rather than a lane of its own -- so a rule
    that happens to work for two platforms is badly wrong for the third, and it
    would go wrong for these two the moment a filter and an expected file
    stopped arriving in pairs.
    """
    names = set()
    for directory in ("common", platform):
        for filter_file in (VIEW_ROOT / directory / "views").glob("*.filter"):
            names.add(filter_file.stem)
    return len(names)


class Claim:
    """One documented number, where it is written, and how it is derived."""

    def __init__(self, path: str, pattern: str, derive, describes: str):
        self.path = path
        self.pattern = re.compile(pattern, re.MULTILINE)
        self.derive = derive
        self.describes = describes


CLAIMS = (
    Claim(
        path="kernel/README.md",
        pattern=r"^PASS kernel/rpi5 \((\d+) views, one boot\)$",
        derive=lambda: lane_view_count("rpi5"),
        describes="views the RPi5 lane compares",
    ),
)


def main() -> int:
    problems = []
    checked = 0
    for claim in CLAIMS:
        path = REPO / claim.path
        if not path.exists():
            problems.append(f"{claim.path}: declared here but not in the tree")
            continue
        text = path.read_text(encoding="ascii")
        expected = claim.derive()
        found = list(claim.pattern.finditer(text))
        if not found:
            # The sentence carrying the number was reworded or moved, which
            # silently retires the claim. Refuse instead: a check that stops
            # examining is the failure this whole file exists to prevent.
            problems.append(
                f"{claim.path}: nothing matches the claim for "
                f"{claim.describes} -- the line was reworded or moved, so the "
                f"number is no longer checked. Pattern: "
                f"{claim.pattern.pattern}")
            continue
        for match in found:
            checked += 1
            stated = int(match.group(1))
            if stated != expected:
                line = text.count("\n", 0, match.start()) + 1
                problems.append(
                    f"{claim.path}:{line}: says {stated} {claim.describes}; "
                    f"the tree has {expected}")
    if problems:
        for problem in problems:
            print(f"  {problem}", file=sys.stderr)
        print(f"FAIL documented-counts: {len(problems)} documented count(s) "
              "do not match the tree", file=sys.stderr)
        return 1
    report_pass("documented-counts",
                f"{checked} number(s) transcribed into documentation match "
                "what the tree they count actually holds",
                counts=checked)
    return 0


if __name__ == "__main__":
    sys.exit(main())
