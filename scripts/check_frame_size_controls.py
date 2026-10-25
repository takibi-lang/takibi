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
