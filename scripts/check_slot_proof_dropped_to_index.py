#!/usr/bin/env python3
"""Dropping a slot's liveness proof to a bare INDEX is declared, with a reason.

GitHub issue #569. `intrusive_pool_probe_slot` mints an `IntrusiveSlotView`
that says a slot is occupied. `intrusive_view_drop` gives it back. What a
caller keeps after that decides whether its answer survives the drop:

  - keep the GENERATION (`intrusive_view_generation`) and the answer is still
    checkable -- a later lookup with that generation catches a slot that was
    freed and reused, on `RECYCLED HANDLE READS`;
  - keep only the SLOT ADDRESS and the answer is a snapshot with nothing left
    to notice it going stale. The next lookup of that address is a second,
    independent probe, and a free in between is invisible to the type system.

That second shape is what #569 was. `scheduled_process_live_pool_slot_from`
probed under the pool lock, saw Live, dropped the view, and handed back a bare
slot; the walk then looked that slot up again and the pool answered NoPayload
about three `make cicheck` runs in eight. The walk skipped the slot correctly
-- what was wrong was that a counter called it a missing record, and a view
asserted that counter at zero.

The declared cursor, predicate and scalar-copy sites answer questions that
are inherently snapshots. The point is not to forbid the shape, it is that a NEW one is a
decision somebody made rather than a line somebody wrote. That is the same
argument scripts/check_liveness_proof_escapes.py makes about a DIFFERENT
escape -- that one is about a payload POINTER outliving its proof
(`intrusive_pool_payload_unproven_of`), this one is about an INDEX outliving
it, and neither covers the other.

Exit code only (0 = pass, 1 = fail).
"""

import pathlib
import re
import sys

from pass_line import report_pass

ROOT = pathlib.Path(__file__).resolve().parents[1]
KERNEL = ROOT / "kernel"
# The file that defines drop, probe and generation: it names them without
# being a caller in the sense this checks.
DEFINING = "lib/intrusive_pool.tkb"

# Since GitHub issue #745 the kernel's pool is the built-in RegionPool: a
# Held record's view is dropped with region_held_view_drop, and a caller
# that keeps the generation keeps the RegionHeld reference
# (region_held_view_ref), which a later probe re-checks.
DROP = "region_held_view_drop("
GENERATION = "region_held_view_ref("

FUNCTION_RE = re.compile(r"^(?:private )?(?:inline |noinline )?fn ([A-Za-z_0-9]+)")

# Functions that drop the proof and keep only a slot address, and why that is
# the right answer there. Each entry is a claim that can stop being true.
INDEX_ONLY_ALLOWED = {
    "scheduled_process_scalar_snapshot":
        "a value snapshot, not an index or payload pointer: it copies pid, "
        "state, wait reason, saved frame address and stack-run address before "
        "consuming its pool view. Saved addresses do not grant access rights; "
        "the frame/stack mints separately validate them",
    "kernel_process_protocol_observe":
        "a value snapshot for the protocol trace: it copies pid, state, stack "
        "owner, wait reason and the parent handle under the pool lock, then "
        "observes after the lock is gone; it keeps no index",
    "pool_walk_read":
        "the walk probe's stamp read: a value, read under the pool lock",
    "kernel_stack_run_depth":
        "a value snapshot (#672): it borrows the record's stack-run "
        "permission under the pool lock, measures the stack's poison depth "
        "and returns that count; it hands on no index or pointer",
}

# These consume a stored pool proof after the compiler checked loan_transfer.
# They return no index or pointer. Keep them separate from cursor snapshots.
TRANSFER_RELEASES = {
    "scheduled_process_locked_view_drop": "ProcessRecordLockedView",
    "scheduled_process_current_view_drop": "ProcessRecordCurrentView",
    "scheduled_process_owned_view_drop": "ProcessRecordOwnedView",
}


def strip_comment(line: str) -> str:
    return line.split("//", 1)[0]


def bodies_of(lines):
    starts = [(index, match.group(1))
              for index, line in enumerate(lines)
              if (match := FUNCTION_RE.match(line))]
    spans = {}
    for position, (index, name) in enumerate(starts):
        end = starts[position + 1][0] if position + 1 < len(starts) else len(lines)
        spans[name] = (index, end, "\n".join(lines[index:end]))
    return spans


def code_of(body: str) -> str:
    """Comments stripped per LINE, so prose naming a call is not a call."""
    return "\n".join(strip_comment(line) for line in body.splitlines())


def main() -> int:
    problems = []
    droppers = set()
    index_only = set()
    transfer_releases = set()
    for path in sorted(KERNEL.rglob("*.tkb")):
        relative = str(path.relative_to(KERNEL))
        if relative == DEFINING:
            continue
        lines = path.read_text(encoding="ascii").splitlines()
        if not any(DROP in strip_comment(line) for line in lines):
            continue
        spans = bodies_of(lines)
        for index, line in enumerate(lines):
            if DROP not in strip_comment(line):
                continue
            holder = None
            for name, (start, end, body) in spans.items():
                if start <= index < end:
                    holder = (name, body)
                    break
            if holder is None:
                problems.append(
                    f"kernel/{relative}:{index + 1} drops a slot view outside "
                    f"any function, so nothing can say what it kept")
                continue
            name, body = holder
            droppers.add(name)
            code = code_of(body)
            if name in TRANSFER_RELEASES:
                header = code.split("{", 1)[0]
                expected = "source: sink " + TRANSFER_RELEASES[name] + "["
                if expected not in header or "->" in header or re.search(r"\breturn\s+[^;]", code):
                    problems.append(f"{name} must consume its stored proof and return no value")
                transfer_releases.add(name)
                continue
            if GENERATION in code:
                continue
            index_only.add(name)
            if name in INDEX_ONLY_ALLOWED:
                continue
            problems.append(
                f"kernel/{relative}:{index + 1} drops a slot view in {name} "
                f"and keeps no generation, so what it hands on is a bare slot "
                f"index whose occupancy nothing can re-check. That is GitHub "
                f"issue #569's shape. Carry {GENERATION[:-1]} forward, or add "
                f"{name} to INDEX_ONLY_ALLOWED in this script with the reason "
                f"its answer is meant to be a snapshot")

    for name in sorted(TRANSFER_RELEASES.keys() - transfer_releases):
        problems.append(f"{name} no longer releases a transferred proof; remove its declaration")
    for name in sorted(INDEX_ONLY_ALLOWED):
        if name not in droppers:
            problems.append(
                f"{name} is declared as dropping a slot view to a bare index "
                f"and no longer drops one: remove the entry")
        elif name not in index_only:
            problems.append(
                f"{name} is declared as keeping no generation and now keeps "
                f"one: remove the entry, the declaration is what would hide "
                f"it going back")

    if problems:
        for problem in problems:
            print(f"ERROR\tslot-proof-to-index: {problem}")
        print(f"FAIL slot-proof-to-index: {len(problems)} slot view(s) are "
              f"dropped to an index nothing can re-check")
        return 1
    report_pass("slot-proof-to-index",
                f"{len(droppers)} function(s) drop a slot view; "
                f"{len(transfer_releases)} consume a transferred proof, "
                f"{len(droppers) - len(index_only) - len(transfer_releases)} carry the generation "
                f"forward and {len(INDEX_ONLY_ALLOWED)} are declared as "
                f"answering a snapshot",
                droppers=len(droppers))
    return 0


if __name__ == "__main__":
    sys.exit(main())
