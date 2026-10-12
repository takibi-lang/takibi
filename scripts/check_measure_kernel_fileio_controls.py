#!/usr/bin/env python3
"""Controls for the file-I/O workload timer (GitHub issue #765).

The timer itself needs a booted shell kernel; what can be controlled offline
is the part that turns console text into numbers: one `real` line per
workload, minutes folded into seconds, a missing or doubled `real` line
refused rather than read as zero, and a comparison that prints the base tree
as +0.0% and a slower tree as a positive delta.
"""

import contextlib
import io
import json
import sys
import tempfile
from pathlib import Path

from pass_line import CaseCount, report_pass

sys.path.insert(0, str(Path(__file__).resolve().parent))
import measure_kernel_fileio as tool  # noqa: E402

CASES = CaseCount()


def expect(label, ok):
    CASES.note()
    if not ok:
        print(f"FAIL fileio controls: {label}")
        return False
    return True


def refused(text):
    try:
        tool.parse_real(text)
    except RuntimeError:
        return True
    return False


def main():
    ok = True
    ok &= expect("seconds-only real line",
                 tool.parse_real("x\nreal\t0m 0.35s\nuser\t0m 0.00s\n") == 0.35)
    ok &= expect("minutes fold into seconds",
                 abs(tool.parse_real("real\t3m 32.91s\n") - 212.91) < 1e-9)
    ok &= expect("no real line is refused", refused("dd: error\n"))
    ok &= expect("two real lines are refused",
                 refused("real\t0m 1.00s\nreal\t0m 2.00s\n"))
    summary = tool.summarize([
        {"workload": "w", "seconds": 1.0}, {"workload": "w", "seconds": 3.0},
        {"workload": "w", "seconds": 2.0}])
    ok &= expect("summary median/min/max/n",
                 summary["w"] == {"n": 3, "median": 2.0, "min": 1.0, "max": 3.0})
    with tempfile.TemporaryDirectory() as directory:
        paths = []
        for label, median in (("base", 2.0), ("slow", 2.2)):
            path = Path(directory) / f"{label}.json"
            path.write_text(json.dumps({"label": label, "summary": {
                "w": {"n": 1, "median": median, "min": median, "max": median}}}))
            paths.append(str(path))
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            tool.compare(paths)
        text = out.getvalue()
        ok &= expect("compare shows base +0.0% and slow +10.0%",
                     "+0.0%" in text and "+10.0%" in text)
    if not ok:
        return 1
    report_pass(
        "fileio controls",
        "time's real line is parsed with minutes folded in, a missing or "
        "doubled real line is refused, the summary keeps median and spread, "
        "and a comparison reports deltas against the first tree",
        cases=CASES.ran)
    return 0


if __name__ == "__main__":
    sys.exit(main())
