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


def pool_line(contended):
    return (f"RECORDED pool lock wait: process={contended} "
            f"fd_block=0 tcp_retx=0")


def cost_line(plain, counted):
    return (f"RECORDED pool lock wait cost: pairs=4096 plain={plain} "
            f"counted={counted} freq=54000000")


COST = cost_line(5417, 5440)
QUIET = [page_line(534), pool_line(2000), COST]
LIMIT_TICKS = int(3 * 15.2e-6 * 54000000)  # 2462 ticks at 54 MHz
POOL_LIMIT = 3 * v.BASELINE_680  # 8217 acquires

CASES = (
    # name, lines, issue that must be named (None: must pass)
    ("baseline passes", QUIET, None),
    ("timestamped duplicate lines pass",
     QUIET + ["[000004.1] " + l for l in QUIET], None),
    ("#812 just under", [page_line(LIMIT_TICKS), pool_line(2000), COST], None),
    ("#812 fires", [page_line(LIMIT_TICKS + 2), pool_line(2000), COST], 812),
    ("#812 missing", [pool_line(2000), COST], 812),
    ("#812 two different lines",
     [page_line(534), page_line(535), pool_line(2000), COST], 812),
    ("#680 just under", [page_line(534), pool_line(POOL_LIMIT), COST], None),
    ("#680 fires", [page_line(534),
                    pool_line(POOL_LIMIT + 1), COST], 680),
    ("#680 missing", [page_line(534), COST], 680),
    ("#680 old acquires/contended format", [page_line(534),
                              "RECORDED pool lock wait: process=10/0 tcp_retx=0/0", COST], 680),
    # 1 ns at 54 MHz over 4096 pairs is 221.2 ticks.
    ("#953 cost just under", [page_line(534), pool_line(2000),
                              cost_line(5417, 5417 + 221)], None),
    ("#953 cost over", [page_line(534), pool_line(2000),
                        cost_line(5417, 5417 + 222)], 953),
    ("#953 cost missing", [page_line(534), pool_line(2000)], 953),
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
        elif not any(w in text for w in ("measurement", "reopen", "per uncontended lock pair")):
            failures.append(f"{name}: failure says neither why nor what to do for #{issue}")
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
