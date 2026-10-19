#!/usr/bin/env python3
"""Controls for the TLC log-ring trace check (GitHub issue #656).

scripts/validate_log_ring_trace.py checks a window of the kernel log ring
against kernel/models/LogRing.tla through LogRingTrace.tla. A trace check
that passes every window is the shape that rots unnoticed, so each refusal
the issue asks for is planted here and required, with what the validator
says checked rather than only its exit status:

- a torn read: the reader kept a copy although the slot's word changed
  under it (the second load saw another record), and a reader that kept a
  copy with no second load at all;
- a silent loss: the reader passed an overwritten sequence, or the
  continuation of a record whose first slot is gone, without counting it;
- a double owner: a writer claimed a slot another writer still holds. It
  is refused by the claim's guard, which --model CHECK_PREV=FALSE removes:
  the model then takes the claim and breaks NoDoubleOwner, so the refusal
  is the model's guard and not an accident of the trace spec.

And the negative control #606 has: the window that passes fails when one
action it needs is left out of the model (--without Commit).

These run TLC, so they belong to `make modelcheck`; the report-format
refusals and the action-list alignment need no TLC and are
scripts/check_validate_log_ring_trace_controls.py.

Usage: log_ring_trace_tlc_controls.py   (exit 0 = every control behaved)
"""

import concurrent.futures
import os
import subprocess
import sys
import tempfile
from pathlib import Path

sys.dont_write_bytecode = True
from pass_line import CaseCount, report_pass  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
VALIDATOR = ROOT / "scripts" / "validate_log_ring_trace.py"
# A hand-written window in the kernel's wire format: two writers, one of
# them a two-slot record, and the reader returning both.
WINDOW = ROOT / "kernel" / "tests" / "qemu" / "log_ring_trace_synthetic.window"

CASES = CaseCount()

STATE = {"F": 0, "R": 1, "C": 2, "D": 3}


def word(seq, state, span=1, cpu=0):
    """A raw slot word, as the kernel prints it."""
    if state == "F":
        return "0"
    return hex(seq << 16 | cpu << 8 | span << 4 | STATE[state])


def window(events, cpus=2, slots=4, head=8):
    lines = [f"log-ring-trace: begin cpus={cpus} slots={slots} head={head} "
             f"stored={len(events)} lost=0"]
    lines += [f"log-ring-trace: {event}" for event in events]
    lines.append("log-ring-trace: end")
    return "\n".join(lines) + "\n"


# Writer 0 writes sequence 8 (slot 0) whole.
W0 = [f"w0 reserve 8 1", f"w0 claim 8 1 0 {word(4, 'C')}",
      "w0 write 8 1 0", "w0 commit 8 1 0"]
# The reader reads 7 then 8.
READ_7_8 = ["r begin 7 9",
            f"r head 7 {word(7, 'C')} copy", "r copy 7",
            f"r check 7 {word(7, 'C')} kept",
            f"r head 8 {word(8, 'C')} copy", "r copy 8",
            f"r check 8 {word(8, 'C')} kept"]

# Torn: the reader's second load of 7's slot sees writer 1's claim of 11
# (slot 3), and the reader keeps the copy anyway.
TORN = W0 + [
    "w1 reserve 9 2", f"w1 claim 9 2 0 {word(5, 'C')}",
    f"w1 claim 9 2 1 {word(6, 'C')}", "w1 write 9 2 0", "w1 write 9 2 1",
    "w1 commit 9 2 1", "w1 commit 9 2 0",
    "w1 reserve 11 1", f"w1 claim 11 1 0 {word(7, 'C')}",
    "r begin 7 9", f"r head 7 {word(7, 'C')} copy", "r copy 7",
    f"r check 7 {word(11, 'R', cpu=1)} kept"]
# The unfixed reader: no second load, straight on to the next record.
NO_RECHECK = W0 + ["r begin 7 9", f"r head 7 {word(7, 'C')} copy",
                   "r copy 7", f"r head 8 {word(8, 'C')} copy"]
# Silent: 7's slot already holds 11, Reserved; the reader skips 7 uncounted.
SILENT = W0 + [
    "w1 reserve 9 2", f"w1 claim 9 2 0 {word(5, 'C')}",
    f"w1 claim 9 2 1 {word(6, 'C')}", "w1 write 9 2 0", "w1 write 9 2 1",
    "w1 commit 9 2 1", "w1 commit 9 2 0",
    "w1 reserve 11 1", f"w1 claim 11 1 0 {word(7, 'C')}",
    "r begin 7 9", f"r head 7 {word(11, 'R', cpu=1)} skip"]
# The same pass counted: accepted.
COUNTED = SILENT[:-1] + [f"r head 7 {word(11, 'R', cpu=1)} lost"]
# A continuation whose first slot was overwritten, skipped uncounted: the
# kernel reader's shape before #824 (a Continuation view -> Skipped(1)).
CONTINUATION = ["w0 reserve 8 1", f"w0 claim 8 1 0 {word(4, 'C', span=2)}",
                "r begin 5 9", f"r head 5 {word(5, 'C', span=0)} skip"]
# Double owner: writer 1 claims 12 into slot 0 while writer 0 holds 8 there.
DOUBLE = ["w0 reserve 8 1", f"w0 claim 8 1 0 {word(4, 'C')}",
          "w1 reserve 9 2", f"w1 claim 9 2 0 {word(5, 'C')}",
          f"w1 claim 9 2 1 {word(6, 'C')}", "w1 write 9 2 0",
          "w1 write 9 2 1", "w1 commit 9 2 1", "w1 commit 9 2 0",
          "w1 reserve 11 1", f"w1 claim 11 1 0 {word(7, 'C')}",
          "w1 write 11 1 0", "w1 commit 11 1 0",
          "w1 reserve 12 1", f"w1 claim 12 1 0 {word(8, 'R', cpu=0)}"]


# The short window with counter stamps. In order: writer 0's record, then
# the reader. Early: the reader's load of 8 ends before writer 0 reserved 8,
# yet saw 8 Committed -- no interleaving the stamps allow has that.
def stamped(events, starts):
    return [f"{e} @{t}+5" if not e.startswith("r begin") else e
            for e, t in zip(events, starts)]


IN_ORDER = (stamped(W0, [100, 110, 120, 130]) +
            stamped(READ_7_8, [0, 140, 150, 160, 170, 180, 190]))
EARLY = (stamped(W0, [100, 110, 120, 130]) +
         stamped(READ_7_8, [0, 10, 20, 30, 40, 50, 60]))


def run(text, *extra):
    """The validator as the lanes run it: a separate process."""
    with tempfile.NamedTemporaryFile("w", suffix=".log") as log:
        log.write(text)
        log.flush()
        return subprocess.run(
            [sys.executable, str(VALIDATOR), log.name, *extra],
            capture_output=True, text=True, check=False)


def expect(name, text, extra, passes, needles, absent=None):
    return (name, text, extra, passes, needles, absent)


def judge(case, result):
    name, _, _, passes, needles, absent = case
    CASES.note()
    output = result.stdout + result.stderr
    missing = [n for n in needles if n not in output]
    if (result.returncode == 0) != passes or missing or \
            (absent is not None and absent in output):
        print(f"FAIL log-ring-trace TLC controls: {name}: expected "
              f"{'PASS' if passes else 'a refusal'} saying {needles!r}"
              f"{'' if absent is None else f' and not {absent!r}'}, got "
              f"exit {result.returncode}:\n{output}")
        return False
    return True


def cases():
    recorded = WINDOW.read_text(encoding="utf-8")
    refused = "FAIL log-ring-trace: the kernel made a ring transition"
    none = "no interleaving of the streams is a behaviour of LogRing.tla"
    return [
        expect("the synthetic window", recorded, (), True,
               ["PASS log-ring-trace", "ContCheck=1"]),
        expect("the synthetic window without Commit", recorded,
               ("--without", "Commit"), False, [none + " without Commit",
                                                refused]),
        expect("a short window, both writers and the reader",
               window(W0 + READ_7_8), (), True, ["PASS log-ring-trace"]),
        expect("the short window, stamped in order", window(IN_ORDER), (),
               True, ["PASS log-ring-trace"]),
        expect("the short window, stamped with the reader's load of 8 "
               "before its reservation", window(EARLY), (), False,
               [none, "r head 8", refused]),
        expect("a torn read: the second load saw another record", window(TORN),
               (), False, [none, "r check 7", refused]),
        expect("a torn read: no second load", window(NO_RECHECK), (), False,
               [none, "r head 8", refused]),
        expect("a silent loss: an overwritten sequence skipped uncounted",
               window(SILENT), (), False, [none, "r head 7", refused]),
        expect("the same sequence counted lost: TLC accepts it, and only the "
               "probe policy refuses a window with no copy", window(COUNTED),
               (), False, ["never exercised"], absent="ERROR"),
        expect("a silent loss: a stray continuation skipped uncounted",
               window(CONTINUATION), (), False, [none, "r head 5", refused]),
        expect("a double owner", window(DOUBLE), (), False,
               [none, "w1 claim 12", refused]),
        expect("a double owner, the claim's guard removed", window(DOUBLE),
               ("--model", "CHECK_PREV=FALSE"), False,
               ["NoDoubleOwner is violated", refused]),
    ]


def main() -> int:
    tools = subprocess.run(["bash", str(ROOT / "scripts" / "fetch_model_tools.sh")],
                           capture_output=True, text=True, check=True)
    os.environ["TAKIBI_MODEL_TOOLS_JAR"] = str(
        Path(tools.stdout.strip()) / "tla2tools-1.7.4" / "tla2tools.jar")
    planned = cases()
    jobs = int(os.environ.get("MODELCHECK_JOBS") or os.cpu_count() or 1)
    with concurrent.futures.ThreadPoolExecutor(max_workers=jobs) as pool:
        results = list(pool.map(lambda c: run(c[1], *c[2]), planned))
    verdicts = [judge(case, result) for case, result in zip(planned, results)]
    if not all(verdicts):
        return 1
    report_pass(
        "log-ring-trace TLC controls",
        "TLC accepts the synthetic window and a short two-writer window as "
        "LogRing.tla behaviours, also with counter stamps in order, refuses "
        "it when the stamps put a load before the write it saw, refuses "
        "the synthetic one without Commit, "
        "and refuses a torn read (second load changed, or no second load), "
        "a silent loss (an overwritten sequence or a stray continuation "
        "skipped uncounted) and a double owner, which the model without the "
        "claim's guard takes and then breaks NoDoubleOwner",
        cases=CASES.ran)
    return 0


if __name__ == "__main__":
    sys.exit(main())
