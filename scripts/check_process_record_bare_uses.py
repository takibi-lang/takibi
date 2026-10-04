#!/usr/bin/env python3
"""The bare process-record lookups left in process.tkb, held to a number.

GitHub issue #693 moves every read and write of a ProcessRecord onto an
authority: the run guard (scheduled_process_record_locked/_of_locked), the
owner (scheduled_process_record_owned), the running evidence
(scheduled_process_record_running), or the diagnostic peek. What is left is
scheduled_process_record_at and scheduled_process_record_of called with a
bare slot or handle, which says nothing about whether the record can be
reaped meanwhile.

That number (counted as lines by grep) went from 81 to 32 in one session, slice by slice, and was
measured each time with an ad hoc grep. Nothing stopped it from climbing back
one convenient lookup at a time. This does: the count must EQUAL the budget
below. Going over is a new bare lookup -- use an authority instead. Going
under is progress -- lower the budget in the same commit, so the gain cannot
be spent later without anyone noticing.

The two accessors' own definitions are not uses; every call is, including
those inside the authority-taking wrappers (they are the mint sites #693
step 7 keeps).

Exit code only (0 = pass, 1 = fail).
"""

import pathlib
import re
import sys

from pass_line import report_pass

PATH = pathlib.Path("kernel/kernel/process.tkb")
BUDGET = 24
CALL_RE = re.compile(r"\bscheduled_process_record_(?:at|of)\s*\(")
DEF_RE = re.compile(r"^(?:private )?fn scheduled_process_record_(?:at|of)\(")


def main() -> int:
    lines = PATH.read_text().splitlines()
    uses = 0
    for line in lines:
        if DEF_RE.match(line):
            continue
        code = line.split("//", 1)[0]
        uses += len(CALL_RE.findall(code))
    if uses > BUDGET:
        print(f"FAIL process-record-bare-uses: {PATH}: {uses} bare "
              f"scheduled_process_record_at/_of call(s), over the budget of "
              f"{BUDGET}; reach the record through the run guard, an owner, "
              f"ProcessRunning or the peek instead (#693)", file=sys.stderr)
        return 1
    if uses < BUDGET:
        print(f"FAIL process-record-bare-uses: {PATH}: {uses} bare "
              f"call(s), under the budget of {BUDGET}; lower BUDGET in "
              f"{__file__} to {uses} in this commit", file=sys.stderr)
        return 1
    report_pass("process-record-bare-uses",
                f"{uses} bare scheduled_process_record_at/_of call(s) in "
                f"{PATH}, equal to its budget, across {len(lines)} lines",
                lines=len(lines), uses=uses)
    return 0


if __name__ == "__main__":
    sys.exit(main())
