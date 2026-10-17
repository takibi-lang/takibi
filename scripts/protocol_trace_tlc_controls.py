#!/usr/bin/env python3
"""Controls for the TLC protocol-trace check (GitHub issue #606, stage 2).

scripts/validate_protocol_trace.py passes on every healthy boot, which is
the shape that rots unnoticed: a trace spec that matches too much, or a
generator that stops reading, turns it into a check of nothing. So each
refusal is planted here and required, with where TLC refused it checked
rather than only the exit status. These run TLC, so they belong to `make
modelcheck` (scripts/run_model_checks.sh), not to the fast gate; the
report-format refusals that need no TLC are
scripts/check_validate_protocol_trace_controls.py.

Two of them are the reason the check exists:

- A path the model lacks fails a PASSING run. The recorded QEMU window
  kernel/tests/qemu/protocol_trace.window passes; checked without
  ChildExitStart, the model action for the direct parent start that #609's
  defect sat beside, it must fail. No race is needed for that: the direct
  start runs on an ordinary wait4 wake.
- #609 itself: a child's exit starting its parent while another core still
  owns the parent's stack must be refused at that hold -- and accepted by
  the model with WAKE_START_CHECKS_STACK = FALSE, which then breaks
  StartsOnFreeStack. That pair shows the refusal is the model's guard, not
  an accident of the trace spec.

Usage: protocol_trace_tlc_controls.py   (exit 0 = every control behaved)
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
VALIDATOR = ROOT / "scripts" / "validate_protocol_trace.py"
WINDOW = ROOT / "kernel" / "tests" / "qemu" / "protocol_trace.window"
# The debug lane's window that first took an interrupt from EL0 inside it,
# which the model did not have until it failed an allcheck.
INTERRUPT_WINDOW = (ROOT / "kernel" / "tests" / "qemu-debug" /
                    "protocol_trace.window")
# A debug-lane window in which the napping child blocked with no successor
# (Nap) because another core had taken its parent: SwitchAway never ran.
NAP_WINDOW = (ROOT / "kernel" / "tests" / "qemu-debug" /
              "protocol_trace_nap.window")
# RPi5's real clone-return window: an EL1 timer leaves a reschedule pending
# before the child has made its first physical stack handoff.
CLONE_WINDOW = (ROOT / "kernel" / "tests" / "rpi5" /
                "protocol_trace_clone_reschedule.window")

CASES = CaseCount()


def window(changes, lost=0, end=True, holds=10):
    lines = [f"protocol-trace: begin cores=2 stored={len(changes)} "
             f"lost={lost} holds={holds}"]
    lines += [f"protocol-trace: {change}" for change in changes]
    if end:
        lines.append("protocol-trace: end")
    return "\n".join(lines) + "\n"


# Parent 10 and child 11 on core 0; core 1 idle.
SNAPSHOT = [
    "0 0 l p 10 2 0 0 -",
    "0 0 l p 11 5 - 0 10",
    "0 0 l c 0 10 10",
    "0 0 l c 1 - -",
]

# #609: the parent blocked in wait4 on core 1, which still stands on its
# stack, and the child running on core 0 exits and starts it.
SHARED_STACK = [
    "0 0 l p 10 3 1 2 -",
    "0 0 l p 11 2 0 0 10",
    "0 0 l c 0 11 11",
    "0 0 l c 1 - 10",
    "1 0 l p 11 4 0 0 10",
    "1 0 l p 10 2 1 2 -",
]

# An interrupt from EL0 releases the running process's stack, and the tick
# inside it leaves the core; then the same leave with no interrupt taken.
TICK_LEAVE = SNAPSHOT[:1] + ["0 0 l p 11 2 1 0 10", "0 0 l c 0 10 10",
                             "0 0 l c 1 11 11",
                             "1 0 l p 10 2 - 0 -", "1 0 l c 0 10 -",
                             "2 0 l p 10 1 - 0 -", "2 0 l c 0 - -"]
TICK_LEAVE_UNINTERRUPTED = SNAPSHOT[:1] + [
    "0 0 l p 11 2 1 0 10", "0 0 l c 0 10 10", "0 0 l c 1 11 11",
    "1 0 l p 10 1 0 0 -", "1 0 l c 0 - 10"]

# #803: an idle core 1 reserves and commits Ready 12, then reserves Ready
# 13 before the exception return has put 12 on its own stack. The kernel
# selects nothing in that window (only a clone child's first return does).
RESERVE_UNSWITCHED = [
    "0 0 l p 10 2 0 0 -", "0 0 l p 12 1 - 0 -", "0 0 l p 13 1 - 0 -",
    "0 0 l c 0 10 10", "0 0 l c 1 - -",
    "1 1 l p 12 2 - 0 -", "2 1 l c 1 12 -", "3 1 l p 13 2 - 0 -"]
# The same window up to the commit, which the model allows.
RESERVE_COMMITTED = RESERVE_UNSWITCHED[:-1]

# Wait4Block.tla and RecordLifetime.tla (#647). Parent 10 runs on core 1
# and its child 11 on core 0.
FAMILY = [
    "0 0 l p 10 2 1 0 -",
    "0 0 l p 11 2 0 0 10",
    "0 0 l c 0 11 11",
    "0 0 l c 1 10 10",
]

# #550: the child exits first, and the parent then publishes Blocked with a
# zombie child, which nothing will wake. The fix's re-check refuses it.
BLOCK_WITH_ZOMBIE = FAMILY + [
    "1 0 l p 11 4 0 0 10",
    "1 0 l c 0 - 11",
    "2 1 l p 10 3 1 2 -",
    "2 1 l c 1 - 10",
]

# The parent blocks first, and the child's exit wakes nobody: the lost
# wakeup itself, reached with each step individually legal.
EXIT_WAKES_NOBODY = FAMILY + [
    "1 1 l p 10 3 1 2 -",
    "1 1 l c 1 - 10",
    "2 0 l p 11 4 0 0 10",
    "2 0 l c 0 - 11",
]
# The same exit waking its parent, which the model allows.
EXIT_WAKES_PARENT = FAMILY + [
    "1 1 l p 10 3 1 2 -",
    "1 1 l c 1 - 10",
    "2 0 l p 11 4 0 0 10",
    "2 0 l p 10 1 1 2 -",
    "2 0 l c 0 - 11",
]

# The child's exit wakes a process that is not its parent.
EXIT_WAKES_STRANGER = FAMILY[:1] + [
    "0 0 l p 12 3 - 2 -",
] + FAMILY[1:] + [
    "1 0 l p 11 4 0 0 10",
    "1 0 l p 12 1 - 0 -",
    "1 0 l c 0 - 11",
]

# The child's zombie is removed with no lock held, and a live record is
# removed at all.
REMOVED_UNLOCKED = FAMILY + [
    "1 0 l p 11 4 0 0 10",
    "1 0 l c 0 - 11",
    "2 0 u g 11 0 0",
]
REMOVED_LIVE = FAMILY + ["1 0 l g 11 0 0"]

# #603 (#653): wait4's decision published on a process that is still Running
# and reserved for no core, and any other wait on a Running process. Neither
# changes the state, so the only thing that shows them is the reason.
STALE_CHILD_EXIT = FAMILY + ["1 1 l p 10 2 1 2 -"]
STALE_SIGNAL = FAMILY + ["1 1 l p 10 2 1 5 -"]

# 765a27af's lost child: a clone child's first return leaves its core
# while the core still stands on the PARENT's stack. The fixed model
# refuses the leave; with LEAVE_CHECKS_STACK = FALSE it takes it.
LEAVE_ON_PARENT_STACK = SNAPSHOT + [
    "1 0 l c 0 11 10",
    "2 0 l p 11 2 - 0 10", "2 0 l p 10 1 0 0 -",
    "3 0 l c 0 - 10",
]


def run(text, *extra):
    """The validator as the lanes run it: a separate process."""
    with tempfile.NamedTemporaryFile("w", suffix=".log") as log:
        log.write(text)
        log.flush()
        return subprocess.run(
            [sys.executable, str(VALIDATOR), log.name, *extra],
            capture_output=True, text=True, check=False)


def expect(name, text, extra, passes, needles, absent=None):
    """A control: (name, its arguments, the verdict, the words it must say)."""
    return (name, text, extra, passes, needles, absent)


def judge(case, result):
    name, _, _, passes, needles, absent = case
    CASES.note()
    output = result.stdout + result.stderr
    missing = [n for n in needles if n not in output]
    if (result.returncode == 0) != passes or missing or \
            (absent is not None and absent in output):
        print(f"FAIL protocol-trace TLC controls: {name}: expected "
              f"{'PASS' if passes else 'a refusal'} saying {needles!r}"
              f"{'' if absent is None else f' and not {absent!r}'}, got "
              f"exit {result.returncode}:\n{output}")
        return False
    return True


def cases():
    recorded = WINDOW.read_text(encoding="utf-8")
    interrupted = INTERRUPT_WINDOW.read_text(encoding="utf-8")
    napped = NAP_WINDOW.read_text(encoding="utf-8")
    cloned = CLONE_WINDOW.read_text(encoding="utf-8")
    refused = "FAIL protocol-trace: the kernel made a step"
    return [
        expect("the recorded QEMU window", recorded, (), True,
               ["PASS protocol-trace: TLC matched", "ChildExitStart=1"]),
        expect("the recorded window without ChildExitStart", recorded,
               ("--without", "ChildExitStart"), False,
               ["sequence 69 (cpu 0): no behaviour of StackOwnership.tla "
                "without ChildExitStart takes this locked hold", refused]),
        expect("the recorded RPi5 clone-return reschedule", cloned, (), True,
               ["CloneReschedule=1"]),
        expect("that window without CloneReschedule", cloned,
               ("--without", "CloneReschedule"), False,
               ["sequence 339 (cpu 0): no behaviour", "339 0 l c 0 2 86",
                # The hidden state TLC chose before the refused hold: c0
                # reserved the successor 2 while the child 87 is current.
                'reserved = [c0 |-> "p2"', 'current = [c0 |-> "p87"',
                'stands = [c0 |-> "p86"']),
        expect("clone reschedule cannot give the child an owned stack",
               cloned.replace("339 0 l p 87 1 - 0 86", "339 0 l p 87 1 1 0 86"),
               (), False, ["sequence 339 (cpu 0): no behaviour", refused]),
        expect("clone reschedule must use the reserved successor",
               cloned.replace("339 0 l c 0 2 86", "339 0 l c 0 1 86"),
               (), False, ["sequence 339 (cpu 0): no behaviour", refused]),
        expect("clone reschedule cannot relabel the retained parent",
               cloned.replace("339 0 l p 87 1 - 0 86", "339 0 l p 87 1 - 0 1"),
               (), False, ["87's parent changes from 86 to 1"]),
        expect("the recorded window whose child napped with no successor",
               napped, (), True,
               ["SwitchAway=0, CloneReschedule=0, Wait4Block=2, Nap=1"]),
        expect("the recorded window with an interrupt from EL0", interrupted,
               (), True, ["InterruptDepart=1"]),
        expect("that window without InterruptDepart", interrupted,
               ("--without", "InterruptDepart"), False,
               ["no behaviour of StackOwnership.tla without InterruptDepart",
                refused]),
        expect("an allocation landing inside another CPU's hold",
               window(SNAPSHOT + ["1 1 l p 12 5 - 0 10"]), (), False,
               ["never exercised"], absent="ERROR"),
        expect("a tick leave inside an interrupt", window(TICK_LEAVE), (),
               False, ["never exercised"], absent="ERROR"),
        expect("#803: a reserve before the current process was switched to",
               window(RESERVE_UNSWITCHED), (), False,
               ["sequence 3 (cpu 1): no behaviour", "3 1 l p 13 2 - 0 -",
                refused]),
        expect("#803: the same window up to the commit",
               window(RESERVE_COMMITTED), (), False,
               ["never exercised"], absent="ERROR"),
        expect("a tick leave with no interrupt taken",
               window(TICK_LEAVE_UNINTERRUPTED), (), False,
               ["sequence 1 (cpu 0): no behaviour", refused]),
        expect("#609's start on a stack another core owns",
               window(SHARED_STACK), (), False,
               ["sequence 1 (cpu 0): no behaviour", refused]),
        expect("#609's start, by the model without its stack check",
               window(SHARED_STACK),
               ("--model", "WAKE_START_CHECKS_STACK=FALSE"), False,
               ["sequence 1 (cpu 0): after ChildExitStart, StartsOnFreeStack "
                "is violated"]),
        expect("765a27af's leave on the parent's stack",
               window(LEAVE_ON_PARENT_STACK), (), False,
               ["sequence 3 (cpu 0): no behaviour", refused]),
        expect("that leave, by the model without its stack check",
               window(LEAVE_ON_PARENT_STACK),
               ("--model", "LEAVE_CHECKS_STACK=FALSE"), False,
               ["sequence 3 (cpu 0): after LeaveBegin, RunningMatchesCores "
                "is violated"]),
        expect("#550: blocking in wait4 with a zombie child",
               window(BLOCK_WITH_ZOMBIE), (), False,
               ["sequence 2 (cpu 1): no behaviour", refused]),
        expect("#550: an exit that wakes a Blocked parent nobody",
               window(EXIT_WAKES_NOBODY), (), False,
               ["sequence 2 (cpu 0): no behaviour", refused]),
        expect("the same exit waking its parent", window(EXIT_WAKES_PARENT),
               (), False, ["never exercised"], absent="ERROR"),
        expect("an exit that wakes a process that is not the parent",
               window(EXIT_WAKES_STRANGER), (), False,
               ["sequence 1 (cpu 0): no behaviour", refused]),
        expect("a record removed with no lock held",
               window(REMOVED_UNLOCKED), (), False,
               ["sequence 2 (cpu 0): no behaviour", "unlocked hold", refused]),
        expect("a live record removed", window(REMOVED_LIVE), (), False,
               ["sequence 1 (cpu 0): no behaviour", refused]),
        expect("#603: ChildExit published on a Running process",
               window(STALE_CHILD_EXIT), (), False,
               ["sequence 1 (cpu 1): after none, WaitMatchesState is violated"]),
        expect("a Signal wait held by a Running process",
               window(STALE_SIGNAL), (), False,
               ["sequence 1 (cpu 1): after none, WaitMatchesState is violated"]),
        expect("a state changed with no lock held",
               window(SNAPSHOT + ["1 0 u p 10 1 - 0 -"]), (), False,
               ["sequence 1 (cpu 0): no behaviour", "unlocked hold", refused]),
        expect("a snapshot already unsafe",
               window(["0 0 l p 10 2 1 0 -", "0 0 l c 0 10 10",
                       "0 0 l c 1 - -"]), (), False,
               ["sequence 0 (cpu 0): after snapshot, StackSafety is violated"]),
        expect("a window that exercised nothing", window(SNAPSHOT), (), False,
               ["never exercised"], absent="ERROR"),
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
        "protocol-trace TLC controls",
        "TLC accepts the four recorded windows (QEMU, two debug-lane, RPi5 "
        "clone reschedule) as StackOwnership.tla behaviours and refuses each "
        "without the action it needs (ChildExitStart, InterruptDepart, "
        "CloneReschedule), reporting the hidden reservation; it refuses "
        "#609's shared-stack start and 765a27af's leave on the parent's stack, "
        "which the model without the guard takes and then breaks "
        "StartsOnFreeStack / RunningMatchesCores; #803's reserve before the "
        "switch, #550's block beside a zombie and exit waking nobody, a wake of "
        "a non-parent, an unlocked or premature removal, an unlocked change, "
        "a published wait on a Running process, an unsafe snapshot, a child "
        "given an owned stack, an unreserved successor and a relabelled parent",
        cases=CASES.ran)
    return 0


if __name__ == "__main__":
    sys.exit(main())
