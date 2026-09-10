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

Usage: find_stale_issue_workarounds.py [--all-trees] [--json]
Exit 0 when nothing needs review, 1 when something does, 2 when the issue
states could not be fetched.
"""

from __future__ import annotations

import argparse
import json
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


def issue_states():
    """Every issue's state, in one request rather than one per reference."""
    try:
        result = subprocess.run(
            ["gh", "issue", "list", "--state", "all", "--limit", "2000",
             "--json", "number,state"],
            capture_output=True, text=True, check=True, timeout=120)
    except (OSError, subprocess.CalledProcessError,
            subprocess.TimeoutExpired) as error:
        detail = getattr(error, "stderr", "") or str(error)
        raise SystemExit(
            "ERROR stale-issue-workarounds: could not read issue states from "
            f"GitHub, so nothing can be judged: {detail.strip()[:400]}\n"
            "This tool needs `gh` authenticated against the repository. It is "
            "deliberately not part of any build, so this is not a build "
            "failure.")
    return {item["number"]: item["state"]
            for item in json.loads(result.stdout)}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--json", action="store_true",
                        help="emit the worklist as JSON instead of prose")
    args = parser.parse_args()

    candidates = list(findings(TREES))
    states = issue_states()

    stale, unknown = [], []
    for relative, number, issue, line in candidates:
        state = states.get(issue)
        if state is None:
            unknown.append((relative, number, issue, line))
        elif state == "CLOSED":
            stale.append((relative, number, issue, line))

    if args.json:
        print(json.dumps({
            "scanned_candidates": len(candidates),
            "declared": len(DECLARED),
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
        print(f"\n{len(stale)} comment(s) say something is unfinished and "
              "name an issue that has since closed. Each is a question, not "
              "a defect: read it, and either update the comment, remove the "
              "workaround, or add the line to DECLARED in this script with "
              "the reason it is not stale.")
        return 1

    report_pass(
        "stale-issue-workarounds",
        f"{len(candidates)} comment(s) claim present incompleteness and name "
        f"an issue; none of those issues is closed",
        candidates=len(candidates))
    return 0


if __name__ == "__main__":
    sys.exit(main())
