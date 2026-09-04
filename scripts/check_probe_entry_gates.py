#!/usr/bin/env python3
"""A two-core probe's entry gate must wait on a MONOTONIC value, not a level.

Every probe in `kernel/kernel/*_contention_evidence.tkb` (and the refcount
probe living in `kernel/kernel/fd_table.tkb`) has the same shape: core 0 arms
the probe and then waits for the second core to have arrived before it starts
measuring. What it waits ON is the part that keeps going wrong.

`<probe>_probe_active` is a LEVEL. The secondary raises it on entry and clears
it on the way out, so polling it asks "is that core inside RIGHT NOW", and the
question the gate needs answered is "was it ever". A secondary that entered,
did its work and left before core 0 got a slice reads exactly like a secondary
that never arrived -- and core 0 then reports `secondary-never-entered` about a
core that did everything asked of it. GitHub issue #510 is that bug, measured
as `pid contention counts: primary=0 secondary=2048`: every round done, and the
probe refusing to start.

The fix is always the same shape: gate on something that only ever GROWS -- a
completed-cycle count, or an entry count for probes whose cycle count cannot be
used because it only advances after a rendezvous with core 0 (gating on that
would deadlock: core 0 would be waiting for a number only core 0 can unblock).

So the rule this enforces is narrow and mechanical: an entry gate may not read
`*_active_address()`. Waiting for `active == 0` is a different thing and stays
allowed -- that is the settle wait, which asks "has it provably LEFT" before
reading accounting the other core could still be changing, and a level is
exactly right for that.

Exit code only (0 = pass, 1 = fail).
"""

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
KERNEL = ROOT / "kernel"

# A gate is the bounded wait that decides whether the second core arrived. It
# is recognised by the loop variable every one of these probes uses.
GATE_START = re.compile(r"let mut (entered|started): bool = false;")
GATE_END = re.compile(r"^\s*\}\s*$")
ACTIVE_READ = re.compile(r"_active_address\(\)")
# `active == 0` inside a gate would be a settle wait, not an arrival gate.
SETTLE = re.compile(r"==\s*0")

# (file, gate) -> why this gate may read a level. Empty on purpose: every
# probe in the tree gates on a monotonic value today. An entry here is a
# claim a reviewer can disagree with, which is what the other check scripts
# in this directory use their own tables for.
ALLOWED: dict[tuple[str, str], str] = {}


def gates(path: pathlib.Path):
    """Yield (line number, gate body) for each arrival gate in the file."""
    lines = path.read_text().splitlines()
    for index, line in enumerate(lines):
        if not GATE_START.search(line):
            continue
        body = []
        for follow in lines[index + 1:index + 24]:
            body.append(follow)
            if GATE_END.match(follow) and len(body) > 2:
                break
        yield index + 1, "\n".join(body)


def main() -> int:
    targets = sorted(KERNEL.glob("kernel/*_contention_evidence.tkb"))
    targets.append(KERNEL / "kernel" / "fd_table.tkb")
    problems = []
    checked = 0
    for path in targets:
        if not path.exists():
            continue
        relative = str(path.relative_to(ROOT))
        for line_number, body in gates(path):
            checked += 1
            if not ACTIVE_READ.search(body):
                continue
            if SETTLE.search(body):
                continue
            key = (relative, str(line_number))
            if key in ALLOWED:
                continue
            problems.append(
                f"{relative}:{line_number}: an arrival gate waits on "
                f"`_active_address()`, which the secondary clears on its way "
                f"out. Wait on a count that only grows (GitHub issue #510)."
            )

    if problems:
        print("ERROR: two-core probe entry gates wait on a level:")
        for problem in problems:
            print(f"  {problem}")
        return 1
    print(f"PASS probe-entry-gates: {checked} arrival gate(s) across "
          f"{len(targets)} probe file(s) wait on a monotonic value")
    return 0


if __name__ == "__main__":
    sys.exit(main())
