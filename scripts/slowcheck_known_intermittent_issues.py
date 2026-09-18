#!/usr/bin/env python3
"""Every row of the known-intermittent table cites an issue that is OPEN.

GitHub issue #565 asked for this as a check: closing an issue must force its
row to be removed or re-attributed, so the table cannot become a list of
excuses whose subjects are all fixed. The other half of that guard -- that a
row's symptom still exists in the tree -- is a tracked-file fact and lives in
scripts/check_known_intermittents.py, which `make langcheck` runs.

This half needs GitHub, which is why it is a `slowcheck_` member rather than
a `check_` one: `make langcheck` reads tracked files and nothing else, and a
member that waits on a socket there is killed rather than tolerated.

## It fails when it cannot ask, and that is the deliberate part

`make slowcheck` is inside `cicheck` and `allcheck`, so this makes both need
`gh` authenticated against the repository. The maintainer asked for that on
2026-09-18, and the reason it is defensible is narrow: a symptom-to-issue map
that nothing verifies is the exact failure this table was created to prevent,
and a gate that passes when it could not check is not a gate. The cost is
equally narrow and worth stating -- a GitHub outage, or a clone without `gh`
auth, reddens an aggregate for a reason unrelated to the change under test.

Two things keep that cost bounded. An empty table needs no request at all, so
a tree with nothing to look up never reaches the network. And the failure
message distinguishes "this row names a closed issue" from "GitHub could not
be asked", so a red lane says which of the two happened in its first line.

scripts/find_stale_issue_workarounds.py still asks the same question about
source comments, on demand and out of every build, because prose matching
makes its hits questions rather than defects. A table row is not a question:
it names one issue in a fixed column, and that issue is open or it is not.
"""

import pathlib
import sys

from find_stale_issue_workarounds import (
    INTERMITTENTS, IssueStatesUnavailable, intermittent_rows, issue_states)
from pass_line import report_pass

ROOT = pathlib.Path(__file__).resolve().parents[1]


def main() -> int:
    table = str(INTERMITTENTS.relative_to(ROOT))
    rows = list(intermittent_rows())
    problems = []

    # An empty table asks nothing. Skipping the request rather than making
    # one and finding it matched no row is what keeps this gate's cost
    # proportional to what it guards: a tree with nothing to look up cannot
    # be reddened by a GitHub outage.
    if rows:
        try:
            states = issue_states()
        except IssueStatesUnavailable as error:
            print(f"FAIL known-intermittent-issues: could not read issue "
                  f"states from GitHub, so the {len(rows)} row(s) in {table} "
                  f"could not be judged: {error}")
            print("  This needs `gh` authenticated against the repository. "
                  "It is a gate rather than a worklist, so it fails rather "
                  "than passing about something it did not check.")
            return 1
        for symptom, issue in rows:
            state = states.get(issue)
            if state is None:
                problems.append(
                    f"#{issue} (`{symptom}`) was not returned by GitHub: it "
                    f"may be a pull request, or may not exist. A row must "
                    f"name an issue, and NOT being told it is closed is not "
                    f"evidence that it is open")
            elif state == "CLOSED":
                problems.append(
                    f"#{issue} is CLOSED and still owns the row for "
                    f"`{symptom}`: remove the row, or re-attribute it to the "
                    f"issue that owns the symptom now")

    if problems:
        for problem in problems:
            print(f"ERROR\tknown-intermittent-issues: {problem}")
        print(f"FAIL known-intermittent-issues: {len(problems)} of "
              f"{len(rows)} row(s) do not name a live open issue")
        return 1

    # Counted as the rows judged plus the table itself, which is read whether
    # or not it has any. scripts/pass_line.py is right to refuse a bare zero
    # -- a verdict about nothing is not a verdict -- and an empty table is the
    # goal state rather than a scan that found no input, so say which it was.
    report_pass("known-intermittent-issues",
                (f"{len(rows)} known intermittent(s) each name an issue that "
                 f"is still open, so none is a row about something already "
                 f"fixed" if rows else
                 f"{table} lists no live intermittent, so no issue state was "
                 f"asked for"),
                claims=len(rows) + 1)
    return 0


if __name__ == "__main__":
    sys.exit(main())
