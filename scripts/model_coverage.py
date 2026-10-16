#!/usr/bin/env python3
"""Fail a TLC run in which some action of the spec was never taken.

GitHub issue #802. During #778 every emitted protocol model without `split`
kept `held = {}`, so `deviceActive` was always empty and two safety
invariants held vacuously; the run said "No error has been found" and
nothing reported that half the model never ran. A model that passes because
part of it is dead is the class this check stops.

scripts/run_model_checks.sh runs every TLC job with `-coverage`, which ends
the log with one line per action of the next-state relation:

    <ChildExit line 107, col 1 to line 107, col 9 of module Wait4Block>: 4:12

The two numbers are distinct new states and states generated. Generated 0
means the action was never enabled in any reachable state: the check fails
on it. Only runs that explored the whole state space are judged (a variant
that stops at its first violation has not visited everything), so the
caller passes the logs of "pass" variants alone.

An action that is meant to be dead in some variant -- a step only a faulty
variant takes, say -- goes on the allow-list, kernel/models/coverage_allow.txt,
one line each with its reason:

    <Model> <variant> <Action>: <reason>

An entry without a reason, an entry for a run that was not judged, and an
entry whose action WAS taken are all errors, not warnings (DECISIONS.md,
2026-10-16: suspicious tool input is an error), so the list cannot go stale.

Usage: model_coverage.py ALLOW_LIST MODEL:VARIANT:LOG...
"""

from __future__ import annotations

import pathlib
import re
import sys

sys.dont_write_bytecode = True
from pass_line import report_pass  # noqa: E402

COVERAGE_RE = re.compile(
    r"^<(\w+) line (\d+), col \d+ to line \d+, col \d+ of module (\w+)"
    r"[^>]*>: (\d+):(\d+)\s*$")
ENTRY_RE = re.compile(r"^(\w+) (\w+) (\w+): (\S.*)$")


def parse_allow(text: str) -> tuple[dict[tuple[str, str, str], str], list[str]]:
    allow: dict[tuple[str, str, str], str] = {}
    errors: list[str] = []
    for number, line in enumerate(text.splitlines(), 1):
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        match = ENTRY_RE.match(stripped)
        if not match:
            errors.append(f"allow-list line {number}: not "
                          f"'<Model> <variant> <Action>: <reason>': {line!r}")
            continue
        key = (match.group(1), match.group(2), match.group(3))
        if key in allow:
            errors.append(f"allow-list line {number}: duplicate entry {' '.join(key)}")
        allow[key] = match.group(4)
    return allow, errors


def parse_coverage(text: str) -> list[tuple[str, int, int]]:
    """(action, line, generated) for every action line of the LAST report.

    -coverage N also prints a report every N minutes of a long run; an
    action still at 0 in an early report may be taken later, so only the
    final one (printed when the run ends) is the verdict's.
    """
    rows = []
    sections = text.split("The coverage statistics at ")
    if len(sections) < 2:
        return rows
    for line in sections[-1].splitlines():
        match = COVERAGE_RE.match(line)
        if match:
            rows.append((match.group(1), int(match.group(2)), int(match.group(5))))
    return rows


def judge(allow_text: str, runs: list[tuple[str, str, str]]) -> tuple[list[str], int]:
    """Errors for runs [(model, variant, log text)], and the action count."""
    allow, errors = parse_allow(allow_text)
    used: set[tuple[str, str, str]] = set()
    judged: set[tuple[str, str]] = set()
    actions = 0
    for model, variant, log in runs:
        judged.add((model, variant))
        rows = parse_coverage(log)
        if not rows:
            errors.append(f"{model} {variant}: the TLC log has no action coverage "
                          f"(was -coverage dropped?)")
            continue
        # An action can occur more than once (two disjuncts calling it);
        # each occurrence never taken is a dead disjunct, so each is judged.
        taken: dict[str, bool] = {}
        dead_lines: dict[str, list[int]] = {}
        for action, line, generated in rows:
            actions += 1
            taken[action] = taken.get(action, False) or generated > 0
            if generated == 0:
                dead_lines.setdefault(action, []).append(line)
        for action, lines in sorted(dead_lines.items()):
            key = (model, variant, action)
            if key in allow:
                used.add(key)
                continue
            where = ", ".join(f"line {n}" for n in lines)
            errors.append(f"{model} {variant}: action {action} ({where}) is never "
                          f"taken -- the model passes partly vacuously; fix the "
                          f"model or allow-list it with the reason in "
                          f"kernel/models/coverage_allow.txt")
        for key in allow:
            if key[:2] == (model, variant) and key not in used:
                if key[2] in taken:
                    errors.append(f"allow-list entry {' '.join(key)}: the action IS "
                                  f"taken now; drop the stale entry")
                else:
                    errors.append(f"allow-list entry {' '.join(key)}: the run has no "
                                  f"action {key[2]}")
                used.add(key)
    for key in allow:
        if key[:2] not in judged:
            errors.append(f"allow-list entry {' '.join(key)}: no fully explored TLC "
                          f"run of {key[0]} {key[1]} was judged")
    return errors, actions


def main(argv: list[str]) -> int:
    if len(argv) < 3:
        print(__doc__.strip().splitlines()[-1], file=sys.stderr)
        return 2
    allow_text = pathlib.Path(argv[1]).read_text()
    runs = []
    for spec in argv[2:]:
        model, variant, log = spec.split(":", 2)
        runs.append((model, variant, pathlib.Path(log).read_text(errors="replace")))
    errors, actions = judge(allow_text, runs)
    for error in errors:
        print(f"FAIL model-coverage: {error}")
    if errors:
        return 1
    report_pass("model-coverage",
                f"every action of {len(runs)} fully explored TLC run(s) was taken "
                f"or is allow-listed with a reason",
                runs=len(runs), actions=actions)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
