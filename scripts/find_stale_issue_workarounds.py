#!/usr/bin/env python3
"""Find comments that say something is unfinished, naming a CLOSED issue.

A source comment may name a settled issue when it explains an enduring design
rationale, and this tree does that hundreds of times. Those are not the
problem. The problem is the other kind: a comment saying the code is shaped
this way BECAUSE something is not done yet, naming the issue that would finish
it. That sentence stops being true the moment the issue closes, and nothing
announces the moment. Two were found by accident in one 2026-08-16 session,
only because the compiler-side fix happened to be worked on beside them
(GitHub issue #336).

This is a WORKLIST, not a check. It is deliberately not part of any build:

  - it needs the network, and a build that fails when GitHub is unreachable
    fails for a reason that has nothing to do with the change under test;
  - the heuristic is prose matching and always will be, so a run costs a
    person a minute of reading rather than nothing;
  - a hit is a question ("is this still true?"), not a defect. Closing an
    issue does not prove that this exact workaround became unnecessary; the
    fix may have been scoped differently than the comment assumed.

## What it looks for

An issue reference on a COMMENT line that also asserts present
incompleteness -- `workaround`, `not yet`, `TODO`, `for now`, `blocked by`
and their neighbours. Every one of those is a claim about the world that the
named issue closing may have falsified.

Deliberately NOT matched, because in this tree they are how settled rationale
is written and matching them buries the signal: bare `cannot`, `is not`,
`does not`. Measured on 2026-09-06, matching those took the report from 7
lines to 668, of which the overwhelming majority were permanent statements
like "GitHub issue #488: this RETURNS the pointer, so it cannot outlive".

`pending` is not matched either, for a more specific reason: it is a variant
constructor in this codebase (`FreelistPopPending`), so it matched only
prose about types.

A negation window suppresses the opposite sentence. "no more manual
workaround (issue #15) needed here" records that a workaround was REMOVED,
which is the good state, and it appears three times.

## Reporting

One `gh issue list` call for every issue's state rather than one call per
reference, so a run costs one request. A number GitHub does not return is
reported separately and never assumed closed: it may be a pull request, or
may not exist.

## The known-intermittent table

GitHub issue #565 asks for the same question about docs/KNOWN_INTERMITTENTS.md:
every row must cite an issue that is still OPEN, so closing the issue forces
the row to be removed or re-attributed. That is the same fact, needing the
same one network call, and it belongs here for the same reason -- a build
that fails when GitHub is unreachable fails for a reason unrelated to the
change under test.

The table's other guard, that a row's symptom still exists in the tree, is a
tracked-file fact and lives in scripts/check_known_intermittents.py, which
`make langcheck` runs.

Usage: find_stale_issue_workarounds.py [--json]
Exit 0 when nothing needs review, 1 when something does, 2 when the issue
states could not be fetched.
"""

from __future__ import annotations

import argparse
import json
import os
import pathlib
import re
import subprocess
import sys

from pass_line import report_pass

ROOT = pathlib.Path(__file__).resolve().parent.parent

# The trees the issue named, plus scripts/: the first real hit this found was
# in a runner comment, so host-side code carries the same staleness.
TREES = ("kernel", "lib", "linux_user", "examples", "scripts")
SUFFIXES = {".tkb", ".ml", ".mli", ".mll", ".mly", ".py", ".sh", ".S", ".ld"}

COMMENT = re.compile(r"^\s*(//|#|--|\*|/\*)")
ISSUE = re.compile(r"issues?\s*#(\d+)", re.IGNORECASE)

# Claims about the present that the named issue closing may have falsified.
PENDING = re.compile(
    r"\bworkarounds?\b|\bwork around\b|\bnot yet\b|\bTODO\b|\bFIXME\b|"
    r"\bfor now\b|\bnot implemented\b|\bunimplemented\b|\bblocked by\b|"
    r"\bnot supported\b|\bunsupported\b|\bdeferred\b|"
    r"\b(?:until|once)\b.{0,40}?\b(?:lands|ships|is fixed|exists|"
    r"is implemented)\b",
    re.IGNORECASE)

# "no more X needed" / "no longer needs X" is the sentence that records a
# workaround being REMOVED. Searched across a small window because the
# negation and the word it negates are often on different comment lines.
NEGATED = re.compile(r"\bno (?:more|longer)\b", re.IGNORECASE)
NEGATION_WINDOW = 3

# (path, exact comment line) -> why this is not a stale workaround. Exact
# lines rather than file or line-number keys: a broad exemption would let an
# unrelated future comment inherit it silently, and an edited line stops
# matching and comes back for review, which is the behaviour wanted.
DECLARED: dict[tuple[str, str], str] = {
    ("examples/field_lease/field_lease.tkb",
     "// This does not yet solve issue #89's actual fd-table shape (an escaping"):
        "the historical twin of linux_user/field_lease. Issue #89's closing "
        "comment split the escaping-index shape out as #131, which is still "
        "open, and the maintained copy names that instead. AGENTS.md says not "
        "to edit examples/ for parity with a maintained file, so this one "
        "keeps the sentence it was written with",
}


def source_files(trees):
    for tree in trees:
        root = ROOT / tree
        if not root.is_dir():
            continue
        for path in sorted(root.rglob("*")):
            if path.is_file() and path.suffix in SUFFIXES:
                yield path


def findings(trees):
    """Yield (relative path, line number, issue number, line) candidates."""
    for path in source_files(trees):
        try:
            lines = path.read_text(encoding="utf-8").splitlines()
        except (OSError, UnicodeDecodeError):
            continue
        for number, line in enumerate(lines, 1):
            if not COMMENT.match(line) or not ISSUE.search(line):
                continue
            if not PENDING.search(line):
                continue
            window = "\n".join(lines[max(0, number - NEGATION_WINDOW):number])
            if NEGATED.search(window):
                continue
            relative = str(path.relative_to(ROOT))
            stripped = line.strip()
            if (relative, stripped) in DECLARED:
                continue
            for issue in sorted({int(m) for m in ISSUE.findall(line)}):
                yield relative, number, issue, stripped


INTERMITTENTS = ROOT / "docs" / "KNOWN_INTERMITTENTS.md"
INTERMITTENT_ROW = re.compile(
    r"^\| `([^`]+)` \| [^|]* \| #(\d+) \| \d{4}-\d{2}-\d{2} \|$", re.M)


def intermittent_rows():
    """Yield (symptom, issue) for each row of the known-intermittent table."""
    if not INTERMITTENTS.is_file():
        return
    text = INTERMITTENTS.read_text(encoding="ascii")
    for symptom, issue in INTERMITTENT_ROW.findall(text):
        yield symptom, int(issue)


class IssueStatesUnavailable(Exception):
    """GitHub could not be asked, so nothing about issue state is known.

    Raised rather than exited on, because the two callers of `issue_states`
    owe different sentences about it. This worklist is excluded from every
    build and says so; scripts/slowcheck_known_intermittent_issues.py runs
    inside one and must not claim the opposite.
    """


# `gh --json` is not machine output by itself: it COLOURS the JSON when it
# believes a terminal is watching, and `CLICOLOR_FORCE` makes it believe that
# even with no terminal in sight. A GitHub Actions runner sets exactly that,
# so the answer arrived as `\x1b[1;37m[\x1b[m ...` and parsed as nothing --
# measured on 2026-09-20, one red CI run after the missing `issues: read`
# permission was the cause of three others.
#
# NO_COLOR and CLICOLOR say "no colour"; CLICOLOR_FORCE outranks them, so it
# is cleared rather than contradicted. GH_FORCE_TTY is emptied for the same
# reason: gh treats any non-empty value as a terminal.
PLAIN_OUTPUT = {
    "NO_COLOR": "1",
    "CLICOLOR": "0",
    "CLICOLOR_FORCE": "",
    "GH_FORCE_TTY": "",
}


def issue_states():
    """Every issue's state, in one request rather than one per reference."""
    try:
        result = subprocess.run(
            ["gh", "issue", "list", "--state", "all", "--limit", "2000",
             "--json", "number,state"],
            capture_output=True, text=True, check=True, timeout=120,
            env={**os.environ, **PLAIN_OUTPUT})
    except (OSError, subprocess.CalledProcessError,
            subprocess.TimeoutExpired) as error:
        detail = getattr(error, "stderr", "") or str(error)
        raise IssueStatesUnavailable(detail.strip()[:400] or str(error))
    # Exit status is not the whole answer. A token that may not read issues
    # makes `gh issue list --json` exit 0 with EMPTY stdout -- measured on
    # GitHub Actions on 2026-09-18, where the workflow granted `contents` and
    # `actions` but not `issues`, and the missing permission arrived here as
    # a JSONDecodeError traceback rather than as a verdict. So the OUTPUT is
    # what decides: anything that is not a list of issues means the question
    # went unanswered.
    try:
        answer = json.loads(result.stdout)
    except json.JSONDecodeError:
        # Deliberately no guess at the cause. Two different ones have now
        # produced this branch -- a token without `issues: read`, which
        # answers with nothing at all, and forced colour, which answers with
        # JSON wrapped in escape codes -- so what is printed is what came
        # back, and the reader draws the conclusion.
        raise IssueStatesUnavailable(
            f"`gh issue list` exited 0 and did not answer with JSON "
            f"(stdout {result.stdout.strip()[:160]!r}, stderr "
            f"{result.stderr.strip()[:200]!r})")
    if not isinstance(answer, list):
        raise IssueStatesUnavailable(
            f"`gh issue list` answered with {type(answer).__name__}, not a "
            f"list of issues")
    return {item["number"]: item["state"] for item in answer}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--json", action="store_true",
                        help="emit the worklist as JSON instead of prose")
    args = parser.parse_args()

    candidates = list(findings(TREES))
    rows = list(intermittent_rows())
    try:
        states = issue_states()
    except IssueStatesUnavailable as error:
        raise SystemExit(
            "ERROR stale-issue-workarounds: could not read issue states from "
            f"GitHub, so nothing can be judged: {error}\n"
            "This tool needs `gh` authenticated against the repository. It is "
            "deliberately not part of any build, so this is not a build "
            "failure.")

    stale, unknown = [], []
    for relative, number, issue, line in candidates:
        state = states.get(issue)
        if state is None:
            unknown.append((relative, number, issue, line))
        elif state == "CLOSED":
            stale.append((relative, number, issue, line))

    table = str(INTERMITTENTS.relative_to(ROOT))
    for symptom, issue in rows:
        state = states.get(issue)
        line = f"known intermittent `{symptom}`"
        if state is None:
            unknown.append((table, 0, issue, line))
        elif state == "CLOSED":
            stale.append((table, 0, issue, line))

    if args.json:
        print(json.dumps({
            "scanned_candidates": len(candidates),
            "declared": len(DECLARED),
            "intermittent_rows": len(rows),
            "stale": [{"file": f, "line": n, "issue": i, "text": t}
                      for f, n, i, t in stale],
            "unknown": [{"file": f, "line": n, "issue": i}
                        for f, n, i, _ in unknown],
        }, indent=2))
        return 1 if stale else 0

    for relative, number, issue, line in stale:
        print(f"{relative}:{number}: issue #{issue} is CLOSED")
        print(f"    {line}")
    for relative, number, issue, _ in unknown:
        print(f"{relative}:{number}: issue #{issue} was not returned by "
              "GitHub -- it may be a pull request, or may not exist. NOT "
              "treated as closed.", file=sys.stderr)

    if stale:
        print(f"\n{len(stale)} claim(s) about the present name an issue "
              "that has since closed. Each is a question, not a defect: read "
              "it, and either update the comment, remove the workaround, add "
              "the line to DECLARED in this script with the reason it is not "
              f"stale, or -- for a row of {table} -- remove the row or "
              "re-attribute it to the issue that owns the symptom now.")
        return 1

    report_pass(
        "stale-issue-workarounds",
        f"{len(candidates)} comment(s) claim present incompleteness and "
        f"{len(rows)} known intermittent(s) name an owning issue; none of "
        f"those issues is closed",
        candidates=len(candidates) + len(rows))
    return 0


if __name__ == "__main__":
    sys.exit(main())
