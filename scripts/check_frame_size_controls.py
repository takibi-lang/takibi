#!/usr/bin/env python3
"""Negative controls for buildcheck_frame_size.py (GitHub issue #1081)."""
import sys

sys.path.insert(0, __file__.rsplit("/", 1)[0])
from buildcheck_frame_size import frames, problems  # noqa: E402
from pass_line import report_pass  # noqa: E402

LISTING = """
0000000000000000 <small>:
       0:	stp	x29, x30, [sp, #-32]!
       4:	mov	x29, sp
0000000000000010 <plan_holder>:
      10:	stp	x29, x30, [sp, #-96]!
      14:	sub	sp, sp, #0x1, lsl #12
      18:	sub	sp, sp, #0x6a0
0000000000000020 <budgeted>:
      20:	stp	x29, x30, [sp, #-16]!
      24:	sub	sp, sp, #3000
"""


def main():
    measured = frames(LISTING)
    checks = []
    checks.append(("prologue parse",
                   measured == {"small": 32, "plan_holder": 96 + 4096 + 0x6a0,
                                "budgeted": 3016}))
    # The #1081 shape: a 6 KiB frame with no budget is refused.
    found = problems(measured, budget={"budgeted": 3016}, ceiling=2048)
    checks.append(("unbudgeted large frame refused",
                   any(p.startswith("plan_holder:") for p in found)))
    checks.append(("budgeted frame within budget passes",
                   not any(p.startswith("budgeted:") for p in found)))
    found = problems(measured, budget={"budgeted": 3000}, ceiling=2048)
    checks.append(("budgeted frame over its budget refused",
                   any("budgeted: frame 3016" in p for p in found)))
    found = problems({"small": 32}, budget={"small": 3000, "gone": 4000},
                     ceiling=2048)
    checks.append(("stale entries refused",
                   any("small: frame 32 B is within" in p for p in found) and
                   any("gone: budget entry" in p for p in found)))
    checks.append(("small frame passes",
                   problems({"small": 32}, budget={}, ceiling=2048) == []))
    # LLVM 19 prints hexadecimal immediates by default. The saved pair is
    # part of the frame even when a later sub alone fits the ceiling.
    for pair, sub in [("48", "2048"), ("0x30", "0x800")]:
        listing = ("0000000000000000 <above_ceiling>:\n"
                   f"       0:\tstp\tx29, x30, [sp, #-{pair}]!\n"
                   f"       4:\tsub\tsp, sp, #{sub}\n")
        measured = frames(listing)
        checks.append((f"{pair} pair allocation accumulates",
                       measured == {"above_ceiling": 2096}))
        checks.append((f"{pair} pair crosses ceiling",
                       any("frame 2096 B exceeds the 2048 B ceiling" in p
                           for p in problems(measured, budget={}))))
        checks.append((f"{pair} pair crosses recorded budget",
                       any("frame 2096 B exceeds its recorded budget 2048 B" in p
                           for p in problems(measured,
                                             budget={"above_ceiling": 2048}))))
    valid = frames("0000000000000000 <at_ceiling>:\n"
                   "       0:\tstp\tx29, x30, [sp, #-0x30]!\n"
                   "       4:\tsub\tsp, sp, #0x7d0\n")
    checks.append(("hexadecimal pair at ceiling passes",
                   valid == {"at_ceiling": 2048} and
                   problems(valid, budget={}) == []))
    checks.append(("hexadecimal pair alone is measured",
                   frames("0000000000000000 <pair_only>:\n"
                          "       0:\tstp\tx29, x30, [sp, #-0x20]!\n") ==
                   {"pair_only": 32}))
    bad = [name for name, ok in checks if not ok]
    if bad:
        for name in bad:
            print(f"FAIL frame-size controls: {name}", file=sys.stderr)
        return 1
    report_pass("frame-size controls",
                f"{len(checks)} controls: the #1081 frame and an over-budget one are "
                f"refused, stale entries are refused, small frames pass",
                controls=len(checks))
    return 0


if __name__ == "__main__":
    sys.exit(main())
