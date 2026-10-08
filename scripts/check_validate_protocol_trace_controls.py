#!/usr/bin/env python3
"""Controls for the protocol-trace replay (GitHub issue #606).

scripts/validate_protocol_trace.py passes on every healthy boot, which is
the shape that rots unnoticed: an action that matches too much, or a parse
that stops reading, turns it into a check of nothing. So each refusal is
planted here and required, with its diagnostic checked rather than only the
exit status.

Two of them are the reason the replay exists:

- A path the model lacks fails a PASSING run. The recorded QEMU window
  kernel/tests/qemu/protocol_trace.window passes; replayed without
  ChildExitStart, the model action for the direct parent start that #609's
  defect sat beside, it must fail as a step no action describes. No race is
  needed for that: the direct start runs on an ordinary wait4 wake.
- #609 itself: a child's exit starting its parent while another core still
  owns the parent's stack must fail as
  "ChildExitStart not enabled: owner[parent] = c1".
"""

import subprocess
import sys
import tempfile
from pathlib import Path

from pass_line import CaseCount, report_pass

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


def run(text, *extra):
    with tempfile.NamedTemporaryFile("w", suffix=".log") as log:
        log.write(text)
        log.flush()
        return subprocess.run(
            [sys.executable, str(VALIDATOR), log.name, *extra],
            capture_output=True, text=True, check=False)


def expect(name, result, passes, needle, absent=None):
    CASES.note()
    output = result.stdout + result.stderr
    if (result.returncode == 0) != passes or needle not in output or \
            (absent is not None and absent in output):
        print(f"FAIL validate-protocol-trace controls: {name}: expected "
              f"{'PASS' if passes else 'a refusal'} saying {needle!r}, got "
              f"exit {result.returncode}:\n{output}")
        return False
    return True


def main() -> int:
    recorded = WINDOW.read_text(encoding="utf-8")
    interrupted = INTERRUPT_WINDOW.read_text(encoding="utf-8")
    napped = NAP_WINDOW.read_text(encoding="utf-8")
    cloned = CLONE_WINDOW.read_text(encoding="utf-8")
    checks = [
        expect("the recorded RPi5 clone-return reschedule", run(cloned),
               True, "CloneReschedule=1"),
        expect("that window without CloneReschedule",
               run(cloned, "--without", "CloneReschedule"), False,
               "sequence 339 (cpu 0): SwitchAway not enabled"),
        expect("a refused clone transition reports the physical parent stack",
               run(cloned, "--without", "CloneReschedule"), False,
               "c0(current=87, stands=86, reserved=2, interrupted=False)"),
        expect("a refused clone transition reports the unstarted child",
               run(cloned, "--without", "CloneReschedule"), False,
               "p87(state=Running, owner=None, parent=86, wait=0)"),
        expect("a refused clone transition reports the observed successor",
               run(cloned, "--without", "CloneReschedule"), False,
               "c0(current=2, stands=86, reserved=2, interrupted=False)"),
        expect("clone reschedule cannot give the child an owned stack",
               run(cloned.replace("339 0 l p 87 1 - 0 86",
                                  "339 0 l p 87 1 1 0 86")), False,
               "CloneReschedule not enabled: the unstarted child already owns a stack"),
        expect("clone reschedule must use the reserved successor",
               run(cloned.replace("339 0 l c 0 2 86",
                                  "339 0 l c 0 1 86")), False,
               "CloneReschedule not enabled: reserved[c0] = 2, not 1"),
        expect("clone reschedule cannot relabel the retained parent",
               run(cloned.replace("339 0 l p 87 1 - 0 86",
                                  "339 0 l p 87 1 - 0 1")), False,
               "sequence 339 (cpu 0): SwitchAway not enabled"),
        expect("the recorded window whose child napped with no successor",
               run(napped), True, "SwitchAway=0, CloneReschedule=0, Wait4Block=2, Nap=1"),
        expect("the recorded window with an interrupt from EL0",
               run(interrupted), True, "InterruptDepart=1"),
        expect("that window without InterruptDepart",
               run(interrupted, "--without", "InterruptDepart"), False,
               "IdleEnter not enabled: current[c0] = 76"),
        expect("an allocation landing inside another CPU's hold",
               run(window(SNAPSHOT + ["1 1 l p 12 5 - 0 10"])), False,
               "never exercised", absent="ERROR"),
        expect("a tick leave inside an interrupt", run(window(TICK_LEAVE)),
               False, "never exercised", absent="ERROR"),
        expect("a tick leave with no interrupt taken",
               run(window(TICK_LEAVE_UNINTERRUPTED)), False,
               "TickLeave not enabled: c0 is not inside an interrupt"),
        expect("the recorded QEMU window", run(recorded), True,
               "PASS protocol-trace:"),
        expect("the recorded window without ChildExitStart",
               run(recorded, "--without", "ChildExitStart"), False,
               "a step no model action describes"),
        expect("#609's start on a stack another core owns",
               run(window(SHARED_STACK)), False,
               "ChildExitStart not enabled: owner[parent] = c1"),
        expect("#550: blocking in wait4 with a zombie child",
               run(window(BLOCK_WITH_ZOMBIE)), False,
               "Wait4Block not enabled: 10 blocks with its child 11 "
               "already Exited"),
        expect("#550: an exit that wakes a Blocked parent nobody",
               run(window(EXIT_WAKES_NOBODY)), False,
               "NoLostWakeup: 10 sleeps in wait4 while its child 11 is a "
               "zombie"),
        expect("an exit that wakes a process that is not the parent",
               run(window(EXIT_WAKES_STRANGER)), False,
               "ChildExit not enabled: 11 exits and wakes 12, which is not "
               "its parent"),
        expect("a record removed with no lock held",
               run(window(REMOVED_UNLOCKED)), False,
               "record 11 was removed with no lock held"),
        expect("a live record removed",
               run(window(REMOVED_LIVE)), False,
               "Wait4Reap not enabled: state[11] = Running"),
        expect("#603: ChildExit published on a Running process",
               run(window(STALE_CHILD_EXIT)), False,
               "WaitMatchesState: 10 is Running and holds the published wait 2"),
        expect("a Signal wait held by a Running process",
               run(window(STALE_SIGNAL)), False,
               "WaitMatchesState: 10 is Running and holds the published wait 5"),
        expect("a window that lost changes",
               run(window(SNAPSHOT, lost=3)), False, "lost 3 change(s)"),
        expect("a report cut before its end",
               run(window(SNAPSHOT, end=False)), False, "no end line"),
        expect("a state changed with no lock held",
               run(window(SNAPSHOT + ["1 0 u p 10 1 - 0 -"])), False,
               "with no lock held"),
        expect("a snapshot already unsafe",
               run(window(["0 0 l p 10 2 1 0 -", "0 0 l c 0 10 10",
                           "0 0 l c 1 - -"])), False,
               "StackSafety: c0 stands on 10, owned by 1"),
        expect("a window that exercised nothing",
               run(window(SNAPSHOT)), False, "never exercised"),
        expect("a log with no window", run("takibi kernel: EL1\n"), False,
               "expected one protocol-trace window, found 0"),
    ]
    if not all(checks):
        return 1
    report_pass(
        "validate-protocol-trace controls",
        "Wait4Block.tla's zombie-child block, lost wakeup and wrong-parent "
        "wake, RecordLifetime.tla's unlocked and premature removal, and a "
        "wait published on a Running process are each refused; three recorded QEMU windows pass, one with Nap in SwitchAway's place; they fail without ChildExitStart "
        "and InterruptDepart; the recorded RPi5 clone reschedule passes only with "
        "CloneReschedule, and a child-owned stack, an unreserved successor "
        "or a relabelled parent are refused, with before/observed state for the "
        "physical parent stack, unstarted child and reserved successor; an allocation inside another CPU's hold is "
        "absorbed, a tick leave passes only inside an interrupt, "
        "and #609's shared-stack start, a lost change, a cut report, an "
        "unlocked change, an unsafe snapshot, an unexercised window and a "
        "missing window are each refused with their diagnostic",
        cases=CASES.ran)
    return 0


if __name__ == "__main__":
    sys.exit(main())
