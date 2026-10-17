#!/usr/bin/env python3
"""Controls for the protocol-trace report parser (GitHub issue #606).

scripts/validate_protocol_trace.py parses a protocol-trace window into the
module TLC checks against kernel/models/StackOwnershipTrace.tla. The
protocol refusals need TLC and run in `make modelcheck`
(scripts/protocol_trace_tlc_controls.py). These are the ones that need
nothing but the parser, in this process, with no child: what the parser
refuses about the REPORT, and the bookkeeping conventions the generated
module rests on. A parser that quietly stopped reading would turn the TLC
check into a check of nothing.

It also holds three lists to one another, since a drift between them makes
a negative control vacuous: the actions of StackOwnership.tla's Next, the
actions StackOwnershipTrace.tla's ModelStep offers by name (`Allowed`), and
the validator's ACTIONS, which `--without` accepts. A `--without` naming an
action the trace spec does not label would remove nothing and still be
"refused" by whatever else broke.
"""

import importlib.util
import re
import sys
from pathlib import Path

from pass_line import CaseCount, report_pass

ROOT = Path(__file__).resolve().parent.parent
VALIDATOR = ROOT / "scripts" / "validate_protocol_trace.py"
_spec = importlib.util.spec_from_file_location("validate_protocol_trace", VALIDATOR)
V = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(V)
MODEL = ROOT / "kernel" / "models" / "StackOwnership.tla"
TRACE_SPEC = ROOT / "kernel" / "models" / "StackOwnershipTrace.tla"
WINDOW = ROOT / "kernel" / "tests" / "qemu" / "protocol_trace.window"

CASES = CaseCount()


def window(changes, lost=0, end=True, holds=10, stored=None):
    stored = len(changes) if stored is None else stored
    lines = [f"protocol-trace: begin cores=2 stored={stored} "
             f"lost={lost} holds={holds}"]
    lines += [f"protocol-trace: {change}" for change in changes]
    if end:
        lines.append("protocol-trace: end")
    return lines


SNAPSHOT = [
    "0 0 l p 10 2 0 0 -",
    "0 0 l p 11 5 - 0 10",
    "0 0 l c 0 10 10",
    "0 0 l c 1 - -",
]


def refusal(name, lines, needle):
    CASES.note()
    try:
        cores, _, holds = V.parse(lines)
        V.observations(cores, holds)
    except V.TraceError as error:
        if needle in str(error):
            return True
        print(f"FAIL validate-protocol-trace controls: {name}: refused with "
              f"{error!r}, expected {needle!r}")
        return False
    print(f"FAIL validate-protocol-trace controls: {name}: accepted, "
          f"expected a refusal saying {needle!r}")
    return False


def holds_true(name, condition, detail=""):
    CASES.note()
    if not condition:
        print(f"FAIL validate-protocol-trace controls: {name} {detail}")
    return bool(condition)


def model_next_actions(text):
    body = text.split("\nNext ==", 1)[1].split("\n\n", 1)[0]
    return set(re.findall(r"\b([A-Z]\w+)\(", body)) - {"SF_vars", "WF_vars"}


def main() -> int:
    obs_lines = window(SNAPSHOT + [
        # 12 appears later as a fresh record: Constructing from the start.
        "1 1 u p 12 5 - 0 -", "1 1 l p 12 5 - 0 10",
        # 13 appears later already Running: Absent until then.
        "2 1 l p 13 2 - 0 10",
        # An unlocked line's wait reason is not the published one.
        "3 0 u p 10 2 0 4 -",
        # The kernel clears 11's link as it removes the record.
        "4 0 u p 11 4 - 0 -", "4 0 l g 11 0 0",
    ])
    cores, _, holds = V.parse(obs_lines)
    obs = V.observations(cores, holds)
    module = V.trace_module(cores, obs)
    model_text = MODEL.read_text(encoding="utf-8")
    trace_text = TRACE_SPEC.read_text(encoding="utf-8")
    allowed = set(re.findall(r'Allowed\("(\w+)"\)', trace_text))
    labelled = set(re.findall(r'act\' = "(\w+)"', trace_text)) - {"none"}
    in_next = model_next_actions(model_text)
    real_cores, _, real = V.parse(WINDOW.read_text(encoding="utf-8").splitlines())
    checks = [
        refusal("a window that lost changes", window(SNAPSHOT, lost=3),
                "lost 3 change(s)"),
        refusal("a report cut before its end", window(SNAPSHOT, end=False),
                "no end line"),
        refusal("a log with no window", ["takibi kernel: EL1"],
                "expected one protocol-trace window, found 0"),
        refusal("two windows", window(SNAPSHOT) + window(SNAPSHOT),
                "expected one protocol-trace window, found 2"),
        refusal("a header that miscounts", window(SNAPSHOT, stored=5),
                "the header says 5 change(s) and 4 arrived"),
        refusal("a malformed change", window(SNAPSHOT + ["1 0 l x 1"]),
                "malformed change: 1 0 l x 1"),
        refusal("a non-numeric field", window(SNAPSHOT + ["1 0 l p ten 2 0 0 -"]),
                "malformed change"),
        refusal("a snapshot missing a core", window(SNAPSHOT[:3]),
                "the snapshot has no line for core 1"),
        refusal("a window not opening with its snapshot",
                window(["1 0 l c 0 10 10"]),
                "does not start with its snapshot"),
        refusal("an unknown state code", window(SNAPSHOT + ["1 0 l p 10 9 0 0 -"]),
                "unknown process state code 9"),
        refusal("a reparented process",
                window(SNAPSHOT + ["1 0 l p 11 5 - 0 1"]),
                "11's parent changes from 10 to 1"),
        holds_true("a fresh record is Constructing from the window's start",
                   obs[0].state[12] == "Constructing" and obs[0].parent[12] == 10,
                   f"(got {obs[0].state[12]}, parent {obs[0].parent[12]})"),
        holds_true("a pid first seen Running is Absent until then",
                   obs[0].state[13] == "Absent" and obs[3].state[13] == "Running"),
        holds_true("an unlocked line's wait reason is not taken in",
                   obs[4].reason[10] == 0, f"(got {obs[4].reason[10]})"),
        holds_true("a removed record is Reaped, keeping its parent",
                   obs[-1].state[11] == "Reaped" and obs[-1].parent[11] == 10),
        holds_true("one record per hold, unlocked holds apart",
                   len(obs) == 7 and module.count("[seq |-> ") == 7
                   and module.count("locked |-> FALSE") == 3,
                   f"(got {len(obs)} observations)"),
        holds_true("the module names every core and process",
                   'TraceCores == {"c0", "c1"}' in module
                   and 'TraceProcs == {"p10", "p11", "p12", "p13"}' in module
                   and 'p12 |-> "p10"' in module),
        holds_true("the recorded QEMU window parses whole",
                   real_cores == 4 and len(real) == 53,
                   f"(got {real_cores} cores, {len(real)} holds)"),
        holds_true("the trace spec labels each action it offers",
                   allowed == labelled, f"(Allowed {sorted(allowed ^ labelled)})"),
        holds_true("the trace spec offers every action of StackOwnership's Next",
                   allowed == in_next,
                   f"(differ: {sorted(allowed ^ in_next)})"),
        holds_true("--without accepts exactly those actions",
                   set(V.ACTIONS) == in_next,
                   f"(differ: {sorted(set(V.ACTIONS) ^ in_next)})"),
        holds_true("every REQUIRED action is one of them",
                   {a for step in V.REQUIRED for a in step} <= in_next),
    ]
    if not all(checks):
        return 1
    report_pass(
        "validate-protocol-trace controls",
        "the parser refuses a lost change, a cut report, a missing or second "
        "window, a miscounted header, malformed and non-numeric lines, a "
        "snapshot missing a core or not first, an unknown state and a "
        "reparented process; a fresh record is Constructing from the start, a "
        "pid first seen otherwise is Absent, unlocked wait reasons are not "
        "taken in, a removed record is Reaped with its parent, one record per "
        "hold; and StackOwnership's Next, the trace spec's labelled actions "
        "and --without's choices are the same list",
        cases=CASES.ran, actions=len(in_next))
    return 0


if __name__ == "__main__":
    sys.exit(main())
