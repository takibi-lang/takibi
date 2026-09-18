#!/usr/bin/env python3
"""Controls for the known-intermittent open-issue gate, with no GitHub.

The gate itself asks GitHub, and a control that did the same would be testing
the network. What rots is the part that decides a VERDICT from an answer: a
closed issue must fail, an unreturned number must fail rather than be read as
open, an empty table must not reach the network at all, and an unreachable
GitHub must fail rather than pass about something it did not check.

So the answer is injected here and the verdict is read back, offline. This is
a `check_` member on purpose: it waits on nothing.
"""

import importlib.util
import io
import pathlib
import sys
import tempfile
from contextlib import redirect_stdout

from pass_line import CaseCount, report_pass

ROOT = pathlib.Path(__file__).resolve().parent.parent
GATE = ROOT / "scripts" / "slowcheck_known_intermittent_issues.py"

HEADER = ("| Symptom | Rate | Issue | Last seen |\n"
          "| --- | --- | --- | --- |\n")
ROW = ("| `process table: records MISSING uses=` | 2 in 16 runs | #%d | "
       "2026-09-17 |\n")


def load():
    """The gate, plus the module that actually owns the table's path.

    `intermittent_rows` lives in find_stale_issue_workarounds and reads that
    module's own INTERMITTENTS, so a planted table has to be planted there.
    Returned explicitly rather than reached for through the gate, because a
    control that patched only the name the gate holds would plant a table
    nothing reads and then pass about the real one.
    """
    sys.path.insert(0, str(ROOT / "scripts"))
    spec = importlib.util.spec_from_file_location("gate", GATE)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module, sys.modules["find_stale_issue_workarounds"]


# GitHub issue #526: a control asserts the number of scenarios it ran.
CASES = CaseCount()


def verdict(pair, table, states):
    """Run the gate over a planted table with a planted GitHub answer.

    `states` is a dict, or an exception instance to raise instead -- which is
    how the unreachable case is exercised without unplugging anything.
    """
    CASES.note()
    gate, finder = pair
    asked = []

    def fake_states():
        asked.append(True)
        if isinstance(states, Exception):
            raise states
        return states

    with tempfile.TemporaryDirectory() as raw:
        path = pathlib.Path(raw) / "KNOWN_INTERMITTENTS.md"
        path.write_text(table, encoding="ascii")
        saved = (gate.INTERMITTENTS, gate.issue_states, gate.ROOT,
                 finder.INTERMITTENTS)
        gate.INTERMITTENTS = finder.INTERMITTENTS = path
        gate.ROOT = path.parent
        gate.issue_states = fake_states
        captured = io.StringIO()
        try:
            with redirect_stdout(captured):
                status = gate.main()
        finally:
            (gate.INTERMITTENTS, gate.issue_states, gate.ROOT,
             finder.INTERMITTENTS) = saved
    return status, captured.getvalue(), bool(asked)


def expect(name, got, want_status, want_text, want_asked):
    status, report, asked = got
    failures = []
    if status != want_status:
        failures.append(f"{name}: exited {status}, wanted {want_status} "
                        f"({report.strip()!r})")
    elif want_text and want_text not in report:
        failures.append(f"{name}: reported {report.strip()!r}, which does not "
                        f"name {want_text!r}")
    if asked != want_asked:
        failures.append(f"{name}: {'asked' if asked else 'did not ask'} "
                        f"GitHub, wanted the opposite")
    return failures


def main() -> int:
    pair = load()
    failures = []

    # An open issue is the passing case, and the one that must not be
    # confused with "GitHub said nothing about it".
    failures += expect(
        "a row naming an open issue",
        verdict(pair, HEADER + ROW % 514, {514: "OPEN"}),
        0, "1 known intermittent(s)", True)

    # The rot this gate exists for.
    failures += expect(
        "a row naming a closed issue",
        verdict(pair, HEADER + ROW % 514, {514: "CLOSED"}),
        1, "is CLOSED and still owns the row", True)

    # Silence is not agreement. A number GitHub does not return may be a pull
    # request or may not exist; reading it as open would make a typo look
    # like a live attribution.
    failures += expect(
        "a row GitHub returns nothing about",
        verdict(pair, HEADER + ROW % 514, {999: "OPEN"}),
        1, "not evidence", True)

    # An empty table is the goal state AND must cost no request: a tree with
    # nothing to look up should not be able to fail on a network outage.
    failures += expect(
        "an empty table",
        verdict(pair, HEADER, {}),
        0, "no issue state was asked for", False)

    # And the deliberate part: unable to ask is a failure, not a pass.
    failures += expect(
        "GitHub unreachable with rows to judge",
        verdict(pair, HEADER + ROW % 514,
                pair[0].IssueStatesUnavailable("gh: not authenticated")),
        1, "could not read issue states", True)

    # The same outage over an empty table still costs nothing and passes,
    # which is what keeps the gate's cost proportional to what it guards.
    failures += expect(
        "GitHub unreachable with nothing to judge",
        verdict(pair, HEADER,
                pair[0].IssueStatesUnavailable("gh: not authenticated")),
        0, "no issue state was asked for", False)

    for failure in failures:
        print(f"ERROR\tknown-intermittent-issues-controls: {failure}")
    if failures:
        print("FAIL known-intermittent-issues controls: the gate's verdict "
              "does not follow from the answer it was given")
        return 1
    report_pass(
        "known-intermittent-issues controls",
        "an open issue passes, a closed one fails, a number GitHub returns "
        "nothing about fails rather than reading as open, an unreachable "
        "GitHub fails rather than passing about what it did not check, and "
        "an empty table passes without asking at all",
        cases=CASES.ran)
    return 0


if __name__ == "__main__":
    sys.exit(main())
