#!/usr/bin/env python3
"""Turn one allcheck run's lane receipts into a duration summary.

The allcheck latency work took the wall time from 93.6s to 51.5s, and finding
the critical path meant several ad hoc timing runs and reading interleaved
parallel output by hand. That is the part this replaces: `scripts/run_lane.sh`
records when each lane started, finished, and with what status, and this reads
the records back (GitHub issue #471).

Two numbers matter and they are not the same one.

  LONGEST is the lane that took the most time. It is the obvious number and
  it is often not the actionable one: a long lane that runs beside an equally
  long lane costs nothing to shorten.

  TAIL is how long the run spent waiting on ONE lane after every other lane
  had finished. That is exactly what allcheck would save if that lane got
  faster, so it is the number to act on, and it names its own lane.

A lane with a start stamp and no record did not finish -- it is reported as
incomplete rather than dropped, because a lane that died is the one a reader
is most likely to be looking for.

What this does NOT establish is that the set of lanes is COMPLETE. It counts
what it was given, so a lane that silently stopped recording makes the summary
shorter rather than wrong-looking. The lane count is printed for that reason:
a drop shows up in a diff of two runs, which is the same way a duration
regression does. Asserting the set would mean naming every leaf lane in a
second place, and a list like that goes stale in the direction that reports
success.

Usage: summarize_lane_timing.py [timing_dir]
Exits nonzero when there is nothing to summarize, which is a real answer: it
means the run produced no receipts at all.
"""

from __future__ import annotations

import json
import pathlib
import sys

DEFAULT_DIR = pathlib.Path("_build/lane-timing")


def load(directory: pathlib.Path):
    """Return (finished records, names of lanes that started and did not)."""
    records = []
    for path in sorted(directory.glob("*.jsonl")):
        for number, line in enumerate(path.read_text().splitlines(), 1):
            line = line.strip()
            if not line:
                continue
            try:
                record = json.loads(line)
            except json.JSONDecodeError:
                print(f"warning: {path.name}:{number} is not JSON, ignored",
                      file=sys.stderr)
                continue
            records.append(record)
    incomplete = sorted(path.stem for path in directory.glob("*.start"))
    return records, incomplete


def summarize(records, incomplete) -> int:
    ordered = sorted(records, key=lambda r: r["elapsed"], reverse=True)
    width = max(len(r["lane"]) for r in ordered)

    print("lane durations, longest first:")
    for record in ordered:
        verdict = "ok" if record["status"] == 0 else f"FAILED ({record['status']})"
        print(f"  {record['lane']:<{width}}  {record['elapsed']:7.1f}s  {verdict}")
    for lane in incomplete:
        print(f"  {lane:<{width}}  {'--':>7}   did not finish")

    first_start = min(r["start"] for r in records)
    last_finish = max(r["finish"] for r in records)
    span = last_finish - first_start
    longest = ordered[0]

    # The tail is measured against the finish of every OTHER lane, so a lane
    # that merely started late does not look like the critical path.
    last = max(records, key=lambda r: r["finish"])
    others = [r["finish"] for r in records if r is not last]
    tail = last["finish"] - max(others) if others else last["elapsed"]

    print(f"lanes:   {len(records):7d}   summarized"
          + (f", {len(incomplete)} unfinished" if incomplete else ""))
    print(f"span:    {span:7.1f}s  from the first lane's start to the last "
          "lane's finish")
    print(f"longest: {longest['elapsed']:7.1f}s  {longest['lane']}")
    print(f"tail:    {tail:7.1f}s  {last['lane']} ran alone after every other "
          "lane had finished")
    if incomplete:
        print(f"incomplete: {len(incomplete)} lane(s) started and left no "
              "record: " + ", ".join(incomplete))
    return 0


def main() -> int:
    directory = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_DIR
    if not directory.is_dir():
        print(f"ERROR lane-timing: {directory} does not exist, so no lane "
              "recorded a duration", file=sys.stderr)
        return 1
    records, incomplete = load(directory)
    if not records:
        # A summary of nothing would read as "every lane was instant".
        print(f"ERROR lane-timing: {directory} holds no lane records"
              + (f" ({len(incomplete)} lane(s) started and did not finish: "
                 + ", ".join(incomplete) + ")" if incomplete else ""),
              file=sys.stderr)
        return 1
    return summarize(records, incomplete)


if __name__ == "__main__":
    sys.exit(main())
