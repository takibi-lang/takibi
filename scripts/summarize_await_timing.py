#!/usr/bin/env python3
"""Summarize one aggregate's observed await margins without changing verdicts.

Only recorders using AwaitTiming contribute; an empty directory is no evidence,
not a claim that every console driver has comfortable margins.
"""

import json
from pathlib import Path
import sys


def main():
    directory = Path(sys.argv[1])
    captures = observed = tight = missing = 0
    invalid = False
    print("await margins (instrumented drivers only):")
    for path in sorted(directory.glob("*.jsonl")):
        try:
            rows = [json.loads(line) for line in path.read_text().splitlines() if line.strip()]
            arrived = [row for row in rows if row["status"] == "arrived"]
            absent = [row for row in rows if row["status"] == "not-arrived"]
            if any(row["status"] not in ("arrived", "not-arrived") for row in rows):
                raise ValueError("unknown arrival status")
            slow = [row for row in arrived if row["fraction"] > 0.5]
            if arrived:
                worst = max(arrived, key=lambda row: row["fraction"])
                detail = (f'{worst["elapsed_seconds"]:.3f}s/{worst["timeout_seconds"]:.3f}s '
                          f'({worst["fraction"]:.1%}) at {worst["await"]}')
            else:
                detail = "no arrivals recorded"
            if rows:
                first = rows[0]
                print(f'  {first["lane"]}: {first["driver"]} [{first["budget_origin"]}]: {detail}; '
                      f'{len(slow)} over half budget, {len(absent)} not arrived')
                print(f'    artifact: {first["source"] or path}')
                if absent:
                    print("    not arrived: " + ", ".join(row["await"] for row in absent))
                captures += 1
            else:
                print(f"  {path.name}: no observations recorded")
            observed += len(arrived)
            tight += len(slow)
            missing += len(absent)
        except (OSError, ValueError, KeyError, TypeError) as error:
            print(f"RECORDED await summary unavailable: {path}: {error}")
            invalid = True
    print(f"await observations: {captures} captures, {observed} arrivals, "
          f"{tight} over half budget, {missing} not arrived")
    return int(invalid)


if __name__ == "__main__":
    sys.exit(main())
