#!/usr/bin/env python3
"""Controls for the kernel profile folder (GitHub issue #497).

The capture needs a booted kernel; what can be controlled offline is how a
dump becomes folded stacks: samples are parsed and ordered by time, a dump
whose declared count disagrees or whose end line is missing is refused, a
late (masked) sample weighs 1 + skid // period, return addresses are
symbolized at address - 4 and the stack is root-first, EL0 samples are kept
apart from EL1, and the summary's masked weight is what the skids say.
"""

import sys
from pathlib import Path

from pass_line import CaseCount, report_pass

sys.path.insert(0, str(Path(__file__).resolve().parent))
import profile_kernel_session as tool  # noqa: E402

CASES = CaseCount()


def expect(label, ok):
    CASES.note()
    if not ok:
        print(f"FAIL profile-session controls: {label}")
    return ok


class FakeSymbols:
    def __init__(self):
        self.starts = [0x1000, 0x2000, 0x3000]
        self.names = ["leaf_fn", "middle_fn", "root_fn"]

    def name(self, address):
        return tool.Symbols.name(self, address)


DUMP = """noise
profile-session: begin period=1000 depth=16 mode=2 started=1 stopped=2 cntfrq=54000000
profile-session: sample cpu=1 t=20 pid=7 el=1 skid=2500 stop=0 pcs=1010,2008,3004
profile-session: sample cpu=0 t=10 pid=7 el=1 skid=10 stop=0 pcs=1010,2008,3004
profile-session: sample cpu=0 t=30 pid=9 el=0 skid=0 stop=3 pcs=400100
profile-session: core cpu=0 stored=2 lost=0 capacity=24
profile-session: core cpu=1 stored=1 lost=1 capacity=24
profile-session: end samples=3 lost=1
"""


def refused(text):
    try:
        tool.parse_console(text)
    except ValueError:
        return True
    return False


def main():
    ok = True
    period, samples, end = tool.parse_console(DUMP)
    ok &= expect("period and count", period == 1000 and len(samples) == 3)
    ok &= expect("ordered by timestamp", [s["t"] for s in samples] == [0x10, 0x20, 0x30])
    ok &= expect("lost carried", end["lost"] == 1)
    ok &= expect("missing end refused", refused(DUMP.split("profile-session: end")[0]))
    ok &= expect("count mismatch refused",
                 refused(DUMP.replace("end samples=3", "end samples=4")))
    ok &= expect("no begin refused", refused("profile-session: end samples=0 lost=0\n"))
    ok &= expect("late sample weight", tool.weight_of(samples[1], period) == 3)
    stacks, summary = tool.fold(samples, period, FakeSymbols())
    ok &= expect("EL1 stack root first, return address at -4",
                 stacks.get("[el1];root_fn;middle_fn;leaf_fn") == 1 + 3)
    ok &= expect("EL0 kept apart", stacks.get("[el0 pid=9]") == 1)
    ok &= expect("masked weight", summary["masked_weight"] == 2)
    ok &= expect("weights add up",
                 summary["weight"] == 5 and summary["el1_weight"] == 4 and
                 summary["el0_weight"] == 1)
    ok &= expect("inclusive counts each function once per sample",
                 summary["inclusive"]["middle_fn"] == 4)
    if not ok:
        return 1
    report_pass(
        "profile-session controls",
        "a dump parses in time order, a truncated or miscounted dump is "
        "refused, a late sample weighs 1 + skid // period, EL1 stacks fold "
        "root-first with return addresses at -4, EL0 stays apart, and the "
        "masked weight is what the skids say",
        cases=CASES.ran)
    return 0


if __name__ == "__main__":
    sys.exit(main())
