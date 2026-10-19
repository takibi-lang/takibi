#!/usr/bin/env python3
"""Check a kernel protocol-trace window against StackOwnership.tla with TLC.

GitHub issue #606, stage 2. /bin/protocol-trace opens a window in which the
kernel diffs the stack-ownership state at every hold of the process-run lock
(kernel/kernel/protocol_trace.tkb) and prints the changes when the window
closes. This script only PARSES that window: it writes it as the TLA+
module ProtocolTraceData, one record per hold with every process's state,
stack owner, parent and wait reason and every core's current process and
stood-on stack as they stand after the hold, and asks TLC whether
kernel/models/StackOwnershipTrace.tla accepts it -- whether some behaviour
of kernel/models/StackOwnership.tla produces exactly that sequence of holds.
No enabling condition, effect or invariant is written here. Stage 1's
Python replay wrote every action again and could drift from the .tla;
this cannot.

What TLC checks, all in the .tla files:
- each locked hold that changes the state is one StackOwnership action,
  with its enabling condition, and an unlocked hold changes nothing the
  model orders by the run lock (RecordLifetime's REMOVE_UNDER_LOCK);
- the invariants after every hold: StackSafety, RunningMatchesCores,
  StartsOnFreeStack, NoLostWakeup (Wait4Block.tla's, over every parent),
  and WaitMatchesState (#653, the wait cell's rule);
- Wait4Block.tla's RECHECK and its "an exit wakes exactly its parent", and
  RecordLifetime.tla's "removed only once Exited", are enabling conditions
  of StackOwnership's Wait4Block/SwitchAway, ChildExit and Wait4Reap.

What this script still refuses itself, because it is about the report and
not the protocol: no window, two windows, a malformed line, a window that
lost changes or was cut short, and a snapshot missing a core. And one
policy: an action the probe is written to exercise that the matched
behaviour never took (REQUIRED below), which would make a PASS say nothing
about it.

What a PASS claims is narrow: every protocol transition the kernel made in
this window is one the model has. It does not claim the model is right, and
it says nothing about paths the window did not run.

The kernel's state codes: 1 Ready, 2 Running, 3 Blocked, 4 Exited,
5 Constructing; a Blocked process whose wait reason is 2 (ChildExit) is the
model's "Blocked", any other is "Napping". A removed record is "Reaped"; a
pid first seen mid-window as a fresh Constructing record (allocation is
ordered by the pool lock, not the run lock) is Constructing from the start;
any other pid not in the opening snapshot is "Absent", which no action
takes, so its appearance is refused by TLC.

Usage: validate_protocol_trace.py UART_LOG [--without ACTION]
       [--model NAME=BOOL ...]
--without drops one action from the model's next-state relation: the
negative control that a path the model lacked fails a passing run.
--model sets one of StackOwnership's defect constants (EXIT_IDLES,
LEAVE_CHECKS_STACK, WAKE_START_CHECKS_STACK), so a control can show which
guard refused a step.

Exit code only (0 = pass, 1 = fail).
"""

import argparse
import dataclasses
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MODELS = ROOT / "kernel" / "models"
SPECS = (MODELS / "StackOwnershipTrace.tla", MODELS / "StackOwnership.tla")

LINE_RE = re.compile(r"^protocol-trace: (.*)$")
BEGIN_RE = re.compile(
    r"^begin cores=(\d+) stored=(\d+) lost=(\d+) holds=(\d+)$")
STATES = {1: "Ready", 2: "Running", 3: "Blocked", 4: "Exited",
          5: "Constructing"}
WAIT_CHILD_EXIT = 2

# StackOwnership's Next, by the names StackOwnershipTrace.tla labels.
ACTIONS = ("CloneBegin", "CloneFinish", "SwitchComplete", "Reserve", "Commit",
           "SwitchAway", "CloneReschedule", "Wait4Block", "Nap", "Wake",
           "ChildExit", "ChildExitStart", "IdleEnter", "Wait4Reap",
           "LeaveBegin", "LeaveComplete", "InterruptDepart", "TickLeave")
MODEL_CONSTANTS = ("EXIT_IDLES", "LEAVE_CHECKS_STACK",
                   "WAKE_START_CHECKS_STACK")

# What /bin/protocol-trace makes the kernel do on every run, whatever the
# timing, one entry per step; where timing decides which of two actions the
# step is, the entry names both and either counts. The clone, the moves
# between CPUs that pinning forces, the child's exit and the reap happen
# every time.
#
# What does not is left out on purpose, after allcheck runs showed each
# missing: the child's 100 ms nap can find its deadline already past on a
# host that stalled the vCPU, so it never blocks (no Nap, SwitchAway or
# Wake), and then the parent may reach wait4 after the exit and never block
# either (no Wait4Block, and ChildExit rather than ChildExitStart). Those
# are still checked and counted when they happen; a run without them is
# not a failure. An action in the model and not here may legitimately not
# happen.
#
# LeaveBegin and LeaveComplete stay required because the probe makes them
# deterministic (#847): it re-pins itself away from CPU 0 while running on
# CPU 0, which hands it away at that syscall's own return. A leave from a
# peer could instead be a timer's InterruptDepart and TickLeave.
REQUIRED = (("CloneBegin",), ("CloneFinish",), ("SwitchComplete",),
            ("Reserve",), ("Commit",), ("ChildExit", "ChildExitStart"),
            ("IdleEnter",), ("Wait4Reap",), ("LeaveBegin",),
            ("LeaveComplete",))

NONE = "none"
IDLE = "idle"
ABSENT = "Absent"
REAPED = "Reaped"


class TraceError(Exception):
    pass


@dataclasses.dataclass
class Hold:
    sequence: int
    cpu: int
    unlocked: bool
    processes: dict   # pid -> (state, owner)
    parents: dict     # pid -> parent pid or None, as reported
    reasons: dict     # pid -> wait reason code, as reported
    gone: set
    cores: dict       # core -> (current, stands)
    lines: list       # the hold's own report lines, for diagnostics


def model_state(code, reason):
    if code not in STATES:
        raise TraceError(f"unknown process state code {code}")
    name = STATES[code]
    if name == "Blocked" and reason != WAIT_CHILD_EXIT:
        return "Napping"
    return name


def value(token):
    return None if token == "-" else int(token)


def parse(lines):
    """The one window in the log, as a header and a list of holds."""
    body = [m.group(1) for m in (LINE_RE.match(line) for line in lines) if m]
    begins = [i for i, text in enumerate(body) if text.startswith("begin ")]
    if len(begins) != 1:
        raise TraceError(f"expected one protocol-trace window, found "
                         f"{len(begins)}")
    header = BEGIN_RE.match(body[begins[0]])
    if not header:
        raise TraceError(f"malformed header: {body[begins[0]]}")
    cores, stored, lost, holds = (int(g) for g in header.groups())
    events = body[begins[0] + 1:]
    if not events or events[-1] != "end":
        raise TraceError("the window has no end line: the report was cut")
    events = events[:-1]
    if lost:
        raise TraceError(f"the window lost {lost} change(s); a check with "
                         "a gap in it proves nothing")
    if len(events) != stored:
        raise TraceError(f"the header says {stored} change(s) and "
                         f"{len(events)} arrived")
    steps = {}
    for text in events:
        fields = text.split()
        if len(fields) < 4 or not fields[0].isdigit() \
                or not fields[1].isdigit() or fields[2] not in ("l", "u"):
            raise TraceError(f"malformed change: {text}")
        sequence, cpu, lock, kind = int(fields[0]), int(fields[1]), \
            fields[2], fields[3]
        key = (sequence, lock == "u")
        hold = steps.setdefault(
            key, Hold(sequence, cpu, lock == "u", {}, {}, {}, set(), {}, []))
        hold.lines.append(text)
        try:
            if kind == "p" and len(fields) == 9:
                pid = int(fields[4])
                hold.processes[pid] = (
                    model_state(int(fields[5]), int(fields[7])),
                    value(fields[6]))
                hold.parents[pid] = value(fields[8])
                hold.reasons[pid] = value(fields[7]) or 0
            elif kind == "g" and len(fields) == 7:
                hold.gone.add(int(fields[4]))
            elif kind == "c" and len(fields) == 7:
                hold.cores[int(fields[4])] = (value(fields[5]),
                                              value(fields[6]))
            else:
                raise TraceError(f"malformed change: {text}")
        except ValueError:
            raise TraceError(f"malformed change: {text}") from None
    ordered = [steps[key] for key in sorted(steps,
                                            key=lambda k: (k[0], not k[1]))]
    if not ordered or ordered[0].sequence != 0 or ordered[0].unlocked:
        raise TraceError("the window does not start with its snapshot")
    for core in range(cores):
        if core not in ordered[0].cores:
            raise TraceError(f"the snapshot has no line for core {core}")
    # The snapshot has a line for every core slot, online or not; the
    # header counts the online ones.
    slots = max(ordered[0].cores) + 1
    if sorted(ordered[0].cores) != list(range(slots)):
        raise TraceError("the snapshot's core lines are not 0.."
                         f"{slots - 1}")
    return slots, holds, ordered


# --------------------------------------------------------------------------
# The window as observations: the full observed state after each hold.


def pid_name(pid):
    return NONE if pid is None else f"p{pid}"


def core_name(core):
    return NONE if core is None else f"c{core}"


@dataclasses.dataclass
class Observation:
    sequence: int
    cpu: int
    locked: bool
    state: dict    # pid -> state name
    owner: dict    # pid -> core or None
    parent: dict   # pid -> pid or None
    reason: dict   # pid -> wait reason code
    current: dict  # core -> pid or None
    stands: dict   # core -> pid or None (its idle stack)
    lines: list


def observations(cores, holds):
    """One Observation per hold, each the whole observed state after it.

    Pure bookkeeping: which pids exist, and the latest value reported for
    each. Conventions, all about the report rather than the protocol: a
    process's parent is the one link its lines report, for the whole window
    (a link reported later, at its clone, is the record's from allocation;
    a link the kernel clears ("-") while removing the record is the same
    link); and the wait reason is taken from locked lines only, as the wait
    cell publishes it under the run lock.
    """
    snapshot = holds[0]
    pids = set()
    for hold in holds:
        pids |= set(hold.processes) | hold.gone
        pids |= {p for p in hold.parents.values() if p is not None}
        pids |= {p for core in hold.cores.values() for p in core
                 if p is not None}
    state, owner, parent, reason = {}, {}, {}, {}
    for pid in pids:
        state[pid], owner[pid], parent[pid], reason[pid] = ABSENT, None, None, 0
    for pid in sorted(pids - set(snapshot.processes)):
        first = next((h.processes[pid] for h in holds[1:]
                      if pid in h.processes), None)
        if first == ("Constructing", None):
            state[pid] = "Constructing"
    for hold in holds:
        for pid, link in hold.parents.items():
            if link is None:
                continue
            if parent[pid] not in (None, link):
                raise TraceError(
                    f"sequence {hold.sequence}: {pid}'s parent changes from "
                    f"{parent[pid]} to {link} inside the window; "
                    "StackOwnership.tla's ParentOf is fixed, so a reparented "
                    "process cannot be checked")
            parent[pid] = link
    current = {core: None for core in range(cores)}
    stands = {core: None for core in range(cores)}
    result = []
    for hold in holds:
        for pid, (st, own) in hold.processes.items():
            state[pid], owner[pid] = st, own
            if not hold.unlocked:
                reason[pid] = hold.reasons[pid]
        for pid in hold.gone:
            state[pid], owner[pid] = REAPED, None
        for core, (cur, stood) in hold.cores.items():
            if core not in current:
                raise TraceError(f"a line for core {core} of a window with "
                                 f"{cores} core(s)")
            current[core], stands[core] = cur, stood
        result.append(Observation(hold.sequence, hold.cpu, not hold.unlocked,
                                  dict(state), dict(owner), dict(parent),
                                  dict(reason), dict(current), dict(stands),
                                  hold.lines))
    return result


def tla_record(fields):
    return "[" + ", ".join(f"{k} |-> {v}" for k, v in fields) + "]"


def tla_string(text):
    return f'"{text}"'


def trace_module(cores, obs):
    """The module ProtocolTraceData that StackOwnershipTrace.tla extends."""
    pids = sorted(obs[0].state)
    rows = []
    for o in obs:
        rows.append(tla_record([
            ("seq", str(o.sequence)),
            ("cpu", tla_string(core_name(o.cpu))),
            ("locked", "TRUE" if o.locked else "FALSE"),
            ("state", tla_record([(pid_name(p), tla_string(o.state[p]))
                                  for p in pids])),
            ("owner", tla_record([(pid_name(p), tla_string(core_name(o.owner[p])))
                                  for p in pids])),
            ("reason", tla_record([(pid_name(p), str(o.reason[p]))
                                   for p in pids])),
            ("current", tla_record([(core_name(c), tla_string(pid_name(o.current[c])))
                                    for c in range(cores)])),
            ("stands", tla_record([(core_name(c), tla_string(
                IDLE if o.stands[c] is None else pid_name(o.stands[c])))
                for c in range(cores)])),
        ]))
    return ("---- MODULE ProtocolTraceData ----\n"
            "\\* Generated by scripts/validate_protocol_trace.py.\n"
            "EXTENDS Sequences\n"
            "TraceCores == {" + ", ".join(tla_string(core_name(c))
                                          for c in range(cores)) + "}\n"
            "TraceProcs == {" + ", ".join(tla_string(pid_name(p))
                                          for p in pids) + "}\n"
            "TraceParent == " + tla_record(
                [(pid_name(p), tla_string(pid_name(obs[0].parent[p])))
                 for p in pids]) + "\n"
            "Trace == <<\n  " + ",\n  ".join(rows) + "\n>>\n"
            "====\n")


def trace_config(without, model, stop_at):
    constants = {"EXIT_IDLES": True, "LEAVE_CHECKS_STACK": True,
                 "WAKE_START_CHECKS_STACK": True}
    constants.update(model)
    lines = ["SPECIFICATION Spec", "CONSTANTS"]
    lines += [f"  {k} = {'TRUE' if v else 'FALSE'}" for k, v in constants.items()]
    lines.append(f'  WITHOUT = "{without or NONE}"')
    lines.append(f"  STOP_AT = {stop_at}")
    for inv in ("StackSafety", "RunningMatchesCores", "StartsOnFreeStack",
                "NoLostWakeup", "WaitMatchesState", "NotStopped",
                "TraceUnfinished"):
        lines.append(f"INVARIANT {inv}")
    return "\n".join(lines) + "\n"


# --------------------------------------------------------------------------
# Running TLC, and reading its answer.


def tla_jar():
    tools = os.environ.get("TAKIBI_MODEL_TOOLS_JAR")
    if tools:
        return tools
    root = subprocess.run(["bash", str(ROOT / "scripts" / "fetch_model_tools.sh")],
                          capture_output=True, text=True, check=False)
    if root.returncode != 0:
        raise TraceError("the TLA+ tools are not available: "
                         + root.stderr.strip())
    return str(Path(root.stdout.strip()) / "tla2tools-1.7.4" / "tla2tools.jar")


def run_tlc(cores, obs, without, model, stop_at=0):
    with tempfile.TemporaryDirectory(prefix="takibi-trace.") as work:
        work = Path(work)
        (work / "ProtocolTraceData.tla").write_text(trace_module(cores, obs),
                                                    encoding="utf-8")
        (work / "StackOwnershipTrace.cfg").write_text(
            trace_config(without, model, stop_at), encoding="utf-8")
        # TLC reads a spec's modules and config from one directory: the
        # two models are copied beside the generated data, unchanged.
        for spec in SPECS:
            (work / spec.name).write_bytes(spec.read_bytes())
        # Each JVM gets private standard-module files (scripts/run_tlc.sh).
        result = subprocess.run(
            ["java", f"-Djava.io.tmpdir={work}", "-XX:+UseSerialGC",
             "-cp", tla_jar(), "tlc2.TLC", "-workers", "1", "-deadlock",
             "-nowarning", "-config", "StackOwnershipTrace.cfg",
             "-metadir", "states", "StackOwnershipTrace.tla"],
            capture_output=True, text=True, check=False, cwd=work)
    return result.stdout + result.stderr


STATE_RE = re.compile(r"^State (\d+): ")
VAR_RE = re.compile(r"^/\\ (\w+) = (.*)$")


def behaviour(output):
    """The error trace TLC printed: a list of {variable: text} per state."""
    states = []
    for line in output.splitlines():
        # An initial state that breaks an invariant is printed with no
        # "State 1:" heading.
        if STATE_RE.match(line) or "is violated by the initial state" in line:
            states.append({})
        elif states:
            match = VAR_RE.match(line)
            if match:
                states[-1][match.group(1)] = match.group(2)
    return states


def describe_hold(o):
    return "\n".join(f"    {line}" for line in o.lines)


def stuck_report(cores, obs, without, model, depth):
    """Where every behaviour stopped, with the hidden state there."""
    if depth >= len(obs):
        return "TLC reached the end of the trace without a verdict"
    stuck = obs[depth]
    detail = run_tlc(cores, obs, without, model, stop_at=depth)
    states = behaviour(detail)
    before = ""
    if states and "Invariant NotStopped is violated" in detail:
        last = states[-1]
        before = "\n  the model's state before it (hidden variables " \
                 "chosen by TLC):\n" + "\n".join(
                     f"    {k} = {v}" for k, v in last.items()
                     if k not in ("l",))
    return (f"sequence {stuck.sequence} (cpu {stuck.cpu}): no behaviour of "
            f"StackOwnership.tla{' without ' + without if without else ''} "
            f"takes this {'locked' if stuck.locked else 'unlocked'} hold, "
            f"from any state matching the trace so far:\n"
            f"{describe_hold(stuck)}{before}")


def check(cores, holds, without=None, model=None):
    """(errors, counts): the refusal if any, and each action's count."""
    model = model or {}
    obs = observations(cores, holds)
    output = run_tlc(cores, obs, without, model)
    counts = {name: 0 for name in ACTIONS}
    violated = re.search(r"Invariant (\w+) is violated", output)
    if violated and violated.group(1) == "TraceUnfinished":
        for step in behaviour(output):
            name = step.get("act", "").strip('"')
            if name in counts:
                counts[name] += 1
        return [], counts
    if violated:
        states = behaviour(output)
        index = int(states[-1].get("l", "1")) - 1 if states else 0
        where = obs[index]
        act = states[-1].get("act", "?").strip('"') if states else "?"
        tail = "\n".join(f"    {k} = {v}" for k, v in states[-1].items()) \
            if states else ""
        return [f"sequence {where.sequence} (cpu {where.cpu}): after {act}, "
                f"{violated.group(1)} is violated:\n{describe_hold(where)}\n"
                f"  the state TLC reached:\n{tail}"], counts
    if "Model checking completed. No error has been found." in output:
        depth = re.search(r"depth of the complete state graph search is (\d+)",
                          output)
        return [stuck_report(cores, obs, without, model,
                             int(depth.group(1)) if depth else 0)], counts
    raise TraceError("TLC gave no verdict:\n" + output[-4000:])


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("uart_log")
    parser.add_argument("--without", choices=ACTIONS)
    parser.add_argument("--model", action="append", default=[],
                        metavar="NAME=BOOL")
    args = parser.parse_args()
    model = {}
    for item in args.model:
        name, _, flag = item.partition("=")
        if name not in MODEL_CONSTANTS or flag not in ("TRUE", "FALSE"):
            parser.error(f"--model takes one of {', '.join(MODEL_CONSTANTS)}"
                         f"=TRUE|FALSE, not {item}")
        model[name] = flag == "TRUE"
    with open(args.uart_log, encoding="utf-8", errors="replace") as log:
        lines = [line.rstrip("\r\n") for line in log]
    try:
        cores, total, holds = parse(lines)
        errors, counts = check(cores, holds, args.without, model)
    except TraceError as error:
        print(f"FAIL protocol-trace: {error}")
        return 1
    for error in errors:
        print(f"ERROR protocol-trace: {error}")
    if errors:
        print("FAIL protocol-trace: the kernel made a step "
              "kernel/models/StackOwnership.tla does not allow (checked by "
              "TLC through StackOwnershipTrace.tla)")
        return 1
    unseen = [" or ".join(step) for step in REQUIRED
              if args.without not in step
              and not any(counts[name] for name in step)]
    if unseen:
        print("FAIL protocol-trace: the window never exercised "
              f"{', '.join(unseen)}, so a PASS would say nothing about it")
        return 1
    steps = sum(counts.values())
    seen = ", ".join(f"{name}={count}" for name, count in counts.items())
    print(f"PASS protocol-trace: TLC matched {steps} step(s) over "
          f"{len(holds)} changed hold(s) of {total}, on {cores} core(s), to a "
          f"behaviour of StackOwnership.tla with its invariants and "
          f"WaitMatchesState intact ({seen})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
