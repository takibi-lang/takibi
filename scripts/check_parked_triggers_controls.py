#!/usr/bin/env python3
"""Controls for scripts/validate_parked_triggers.py (GitHub issue #953).

The RPi5 log passes today, so each trigger needs a failing control: a
planted log whose measurement passes its threshold must fail naming the
issue and saying to reopen it, and a log missing the measurement must fail
too. Runs in-process (no child), over planted lines.
"""

import sys

from pass_line import report_pass
import validate_parked_triggers as v


def page_line(max_ticks):
    return (f"RECORDED page run allocator: calls=114 visits=3683 ticks=9249 "
            f"max_ticks={max_ticks} freq=54000000")


def pool_line(acquires, contended):
    return (f"RECORDED pool lock wait: process={acquires}/{contended} "
            f"fd_block=10/0 tcp_retx=0/0")


QUIET = [page_line(534), pool_line(100000, 0)]
LIMIT_TICKS = int(3 * 15.2e-6 * 54000000)  # 2462 ticks at 54 MHz
POOL_LIMIT = 3 * v.BASELINE_680

CASES = (
    # name, lines, issue that must be named (None: must pass)
    ("baseline passes", QUIET, None),
    ("timestamped duplicate lines pass",
     QUIET + ["[000004.1] " + l for l in QUIET], None),
    ("#812 just under", [page_line(LIMIT_TICKS), pool_line(100000, 0)], None),
    ("#812 fires", [page_line(LIMIT_TICKS + 2), pool_line(100000, 0)], 812),
    ("#812 missing", [pool_line(100000, 0)], 812),
    ("#812 two different lines",
     [page_line(534), page_line(535), pool_line(100000, 0)], 812),
    ("#680 just under", [page_line(534), pool_line(100000, int(POOL_LIMIT * 100000))], None),
    ("#680 fires", [page_line(534),
                    pool_line(100000, int(POOL_LIMIT * 100000) + 2)], 680),
    ("#680 missing", [page_line(534)], 680),
    ("#680 nothing counted", [page_line(534),
                              "RECORDED pool lock wait: process=0/0 tcp_retx=0/0"], 680),
)


def main():
    failures = []
    for name, lines, issue in CASES:
        found, judged = v.evaluate(lines)
        text = "\n".join(found)
        if judged != len(v.TRIGGERS):
            failures.append(f"{name}: judged {judged} trigger(s)")
        if issue is None:
            if found:
                failures.append(f"{name}: expected pass, got {text}")
            continue
        if f"#{issue}" not in text:
            failures.append(f"{name}: expected a failure naming #{issue}, got {text!r}")
        elif "measurement" not in text and "reopen" not in text:
            failures.append(f"{name}: failure does not say to reopen #{issue}")
        others = [f for f in found if f"#{issue}" not in f]
        if others:
            failures.append(f"{name}: unrelated failures {others}")
    if failures:
        for failure in failures:
            print(f"FAIL parked-triggers-controls: {failure}", file=sys.stderr)
        return 1
    report_pass("parked-triggers-controls",
                f"{len(CASES)} planted logs judged as expected",
                cases=len(CASES))
    return 0


if __name__ == "__main__":
    sys.exit(main())
