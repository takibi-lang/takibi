#!/usr/bin/env python3
"""Controls of scripts/run_kernel_load.py's reading of a load transcript.

GitHub issue #1178: stress-ng exits 0 when it skips a stressor, so a skipped
phase read as a pass. #1158: one table per program, Takibi beside Linux, and a
Linux column read from a transcript carries no wall time.
"""

import argparse
import sys

from pass_line import report_pass
from run_kernel_load import (read_reference_text, series_section, PHASES)

# A str: the log-expectation check reads bytes literals as lines to wait for.
SKIPPING = ("\nload: linux-kernel 6.12.0\nload: begin exec\n"
            "stress-ng: info:  [12] skipped: 4: exec (4)\n"
            "load: end exec status=0\n"
            "load: begin fork\n"
            "stress-ng: info:  [13] skipped: 0\n"
            "stress-ng: metrc: [13] fork 100 10.00 1.00 2.00 10.00 33.33\n"
            "load: end fork status=0\n").encode("ascii")


def main():
    record = read_reference_text(SKIPPING)
    if not record["exec"].get("skipped"):
        sys.exit("FAIL run-kernel-load-controls: a skipped stressor read as run")
    if record["fork"].get("skipped"):
        sys.exit("FAIL run-kernel-load-controls: 'skipped: 0' read as a skip")
    if record["fork"].get("bogo_ops") != 100 or record["__kernel__"] != "6.12.0":
        sys.exit(f"FAIL run-kernel-load-controls: transcript misread: {record}")
    args = argparse.Namespace(seconds=1, jobs=2, loops=3, phases=["fork"])
    takibi = {"fork": {"status": 0, "host_seconds": 1.5}}
    text = series_section("2026-10-31", "qemu", "abc", args, takibi, record, None)
    for needed in ("## 2026-10-31 qemu", "| | Takibi | Linux |", "| status | 0 | 0 |",
                   "| wall s (host clock) | 1.50 | - |", "0 (skipped)", "6.12.0"):
        if needed not in text:
            sys.exit(f"FAIL run-kernel-load-controls: {needed!r} not in the table")
    if text.count("### ") != len(PHASES) or not text.isascii():
        sys.exit("FAIL run-kernel-load-controls: not one ASCII table per program")
    none = series_section("2026-10-31", "rpi5", "abc", args, takibi, "no run yet", "hung")
    if "no column (no run yet)" not in none or "FAILED: hung" not in none:
        sys.exit("FAIL run-kernel-load-controls: a missing column or failure went unsaid")
    report_pass("run-kernel-load-controls", "skips, Linux transcripts and series tables read as meant",
                tables=text.count("### "))


if __name__ == "__main__":
    main()
