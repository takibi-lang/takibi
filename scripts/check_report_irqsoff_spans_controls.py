#!/usr/bin/env python3
"""Controls for scripts/report_irqsoff_spans.py (GitHub issue #958).

In process, over planted boot lines and a fake symbol table: the report
folds each closing chain past the lock wrappers to its class, merges cores
keeping the longest span, survives dmesg timestamps and repeated replays,
and fails when the core line is missing, malformed, doubled with different
numbers, or a class line has no core line. #1110: a DELIBERATE class (the
#829 peer-sleep span) is printed as excluded, not as a lock class; a near
name is not excluded; every DELIBERATE name is still a kernel fn. #1093:
with judging on, a class over 3x its baseline fails and one under passes,
a class without a baseline is reported and not judged, a deliberate span is
never judged, every BASELINE_RPI5_US name is still a kernel fn, and only
the RPi5 runner passes --judge.
"""

import contextlib
import io
import pathlib
import re
import sys

from pass_line import report_pass
import report_irqsoff_spans as r


class FakeSymbols:
    TABLE = {0x1000: "mutex_irq_restore", 0x2000: "mutex_release",
             0x3000: "pool_lock_release", 0x4000: "page_alloc_contiguous",
             0x5000: "fd_table_close", 0x6000: "world_stop_machine_end",
             0x7000: "workload_peer_sleep_progress",
             0x8000: "workload_peer_sleep_pause"}

    def name(self, address):
        return self.TABLE.get(address & ~0xfff, f"0x{address:x}")


CORE0 = "RECORDED irqsoff: cpu=0 longest=900 freq=54000000"
CORE1 = "RECORDED irqsoff: cpu=1 longest=700 freq=54000000"
PAGE0 = "RECORDED irqsoff class: cpu=0 ticks=900 to 0x2008 0x4010 0x5010"
PAGE1 = "RECORDED irqsoff class: cpu=1 ticks=700 to 0x2008 0x4020 0x0"
FD1 = "RECORDED irqsoff class: cpu=1 ticks=300 to 0x2008 0x3008 0x5010"
STOP0 = "RECORDED irqsoff class: cpu=0 ticks=50 to 0x6010 0x0 0x0"
COST = ("irq mask cost: sample=1 rounds=4096 pmr=5886 daif=1478 "
        "sampled=6500 frequency=54000000")
GOOD = [CORE0, PAGE0, STOP0, CORE1, PAGE1, FD1, COST]
# #1110: the deliberate peer-sleep span, longer than every real class, and
# its negative control: a near name the exclusion must not match.
PEER0 = "RECORDED irqsoff class: cpu=0 ticks=9000 to 0x1008 0x7010 0x0"
NEAR0 = "RECORDED irqsoff class: cpu=0 ticks=8000 to 0x1008 0x8010 0x0"


def run(lines, baseline=None):
    """Report `lines`; with `baseline` (class -> us), judged against it."""
    out = io.StringIO()
    err = io.StringIO()
    saved = r.BASELINE_RPI5_US
    try:
        if baseline is not None:
            r.BASELINE_RPI5_US = baseline
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            status = r.report("\n".join(lines), FakeSymbols(), "t",
                              baseline is not None)
    finally:
        r.BASELINE_RPI5_US = saved
    return status, out.getvalue() + err.getvalue()


# page_alloc_contiguous closes at 900 ticks = 16.7 us; fd_table_close 5.6 us;
# world_stop_machine_end 0.9 us.
UNDER = {"page_alloc_contiguous": 5.6, "fd_table_close": 2.0,
         "world_stop_machine_end": 1.0}
OVER = dict(UNDER, page_alloc_contiguous=5.5)


JUDGED = (
    # name, lines, baseline, expected status, texts that must appear
    ("judged: every class under 3x passes", GOOD, UNDER, 0,
     ["3 lock class(es)"]),
    ("judged: a class over 3x fails", GOOD, OVER, 1,
     ["class page_alloc_contiguous masked IRQs for 16.7 us on cpu0",
      "over 3x its RPi5 baseline 5.5 us", "#1093"]),
    ("judged: a class without baseline is shown, not judged", GOOD,
     {"page_alloc_contiguous": 5.6}, 0,
     ["irqsoff class fd_table_close: no baseline, not judged"]),
    ("judged: a deliberate span is never judged", GOOD + [PEER0],
     dict(UNDER, workload_peer_sleep_progress=0.1), 0,
     ["irqsoff excluded class workload_peer_sleep_progress"]),
    ("judged: a missing measurement still fails", [COST], UNDER, 1,
     ["#958"]),
)

CASES = (
    # name, lines, expected status, texts that must appear
    ("classes folded past wrappers, longest first", GOOD, 0,
     ["irqsoff class page_alloc_contiguous: 900 ticks",
      "irqsoff class fd_table_close: 300 ticks",
      "irqsoff class world_stop_machine_end: 50 ticks",
      "2 core(s), 3 lock class(es)", "sampler cost: 2.8 ns"]),
    ("timestamped replay passes",
     GOOD + ["[000004.000001] " + line for line in GOOD], 0,
     ["3 lock class(es)"]),
    ("deliberate span excluded, still shown", GOOD + [PEER0], 0,
     ["irqsoff excluded class workload_peer_sleep_progress: 9000 ticks",
      "deliberate: #829", "3 lock class(es)"]),
    ("near name is not excluded", GOOD + [NEAR0], 0,
     ["irqsoff class workload_peer_sleep_pause: 8000 ticks",
      "4 lock class(es)"]),
    ("no cost line still reports", GOOD[:-1], 0, ["3 lock class(es)"]),
    ("missing core line fails", [PAGE0], 1, ["without its core line"]),
    ("no lines at all fails", [COST], 1, ["#958"]),
    ("doubled core line fails",
     GOOD + ["RECORDED irqsoff: cpu=0 longest=901 freq=54000000"], 1,
     ["twice"]),
    ("malformed class line fails",
     GOOD + ["RECORDED irqsoff class: cpu=0 ticks=x to 0x1"], 1,
     ["malformed"]),
)


def main():
    failures = []
    for name, lines, expected, texts in CASES:
        status, output = run(lines)
        if status != expected:
            failures.append(f"{name}: status {status}, expected {expected}: "
                            f"{output!r}")
            continue
        for text in texts:
            if text not in output:
                failures.append(f"{name}: {text!r} not in {output!r}")
    for name, lines, baseline, expected, texts in JUDGED:
        status, output = run(lines, baseline)
        if status != expected:
            failures.append(f"{name}: status {status}, expected {expected}: "
                            f"{output!r}")
            continue
        for text in texts:
            if text not in output:
                failures.append(f"{name}: {text!r} not in {output!r}")
    if "fd_table_close masked" in run(GOOD, OVER)[1]:
        failures.append("judged: a class under 3x reported as failing")
    ordered = run(GOOD)[1]
    if not (ordered.index("page_alloc_contiguous:") <
            ordered.index("fd_table_close:") <
            ordered.index("world_stop_machine_end:")):
        failures.append("classes not printed longest first")
    if "irqsoff class workload_peer_sleep_progress" in run(GOOD + [PEER0])[1]:
        failures.append("deliberate class also listed as a lock class")
    # Every exclusion still names a kernel function (no stale entry).
    root = pathlib.Path(__file__).resolve().parent.parent / "kernel" / "kernel"
    source = "".join(path.read_text() for path in root.glob("*.tkb"))
    for name in r.DELIBERATE:
        if not re.search(rf"\bfn {re.escape(name)}\(", source):
            failures.append(f"DELIBERATE names {name}, no such kernel fn")
    # A generic class name ends at `$` (locked_cell_give$BootPagePool); the
    # classes live anywhere under kernel/ (lib, printk, net).
    source = "".join(path.read_text()
                     for path in root.parent.rglob("*.tkb"))
    for name in r.BASELINE_RPI5_US:
        base = name.split("$", 1)[0]
        if not re.search(rf"\bfn {re.escape(base)}\b", source):
            failures.append(f"BASELINE_RPI5_US names {name}, no such kernel fn")
    scripts = pathlib.Path(__file__).resolve().parent
    for runner, wanted in (("run_kernel_hwtest_rpi5.sh", True),
                           ("run_kernel_qemutest.sh", False)):
        text = (scripts / runner).read_text()
        call = text[text.index("report_irqsoff_spans.py"):]
        call = call[:call.index("\n", call.index("--label"))]
        if ("--judge" in call) != wanted:
            failures.append(f"{runner}: --judge {'missing' if wanted else 'passed'}"
                            f" (#1093 judges RPi5 only)")
    if failures:
        for failure in failures:
            print(f"FAIL report-irqsoff-spans-controls: {failure}",
                  file=sys.stderr)
        return 1
    report_pass("report-irqsoff-spans-controls",
                f"{len(CASES) + len(JUDGED)} planted logs reported as "
                f"expected", cases=len(CASES) + len(JUDGED))
    return 0


if __name__ == "__main__":
    sys.exit(main())
