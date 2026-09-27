#!/usr/bin/env python3
"""Replay a kernel protocol-trace window against StackOwnership.tla.

GitHub issue #606, stage 1. /bin/protocol-trace opens a window in which the
kernel diffs the stack-ownership state at every hold of the process-run
lock (kernel/kernel/protocol_trace.tkb) and prints the changes when the
window closes. This replays them, one hold at a time, against the actions of
kernel/models/StackOwnership.tla, written again here with the same names,
enabling conditions and effects, generalized from the model's two cores and
one parent/child pair to every core and process the window saw.

It fails when:
- a hold's changes are the effect of no model action ("a step no model
  action describes");
- they have an action's shape but not its enabling condition
  ("ChildExitStart not enabled: owner[parent] = c1");
- an invariant fails after a step: StackSafety, RunningMatchesCores,
  StartsOnFreeStack;
- the window lost events, or a change the model cares about was made while
  nobody held the run lock;
- an action the probe is written to exercise was never observed, which
  would make a PASS say nothing about it.

What a PASS claims is narrow: every protocol transition the kernel made in
this window is one the model has. It does not claim the model is right, and
it says nothing about paths the window did not run.

What the replay leaves out, and why (the model's own "dropped" discipline):
- which child a wait4 waits for, and who reaps a zombie: the trace carries
  no parent link. Irrelevant to StackSafety: neither moves a stack.
- affinity: it only forbids steps, and the replay allows each one.
- allocation: a record appearing Constructing is taken in wherever the
  diff sees it, since the pool's lock, not the run lock, orders it.
  Irrelevant to StackSafety: a Constructing record owns no stack and is
  nobody's current process until CloneBegin.

The kernel's state codes: 1 Ready, 2 Running, 3 Blocked, 4 Exited,
5 Constructing; a Blocked process whose wait reason is 2 (ChildExit) is the
model's "Blocked", any other is "Napping".

Usage: validate_protocol_trace.py UART_LOG [--without ACTION]
--without drops one action from the replay: the negative control that a
path the model lacked fails a passing run.

Exit code only (0 = pass, 1 = fail).
"""

import argparse
import dataclasses
import re
import sys

LINE_RE = re.compile(r"^protocol-trace: (.*)$")
BEGIN_RE = re.compile(
    r"^begin cores=(\d+) stored=(\d+) lost=(\d+) holds=(\d+)$")
STATES = {1: "Ready", 2: "Running", 3: "Blocked", 4: "Exited",
          5: "Constructing"}
WAIT_CHILD_EXIT = 2

# What /bin/protocol-trace is written to make the kernel do. An action in
# the model and not here may legitimately not happen in a given window.
REQUIRED = ("CloneBegin", "CloneFinish", "SwitchComplete", "Reserve",
            "Commit", "SwitchAway", "Wait4Block", "Wake", "ChildExit",
            "ChildExitStart", "IdleEnter", "Wait4Reap", "LeaveBegin",
            "LeaveComplete")

NONE = None
IDLE = "idle"


class TraceError(Exception):
    pass


@dataclasses.dataclass
class World:
    state: dict       # pid -> model state name
    owner: dict       # pid -> core or None
    current: dict     # core -> pid or None
    stands: dict      # core -> pid or IDLE
    reserved: dict    # core -> pid or None
    interrupted: dict  # core -> inside an interrupt taken from EL0
    reap_pending: dict  # parent pid -> exited child pid

    def copy(self):
        return World(dict(self.state), dict(self.owner), dict(self.current),
                     dict(self.stands), dict(self.reserved),
                     dict(self.interrupted), dict(self.reap_pending))


@dataclasses.dataclass
class Hold:
    sequence: int
    cpu: int
    unlocked: bool
    processes: dict   # pid -> (state, owner)
    gone: set
    cores: dict       # core -> (current, stands)


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
        raise TraceError(f"the window lost {lost} change(s); a replay with "
                         "a gap in it proves nothing")
    if len(events) != stored:
        raise TraceError(f"the header says {stored} change(s) and "
                         f"{len(events)} arrived")
    steps = {}
    for text in events:
        fields = text.split()
        if len(fields) < 4:
            raise TraceError(f"malformed change: {text}")
        sequence, cpu, lock, kind = int(fields[0]), int(fields[1]), \
            fields[2], fields[3]
        key = (sequence, lock == "u")
        hold = steps.setdefault(
            key, Hold(sequence, cpu, lock == "u", {}, set(), {}))
        if kind == "p" and len(fields) == 8:
            pid = int(fields[4])
            hold.processes[pid] = (
                model_state(int(fields[5]), int(fields[7])),
                value(fields[6]))
        elif kind == "g" and len(fields) == 7:
            hold.gone.add(int(fields[4]))
        elif kind == "c" and len(fields) == 7:
            core = int(fields[4])
            stands = value(fields[6])
            hold.cores[core] = (value(fields[5]),
                                IDLE if stands is None else stands)
        else:
            raise TraceError(f"malformed change: {text}")
    ordered = [steps[key] for key in sorted(steps,
                                            key=lambda k: (k[0], not k[1]))]
    return cores, holds, ordered


def initial_world(hold, cores):
    if hold.sequence != 0 or hold.unlocked:
        raise TraceError("the window does not start with its snapshot")
    world = World({}, {}, {}, {}, {}, {}, {})
    for pid, (state, owner) in hold.processes.items():
        world.state[pid] = state
        world.owner[pid] = owner
    for core in range(cores):
        if core not in hold.cores:
            raise TraceError(f"the snapshot has no line for core {core}")
        world.current[core], world.stands[core] = hold.cores[core]
        world.reserved[core] = None
        # A core the window opens inside an EL0 interrupt: its current
        # process runs and it stands on its IRQ stack.
        current = world.current[core]
        world.interrupted[core] = (
            current is not None and world.stands[core] == IDLE
            and world.state.get(current) == "Running")
    return world


# --------------------------------------------------------------------------
# The model's actions. Each takes the world before a hold and the hold's
# changes, and returns None when the changes do not have the action's
# shape, a string naming the enabling condition that fails, or the world
# the action produces. The caller compares that with the world the kernel
# reported.


def changed(world, hold):
    """Processes and cores whose reported value differs from the world."""
    procs = {pid: new for pid, new in hold.processes.items()
             if (world.state.get(pid), world.owner.get(pid)) != new}
    cores = {core: new for core, new in hold.cores.items()
             if (world.current.get(core), world.stands.get(core)) != new}
    return procs, cores


def settled(world, core, pid):
    return world.current[core] == pid and world.stands[core] == pid


def departed(world, core, pid):
    return (world.interrupted[core] and world.current[core] == pid
            and world.stands[core] == IDLE and world.owner.get(pid) is None)


def takeable(world, pid):
    if world.state.get(pid) != "Ready":
        return f"state[{pid}] = {world.state.get(pid)}"
    if world.owner.get(pid) is not None:
        return f"owner[{pid}] = c{world.owner[pid]}"
    child = world.reap_pending.get(pid)
    if child is not None and world.owner.get(child) is not None:
        return f"owner[{child}] = c{world.owner[child]} (reap pending)"
    return None


def only(mapping):
    return next(iter(mapping.items())) if len(mapping) == 1 else None


def clone_begin(world, hold, procs, cores):
    one = only(cores)
    if procs or hold.gone or not one:
        return None
    core, (current, stands) = one
    parent = world.current[core]
    if stands != world.stands[core] or current is None or parent is None \
            or world.state.get(current) != "Constructing":
        return None
    if not settled(world, core, parent):
        return f"current[c{core}] # stands[c{core}]"
    if world.reserved[core] is not None:
        return f"reserved[c{core}] = {world.reserved[core]}"
    after = world.copy()
    after.current[core] = current
    return after


def clone_finish(world, hold, procs, cores):
    if cores or hold.gone or len(procs) != 2:
        return None
    child = [p for p, (s, _) in procs.items()
             if world.state.get(p) == "Constructing" and s == "Running"]
    parent = [p for p, (s, _) in procs.items()
              if world.state.get(p) == "Running" and s == "Ready"]
    if len(child) != 1 or len(parent) != 1:
        return None
    child, parent = child[0], parent[0]
    at = [c for c in world.current if world.current[c] == child]
    if not at:
        return "the child is no core's current process"
    if world.stands[at[0]] != parent:
        return f"stands[c{at[0]}] = {world.stands[at[0]]}, not the parent"
    after = world.copy()
    after.state[child] = "Running"
    after.state[parent] = "Ready"
    return after


def switch_complete(world, hold, procs, cores):
    one = only(cores)
    if hold.gone or not one:
        return None
    core, (current, stands) = one
    incoming = world.current[core]
    outgoing = world.stands[core]
    if current != incoming or incoming is None or stands != incoming \
            or outgoing == incoming:
        return None
    if world.state.get(incoming) != "Running":
        return f"state[{incoming}] = {world.state.get(incoming)}"
    if world.owner.get(incoming) is not None:
        return f"owner[{incoming}] = c{world.owner[incoming]}"
    after = world.copy()
    after.owner[incoming] = core
    if outgoing != IDLE:
        after.owner[outgoing] = None
    after.stands[core] = incoming
    after.interrupted[core] = False
    return after


def core_condition(world, core):
    current = world.current[core]
    if current is not None and world.state.get(current) == "Running":
        return None
    if current is None and world.stands[core] == IDLE:
        return None
    return (f"c{core} neither runs a process nor stands on its idle stack "
            f"(current {current}, stands {world.stands[core]})")


def reserve(world, hold, procs, cores):
    one = only(procs)
    if cores or hold.gone or not one:
        return None
    pid, (state, owner) = one
    if world.state.get(pid) != "Ready" or state != "Running" \
            or owner != world.owner.get(pid):
        return None
    core = hold.cpu
    if world.reserved[core] is not None:
        return f"reserved[c{core}] = {world.reserved[core]}"
    why = core_condition(world, core) or takeable(world, pid)
    if why:
        return why
    after = world.copy()
    after.state[pid] = "Running"
    after.reserved[core] = pid
    return after


def commit(world, hold, procs, cores):
    one = only(cores)
    if procs or hold.gone or not one:
        return None
    core, (current, stands) = one
    before = world.current[core]
    if stands != world.stands[core] or current is None:
        return None
    if before is not None and world.state.get(before) != "Exited":
        return None
    if world.reserved[core] != current:
        return f"reserved[c{core}] = {world.reserved[core]}, not {current}"
    after = world.copy()
    after.current[core] = current
    after.reserved[core] = None
    return after


def switch_away(world, hold, procs, cores):
    one_core, one_proc = only(cores), only(procs)
    if hold.gone or not one_core or not one_proc:
        return None
    core, (current, stands) = one_core
    pid, (state, owner) = one_proc
    if pid != world.current[core] or current is None or current == pid \
            or stands != world.stands[core] or owner != world.owner.get(pid) \
            or world.state.get(pid) != "Running" \
            or state not in ("Ready", "Napping", "Blocked"):
        return None
    if world.reserved[core] != current:
        return f"reserved[c{core}] = {world.reserved[core]}, not {current}"
    if not settled(world, core, pid) and not departed(world, core, pid):
        return f"c{core} neither settled on {pid} nor inside an interrupt"
    if state == "Blocked" and pid in world.reap_pending:
        return f"{pid} has a wake pending"
    after = world.copy()
    after.state[pid] = state
    after.current[core] = current
    after.reserved[core] = None
    return after


def block_to_idle(name, blocked):
    def action(world, hold, procs, cores):
        one_core, one_proc = only(cores), only(procs)
        if hold.gone or not one_core or not one_proc:
            return None
        core, (current, stands) = one_core
        pid, (state, owner) = one_proc
        if current is not None or pid != world.current[core] \
                or stands != world.stands[core] \
                or owner != world.owner.get(pid) \
                or world.state.get(pid) != "Running" or state != blocked:
            return None
        if not settled(world, core, pid):
            return f"current[c{core}] # stands[c{core}]"
        if world.reserved[core] is not None:
            return f"reserved[c{core}] = {world.reserved[core]}"
        if blocked == "Blocked" and pid in world.reap_pending:
            return f"{pid} has a wake pending"
        after = world.copy()
        after.state[pid] = blocked
        after.current[core] = None
        return after
    action.__name__ = name
    return action


def wake(world, hold, procs, cores):
    one = only(procs)
    if cores or hold.gone or not one:
        return None
    pid, (state, owner) = one
    if world.state.get(pid) != "Napping" or state != "Ready" \
            or owner != world.owner.get(pid):
        return None
    after = world.copy()
    after.state[pid] = "Ready"
    return after


def exit_parts(world, procs):
    exited = [p for p, (s, o) in procs.items()
              if world.state.get(p) == "Running" and s == "Exited"
              and o == world.owner.get(p)]
    return exited[0] if len(exited) == 1 else None


def child_exit(world, hold, procs, cores):
    one_core = only(cores)
    if hold.gone or not one_core or len(procs) not in (1, 2):
        return None
    core, (current, stands) = one_core
    child = exit_parts(world, procs)
    if child is None or current is not None or child != world.current[core] \
            or stands != world.stands[core]:
        return None
    woken = [p for p in procs if p != child]
    if woken:
        parent = woken[0]
        state, owner = procs[parent]
        if world.state.get(parent) != "Blocked" or state != "Ready" \
                or owner != world.owner.get(parent):
            return None
    if not settled(world, core, child):
        return f"current[c{core}] # stands[c{core}]"
    if world.reserved[core] is not None:
        return f"reserved[c{core}] = {world.reserved[core]}"
    after = world.copy()
    after.state[child] = "Exited"
    after.current[core] = None
    if woken:
        after.state[woken[0]] = "Ready"
        after.reap_pending[woken[0]] = child
    return after


def child_exit_start(world, hold, procs, cores):
    if cores or hold.gone or len(procs) != 2:
        return None
    child = exit_parts(world, procs)
    if child is None:
        return None
    parent = next(p for p in procs if p != child)
    state, owner = procs[parent]
    if world.state.get(parent) != "Blocked" or state != "Running" \
            or owner != world.owner.get(parent):
        return None
    at = [c for c in world.current if world.current[c] == child]
    if not at:
        return "the child is no core's current process"
    core = at[0]
    if not settled(world, core, child):
        return f"current[c{core}] # stands[c{core}]"
    if world.reserved[core] is not None:
        return f"reserved[c{core}] = {world.reserved[core]}"
    if world.owner.get(parent) is not None:
        return f"owner[parent] = c{world.owner[parent]}"
    after = world.copy()
    after.state[child] = "Exited"
    after.state[parent] = "Running"
    after.reserved[core] = parent
    after.reap_pending[parent] = child
    return after


def idle_enter(world, hold, procs, cores):
    one_core, one_proc = only(cores), only(procs)
    if hold.gone or not one_core or not one_proc:
        return None
    core, (current, stands) = one_core
    pid, (state, owner) = one_proc
    if stands != IDLE or current != world.current[core] \
            or pid != world.stands[core] or state != world.state.get(pid) \
            or owner is not None:
        return None
    if world.current[core] is not None:
        return f"current[c{core}] = {world.current[core]}"
    if world.reserved[core] is not None:
        return f"reserved[c{core}] = {world.reserved[core]}"
    if state == "Running":
        return f"state[{pid}] = Running"
    if world.owner.get(pid) != core:
        return f"owner[{pid}] = {world.owner.get(pid)}, not c{core}"
    after = world.copy()
    after.owner[pid] = None
    after.stands[core] = IDLE
    return after


def wait4_reap(world, hold, procs, cores):
    if procs or cores or len(hold.gone) != 1:
        return None
    pid = next(iter(hold.gone))
    if world.state.get(pid) != "Exited":
        return f"state[{pid}] = {world.state.get(pid)}"
    if world.owner.get(pid) is not None:
        return f"owner[{pid}] = c{world.owner[pid]}"
    after = world.copy()
    del after.state[pid]
    del after.owner[pid]
    for parent, child in world.reap_pending.items():
        if child == pid:
            del after.reap_pending[parent]
    return after


def leave_begin(world, hold, procs, cores):
    one = only(cores)
    if procs or hold.gone or not one:
        return None
    core, (current, stands) = one
    pid = world.current[core]
    if current is not None or pid is None or stands != world.stands[core] \
            or world.state.get(pid) != "Running":
        return None
    if world.reserved[core] is not None:
        return f"reserved[c{core}] = {world.reserved[core]}"
    if world.stands[core] != pid:
        return f"stands[c{core}] = {world.stands[core]}, not {pid}"
    after = world.copy()
    after.current[core] = None
    return after


def leave_complete(world, hold, procs, cores):
    one_core, one_proc = only(cores), only(procs)
    if hold.gone or not one_core or not one_proc:
        return None
    core, (current, stands) = one_core
    pid, (state, owner) = one_proc
    if stands != IDLE or current is not None or pid != world.stands[core] \
            or world.state.get(pid) != "Running" or state != "Ready" \
            or owner is not None:
        return None
    if world.current[core] is not None:
        return f"current[c{core}] = {world.current[core]}"
    if world.reserved[core] is not None:
        return f"reserved[c{core}] = {world.reserved[core]}"
    after = world.copy()
    after.state[pid] = "Ready"
    after.owner[pid] = None
    after.stands[core] = IDLE
    return after


def interrupt_depart(world, hold, procs, cores):
    one_core, one_proc = only(cores), only(procs)
    if hold.gone or not one_core or not one_proc:
        return None
    core, (current, stands) = one_core
    pid, (state, owner) = one_proc
    if stands != IDLE or current != pid or world.current[core] != pid \
            or state != world.state.get(pid) or owner is not None \
            or world.stands[core] != pid:
        return None
    if state != "Running":
        return f"state[{pid}] = {state}"
    if world.reserved[core] is not None:
        return f"reserved[c{core}] = {world.reserved[core]}"
    if world.owner.get(pid) != core:
        return f"owner[{pid}] = {world.owner.get(pid)}, not c{core}"
    after = world.copy()
    after.owner[pid] = None
    after.stands[core] = IDLE
    after.interrupted[core] = True
    return after


def tick_leave(world, hold, procs, cores):
    one_core, one_proc = only(cores), only(procs)
    if hold.gone or not one_core or not one_proc:
        return None
    core, (current, stands) = one_core
    pid, (state, owner) = one_proc
    if current is not None or stands != world.stands[core] \
            or world.current[core] != pid or state != "Ready" \
            or owner != world.owner.get(pid) \
            or world.state.get(pid) != "Running":
        return None
    if not departed(world, core, pid):
        return f"c{core} is not inside an interrupt, off {pid}'s stack"
    if world.reserved[core] is not None:
        return f"reserved[c{core}] = {world.reserved[core]}"
    after = world.copy()
    after.state[pid] = "Ready"
    after.current[core] = None
    after.interrupted[core] = False
    return after


ACTIONS = {
    "CloneBegin": clone_begin,
    "CloneFinish": clone_finish,
    "SwitchComplete": switch_complete,
    "Reserve": reserve,
    "Commit": commit,
    "SwitchAway": switch_away,
    "Wait4Block": block_to_idle("Wait4Block", "Blocked"),
    "Nap": block_to_idle("Nap", "Napping"),
    "Wake": wake,
    "ChildExit": child_exit,
    "ChildExitStart": child_exit_start,
    "IdleEnter": idle_enter,
    "Wait4Reap": wait4_reap,
    "LeaveBegin": leave_begin,
    "LeaveComplete": leave_complete,
    "InterruptDepart": interrupt_depart,
    "TickLeave": tick_leave,
}


# --------------------------------------------------------------------------
# Invariants, as the .tla states them over this world.


def invariants(world):
    cores = sorted(world.current)
    for core in cores:
        stood = world.stands[core]
        if stood != IDLE and world.owner.get(stood) != core:
            return (f"StackSafety: c{core} stands on {stood}, owned by "
                    f"{world.owner.get(stood)}")
    for pid, state in world.state.items():
        if state == "Running" and not any(
                pid in (world.current[c], world.reserved[c], world.stands[c])
                for c in cores):
            return f"RunningMatchesCores: {pid} is Running and no core holds it"
    for c in cores:
        for d in cores:
            if c == d:
                continue
            if world.current[c] is not None and \
                    world.current[c] in (world.current[d], world.reserved[d]):
                return (f"RunningMatchesCores: {world.current[c]} is held by "
                        f"c{c} and c{d}")
            if world.reserved[c] is not None and \
                    world.reserved[c] == world.reserved[d]:
                return (f"RunningMatchesCores: {world.reserved[c]} reserved "
                        f"by c{c} and c{d}")
        if world.reserved[c] is not None and \
                world.state.get(world.reserved[c]) != "Running":
            return f"RunningMatchesCores: c{c} reserved a non-Running process"
        if world.current[c] is not None and world.state.get(
                world.current[c]) not in ("Running", "Constructing", "Exited"):
            return (f"RunningMatchesCores: c{c}'s current process "
                    f"{world.current[c]} is {world.state.get(world.current[c])}")
    for c in cores:
        for held in (world.current[c], world.reserved[c]):
            if held is not None and world.owner.get(held) not in (None, c):
                return (f"StartsOnFreeStack: c{c} holds {held}, whose stack "
                        f"c{world.owner[held]} owns")
    return None


def absorb_allocations(world, hold):
    """Take in the records that appeared Constructing, and drop them.

    Allocation inserts a record under the pool's lock, not the run lock,
    so the diff sees it at whichever hold comes next -- an acquire, or the
    release of an unrelated hold on another CPU. It is not a model step:
    the model's child exists, Constructing, from the start.
    """
    for pid, (state, owner) in list(hold.processes.items()):
        if pid not in world.state and state == "Constructing" \
                and owner is None:
            world.state[pid] = state
            world.owner[pid] = owner
            del hold.processes[pid]


def unlocked_errors(world, hold):
    """What changed with no lock held; only allocation may."""
    procs, cores = changed(world, hold)
    errors = []
    for pid, (state, owner) in procs.items():
        errors.append(f"{pid} changed to {state}/{owner} with no lock held")
    if cores or hold.gone:
        errors.append("a core or the pool changed with no lock held")
    return errors


def replay(cores, holds, without=None):
    """(errors, counts): every problem found, and each action's count."""
    world = initial_world(holds[0], cores)
    counts = {name: 0 for name in ACTIONS}
    errors = []
    why = invariants(world)
    if why:
        return [f"sequence 0: the snapshot already violates {why}"], counts
    for hold in holds[1:]:
        where = f"sequence {hold.sequence} (cpu {hold.cpu})"
        absorb_allocations(world, hold)
        if hold.unlocked:
            errors += [f"{where}: {e}" for e in unlocked_errors(world, hold)]
            continue
        procs, cores_changed = changed(world, hold)
        if not procs and not cores_changed and not hold.gone:
            continue
        reported = world.copy()
        for pid, (state, owner) in hold.processes.items():
            reported.state[pid] = state
            reported.owner[pid] = owner
        for pid in hold.gone:
            reported.state.pop(pid, None)
            reported.owner.pop(pid, None)
        for core, (current, stands) in hold.cores.items():
            reported.current[core] = current
            reported.stands[core] = stands
        matched = None
        refusals = []
        for name, action in ACTIONS.items():
            if name == without:
                continue
            result = action(world, hold, procs, cores_changed)
            if result is None:
                continue
            if isinstance(result, str):
                refusals.append(f"{name} not enabled: {result}")
                continue
            if (result.state, result.owner, result.current, result.stands) \
                    == (reported.state, reported.owner, reported.current,
                        reported.stands):
                matched = (name, result)
                break
        if matched is None:
            detail = "; ".join(refusals) if refusals else \
                "a step no model action describes: " + \
                f"processes {procs}, cores {cores_changed}, gone " \
                f"{sorted(hold.gone)}"
            errors.append(f"{where}: {detail}")
            return errors, counts
        name, world = matched
        counts[name] += 1
        why = invariants(world)
        if why:
            errors.append(f"{where}: after {name}, {why}")
            return errors, counts
    return errors, counts


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("uart_log")
    parser.add_argument("--without", choices=sorted(ACTIONS))
    args = parser.parse_args()
    with open(args.uart_log, encoding="utf-8", errors="replace") as log:
        lines = [line.rstrip("\r\n") for line in log]
    try:
        cores, total, holds = parse(lines)
        errors, counts = replay(cores, holds, args.without)
    except TraceError as error:
        print(f"FAIL protocol-trace: {error}")
        return 1
    for error in errors:
        print(f"ERROR protocol-trace: {error}")
    if errors:
        print("FAIL protocol-trace: the kernel made a step "
              "kernel/models/StackOwnership.tla does not allow")
        return 1
    unseen = [name for name in REQUIRED
              if name != args.without and counts[name] == 0]
    if unseen:
        print("FAIL protocol-trace: the window never exercised "
              f"{', '.join(unseen)}, so a PASS would say nothing about it")
        return 1
    steps = sum(counts.values())
    seen = ", ".join(f"{name}={count}" for name, count in counts.items())
    print(f"PASS protocol-trace: {steps} step(s) over {len(holds)} changed "
          f"hold(s) of {total}, on {cores} core(s), each a "
          f"StackOwnership.tla action with its invariants intact ({seen})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
