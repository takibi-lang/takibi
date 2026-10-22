#!/usr/bin/env python3
"""Refuse a passing lane that left a failure archive behind (GitHub issue #883).

Since #877 every lane runner archives a failing capture to
<root>/<lane>-failures/<stamp>/ through scripts/archive_kernel_failure.sh.
The converse was unchecked: a child that is MEANT to fail (a counterfactual,
a scalar control) and archives anyway makes a passing lane leave a failure
archive, which reads later as a real failure. #877 found two such children
by hand.

scripts/run_lane.sh gives each lane run an id (TAKIBI_LANE_RUN_ID), the
archiver writes it into the MANIFEST as `lane-run:`, and after a passing lane
run_lane.sh calls this with that id. Attribution is by id rather than by
comparing directory listings before and after, because allcheck runs lanes
side by side in one worktree: a neighbour's real failure archived during this
lane's run is not this lane's archive, and a listing diff would blame it.

An archive a passing lane makes on purpose carries `expected:` (the
archiver's TAKIBI_ARCHIVE_EXPECTED) naming why: the race-window reverted
kernel, which must fail and whose capture is the evidence (#665), and the
armed churn run recorded but not gated on QEMU (#692). Those are listed,
not refused.

Usage: lane_new_archives.py RUN_ID ROOT [ROOT...]
Exit 0 when no unexpected archive carries RUN_ID, 1 otherwise.
"""
from __future__ import annotations

import sys
from pathlib import Path

# <root>/<lane>-failures/<stamp>/MANIFEST, and one level deeper for an
# artifact directory nested under the root (a repeated lane's sample).
PATTERNS = ("*-failures/*/MANIFEST", "*/*-failures/*/MANIFEST")


def manifest_fields(path: Path) -> dict[str, str]:
    fields: dict[str, str] = {}
    try:
        text = path.read_text(errors="replace")
    except OSError:
        return fields
    for line in text.splitlines():
        key, sep, value = line.partition(": ")
        if sep and key in ("lane-run", "expected", "lane", "reason") and key not in fields:
            fields[key] = value.strip()
    return fields


def scan(run_id: str, roots: list[Path]) -> tuple[list[Path], list[tuple[Path, str]]]:
    unexpected: list[Path] = []
    expected: list[tuple[Path, str]] = []
    seen: set[Path] = set()
    for root in roots:
        if not root.is_dir():
            continue
        for pattern in PATTERNS:
            for manifest in sorted(root.glob(pattern)):
                real = manifest.resolve()
                if real in seen:
                    continue
                seen.add(real)
                fields = manifest_fields(manifest)
                if fields.get("lane-run") != run_id:
                    continue
                why = fields.get("expected", "")
                if why and why != "no":
                    expected.append((manifest.parent, why))
                else:
                    unexpected.append(manifest.parent)
    return unexpected, expected


def main(argv: list[str]) -> int:
    if len(argv) < 3 or not argv[1] or argv[1] == "none":
        print("usage: lane_new_archives.py RUN_ID ROOT [ROOT...]", file=sys.stderr)
        return 2
    run_id = argv[1]
    unexpected, expected = scan(run_id, [Path(p) for p in argv[2:]])
    for archive, why in expected:
        print(f"NOTE {run_id}: expected failure archive {archive} ({why})")
    if unexpected:
        print(f"FAIL {run_id}: the lane passed but left {len(unexpected)} "
              "failure archive(s); a child meant to fail must not archive (#883):",
              file=sys.stderr)
        for archive in unexpected:
            print(f"  {archive}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
