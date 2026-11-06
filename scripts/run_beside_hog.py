#!/usr/bin/env python3
"""GitHub issue #1390: run timing-sensitive controls beside a CPU hog.

slowcheck_run_lane.sh's CPU control assumed a quiet host and failed inside
a loaded allcheck (#1198's land went red on it). A control that reads a
clock, sleeps or sets a timeout has to keep its verdict when the host is
busy, and the place to learn that is before it is accepted, not in a land.

    run_beside_hog.py [--hogs N] [--record] MEMBER...

starts N busy-loop processes (default: half the CPUs, so the shared host
keeps room for other sessions), runs each scripts/MEMBER beside them, and
prints PASS or FAIL with its elapsed time. With --record, each member that
passed gets its row in scripts/timing_controls_hogged.tsv rewritten with
today's date and the sha256 of the file it ran, which
check_timing_controls_hogged.py compares with the file as it is now.
"""
import argparse
import datetime
import hashlib
import multiprocessing
import os
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TABLE = ROOT / "scripts/timing_controls_hogged.tsv"
HEADER = "# member\tsha256\tdate\thogs\n"


def spin():
    while True:
        pass


def file_hash(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def read_table() -> dict[str, tuple[str, str, str]]:
    rows = {}
    if TABLE.is_file():
        for line in TABLE.read_text().splitlines():
            if not line or line.startswith("#"):
                continue
            member, digest, date, hogs = line.split("\t")
            rows[member] = (digest, date, hogs)
    return rows


def write_table(rows: dict[str, tuple[str, str, str]]):
    body = "".join(f"{m}\t{d}\t{t}\t{h}\n" for m, (d, t, h) in sorted(rows.items()))
    TABLE.write_text(HEADER + body)


def run(member: str) -> tuple[bool, float, str]:
    runner = "bash" if member.endswith(".sh") else sys.executable
    started = time.monotonic()
    try:
        # The member under test is not yet recorded; a member that itself
        # runs check_timing_controls_hogged.py (relayout-fragility runs every
        # check_*) must not fail for its own missing row.
        env = dict(os.environ, TAKIBI_HOG_MEMBER=member)
        done = subprocess.run([runner, f"scripts/{member}"], cwd=ROOT, text=True, env=env,
                              errors="replace", stdout=subprocess.PIPE,
                              stderr=subprocess.STDOUT, timeout=900)
        ok, out = done.returncode == 0, done.stdout
    except subprocess.TimeoutExpired:
        ok, out = False, "timeout after 900 s"
    return ok, time.monotonic() - started, out


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--hogs", type=int, default=max(1, (os.cpu_count() or 2) // 2))
    parser.add_argument("--record", action="store_true")
    parser.add_argument("members", nargs="+")
    options = parser.parse_args()
    hogs = [multiprocessing.Process(target=spin, daemon=True) for _ in range(options.hogs)]
    for hog in hogs:
        hog.start()
    results = []
    try:
        for member in options.members:
            ok, elapsed, out = run(member)
            results.append((member, ok))
            print(f"{'PASS' if ok else 'FAIL'}  {member} beside {options.hogs} hogs ({elapsed:.1f} s)")
            if not ok:
                print("\n".join("    " + l for l in out.splitlines()[-15:]))
    finally:
        for hog in hogs:
            hog.terminate()
        for hog in hogs:
            hog.join()
    if options.record:
        rows = read_table()
        today = datetime.date.today().isoformat()
        for member, ok in results:
            if ok:
                rows[member] = (file_hash(ROOT / "scripts" / member), today, str(options.hogs))
        write_table(rows)
    return 0 if all(ok for _, ok in results) else 1


if __name__ == "__main__":
    sys.exit(main())
