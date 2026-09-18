#!/usr/bin/env python3
"""The known-intermittent table must describe things that still exist.

GitHub issue #565: a red CI run was being re-diagnosed from scratch every
time, including by a reader who had all the evidence and simply could not
tell "this is the documented 1-in-8" from "this is new". The minute between
"CI is red" and "I know which question I am answering" is what
docs/KNOWN_INTERMITTENTS.md exists to remove.

The failure mode of a table like this is that it rots into a list of
excuses, so each row is held to two facts it cannot fake:

  - its SYMPTOM string still appears in a kernel source line, a view
    expectation or a runner/check under scripts/. A row whose symptom no
    longer exists anywhere is describing nothing, and is removed rather than
    left as a claim. ROADMAP.md and HISTORY.md do not count: they are
    narrative, and a symptom that survives only in them is a symptom the
    product stopped producing.
  - it names exactly one issue, and no two rows name the same one, so the
    table is a map from symptom to owner rather than a pile.

The other half of #565's guard -- that the issue is still OPEN -- is not
here, and cannot be: `make langcheck` members read tracked files and nothing
else, and a build that fails when GitHub is unreachable fails for a reason
unrelated to the change under test. That half lives in
scripts/find_stale_issue_workarounds.py, which already holds one network
call and already treats a hit as a question rather than a defect.

This check does NOT suppress or retry anything. Every lane still fails
rather than warns. A row here changes nothing about a red run except how
long it takes to know what it is.
"""

import datetime
import pathlib
import re
import sys

from pass_line import report_pass

ROOT = pathlib.Path(__file__).resolve().parents[1]
TABLE = ROOT / "docs" / "KNOWN_INTERMITTENTS.md"
ROADMAP = ROOT / "ROADMAP.md"

# Where a symptom may still be produced from. A row is a claim about the
# product, so the product is where it has to be visible.
SYMPTOM_TREES = (
    (ROOT / "kernel", ("*.tkb", "*.expected", "*.filter")),
    (ROOT / "scripts", ("*.py", "*.sh")),
)

# The rate may be empty here and is refused below by name, rather than
# rejected as an unreadable row: "you left the rate out" is the more
# useful of the two sentences, and an empty rate is the likely mistake.
ROW = re.compile(
    r"^\| `([^`]+)` \| ([^|]*) \| #(\d+) \| (\d{4}-\d{2}-\d{2}) \|$", re.M)
HEADER = "| Symptom | Rate | Issue | Last seen |"


def sources():
    """Every file a symptom may legitimately still live in."""
    for base, patterns in SYMPTOM_TREES:
        for pattern in patterns:
            for path in base.rglob(pattern):
                if path.is_file():
                    yield path


def main() -> int:
    if not TABLE.exists():
        print(f"FAIL known-intermittents: {TABLE.relative_to(ROOT)} is "
              f"missing; a red lane has nowhere to be looked up")
        return 1
    text = TABLE.read_text(encoding="ascii")
    problems = []

    if HEADER not in text:
        problems.append(
            f"the table header is not `{HEADER}`; this check reads those four "
            f"columns and they have moved")

    rows = ROW.findall(text)
    pipe_rows = [line for line in text.splitlines()
                 if line.startswith("| ") and not line.startswith("| ---")
                 and line != HEADER]
    if len(rows) != len(pipe_rows):
        unread = [line for line in pipe_rows if not ROW.match(line)]
        for line in unread:
            problems.append(
                f"this row is not in the checked shape "
                f"`| `symptom` | rate | #issue | YYYY-MM-DD |`, so nothing "
                f"holds it to anything: {line.strip()!r}")

    haystack = None
    if rows:
        haystack = {path: path.read_text(encoding="ascii", errors="replace")
                    for path in sources()}

    today = datetime.date.today()
    seen_issues = {}
    for symptom, rate, issue, last_seen in rows:
        where = [path for path, body in haystack.items() if symptom in body]
        if not where:
            problems.append(
                f"#{issue}'s symptom `{symptom}` appears in no kernel source "
                f"line, view expectation or runner: the row describes "
                f"something the tree no longer produces, so remove it or "
                f"re-attribute it")
        if not rate.strip():
            problems.append(f"#{issue} has no rate; say what was measured "
                            f"over what, or say it is unmeasured and why")
        if issue in seen_issues:
            problems.append(
                f"#{issue} owns two rows (`{seen_issues[issue]}` and "
                f"`{symptom}`); one issue is one row, or the symptoms belong "
                f"to different issues")
        seen_issues[issue] = symptom
        try:
            when = datetime.date.fromisoformat(last_seen)
        except ValueError:
            problems.append(f"#{issue}'s last-seen date `{last_seen}` is not "
                            f"a real date")
            continue
        if when > today:
            problems.append(
                f"#{issue} was last seen {last_seen}, which is in the "
                f"future: a typo, and the column that decides when a quiet "
                f"row may be retired on evidence")

    roadmap = ROADMAP.read_text(encoding="ascii")
    if "docs/KNOWN_INTERMITTENTS.md" not in roadmap:
        problems.append(
            "ROADMAP.md does not point at docs/KNOWN_INTERMITTENTS.md; it is "
            "rewritten wholesale and expected to go stale, so it must name "
            "the table rather than carry the list")

    if problems:
        for problem in problems:
            print(f"ERROR\tknown-intermittents: {problem}")
        print(f"FAIL known-intermittents: {len(problems)} row(s) do not "
              f"describe something that still exists")
        return 1
    # Counted as rows plus the two facts checked whether or not there are
    # any: the table's shape and the roadmap's pointer to it. An empty table
    # is the goal state, not a check that examined nothing, and
    # scripts/pass_line.py is right to refuse a bare zero -- so say what was
    # established instead of reporting a verdict about nothing.
    report_pass("known-intermittents",
                f"{len(rows)} known intermittent(s), each with a symptom the "
                f"tree still produces, one owning issue and a date a quiet "
                f"row could be retired on; the table's shape and the "
                f"roadmap's pointer to it hold either way",
                claims=len(rows) + 2)
    return 0


if __name__ == "__main__":
    sys.exit(main())
