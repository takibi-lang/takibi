#!/usr/bin/env python3
"""Hold every explicit invariant stop to scripts/invariant_stop_sites.tsv
(GitHub issue #1031 slice 1; DECISIONS 2026-10-25, rung 5).

`kernel_invariant_stop()` and `kernel_invariant_stop_with_frame(frame)` are
run-time checks of premises the types do not state. DECISIONS admits one only
at a frame site (#1017) or for a premise no model covers, and treats the rest
as candidates to move up the ladder. The list file classifies every site, per
enclosing function, as `frame`, `unmodelled` or `ladder`. This check refuses:

  * a function in maintained kernel/ Takibi code (kernel/tests excluded) that
    calls a stop but has no row: a new, unclassified stop;
  * a function whose calls outnumber its rows' counts (the count grew) or
    fall short of them (a retired stop whose row was not lowered);
  * a row naming a function that no longer stops;
  * an unknown class, or a `ladder` row with no `#N` issue.

Comments are blanked first (source_scan.code_only), so a comment naming a
stop is neither a site nor evidence; `fn kernel_invariant_stop(` (a
definition or extern declaration) is not a call.

Rung: a build check. The compiler knows every call, but the classification
is a judgement written beside each site, which the compiler cannot make;
the scan over comment-blanked source sees the same calls, since the stops
are ordinary named functions no alias reaches in maintained code.
Controls: scripts/check_invariant_stop_sites_controls.py.
"""

import re
import sys
from collections import Counter
from pathlib import Path

from pass_line import report_pass
from source_scan import code_only, per_file

ROOT = Path(__file__).resolve().parent.parent
LIST = ROOT / "scripts" / "invariant_stop_sites.tsv"
TREE = "kernel"
EXCLUDED_PARTS = {"build", "_build", "tests"}
CLASSES = ("frame", "unmodelled", "ladder")

CALL = re.compile(r"(?<![\w])(?<!fn )kernel_invariant_stop(?:_with_frame)?\s*\(")
FUNCTION = re.compile(r"^\s*(?:private\s+)?(?:noinline\s+)?fn\s+(\w+)", re.M)
ISSUE = re.compile(r"^#\d+$")


@per_file
def site_counts(text):
    """frozenset of (function, number of stop calls) for one file's code."""
    if "kernel_invariant_stop" not in text:
        return frozenset()
    code = code_only(text)
    starts = [(m.start(), m.group(1)) for m in FUNCTION.finditer(code)]
    found = Counter()
    for match in CALL.finditer(code):
        owner = "<top level>"
        for start, name in starts:
            if start > match.start():
                break
            owner = name
        found[owner] += 1
    return frozenset(found.items())


def parse_rows(text):
    """[(line number, file, function, class, count, value, issue, reason)]
    plus format problems."""
    rows, problems = [], []
    for number, line in enumerate(text.splitlines(), 1):
        if not line.strip() or line.startswith("#"):
            continue
        fields = line.split("\t")
        if len(fields) != 7:
            problems.append(f"invariant_stop_sites.tsv:{number}: expected 7 "
                            f"tab-separated fields, got {len(fields)}")
            continue
        path, function, klass, count, value, issue, reason = fields
        if not count.isdigit() or int(count) == 0:
            problems.append(f"invariant_stop_sites.tsv:{number}: count "
                            f"{count!r} is not a positive integer")
            continue
        if klass not in CLASSES:
            problems.append(f"invariant_stop_sites.tsv:{number}: class "
                            f"{klass!r} is not one of {', '.join(CLASSES)}")
        if value not in ("handler", "-"):
            problems.append(f"invariant_stop_sites.tsv:{number}: value "
                            f"{value!r} is not 'handler' or '-'")
        if klass == "ladder" and not ISSUE.match(issue):
            problems.append(f"invariant_stop_sites.tsv:{number}: a ladder row "
                            f"names the issue that moves it up, got {issue!r}")
        if not reason.strip():
            problems.append(f"invariant_stop_sites.tsv:{number}: no reason")
        rows.append((number, path, function, klass, int(count), value, issue,
                     reason))
    return rows, problems


def problems_in(files, list_text):
    """files: {relative path: text}; list_text: the TSV's text."""
    rows, problems = parse_rows(list_text)
    listed = Counter()
    for _n, path, function, _k, count, _v, _i, _r in rows:
        listed[(path, function)] += count
    actual = Counter()
    for path, text in files.items():
        for function, count in site_counts(text):
            actual[(path, function)] = count
    for key in sorted(set(actual) | set(listed)):
        path, function = key
        have, want = actual.get(key, 0), listed.get(key, 0)
        if want == 0:
            problems.append(f"{path}: {function} has {have} invariant stop(s) "
                            "and no row in scripts/invariant_stop_sites.tsv; "
                            "classify it (frame, unmodelled or ladder) with a "
                            "reason, or return a value instead")
        elif have > want:
            problems.append(f"{path}: {function} has {have} invariant stop(s), "
                            f"its rows allow {want}; a new stop is classified "
                            "by hand, not absorbed")
        elif have < want:
            problems.append(f"{path}: {function} has {have} invariant stop(s), "
                            f"its rows say {want}; lower or remove the row so "
                            "the retired stop is recorded")
    return problems


def source_files():
    files = {}
    for path in (ROOT / TREE).rglob("*.tkb"):
        relative = path.relative_to(ROOT)
        if EXCLUDED_PARTS & set(relative.parts):
            continue
        files[str(relative)] = path.read_text(encoding="utf-8")
    return files


def class_totals(list_text):
    rows, _ = parse_rows(list_text)
    totals = Counter()
    for row in rows:
        totals[row[3]] += row[4]
    return totals


def main():
    files = source_files()
    list_text = LIST.read_text(encoding="utf-8")
    problems = problems_in(files, list_text)
    for problem in problems:
        print(f"ERROR\tinvariant-stop-sites: {problem}")
    if problems:
        print("FAIL invariant-stop-sites: kernel invariant stops and "
              "scripts/invariant_stop_sites.tsv disagree")
        return 1
    totals = class_totals(list_text)
    sites = sum(totals.values())
    if sites == 0:
        print("FAIL invariant-stop-sites: no site found; the scan is broken")
        return 1
    summary = ", ".join(f"{k} {totals[k]}" for k in CLASSES)
    report_pass("invariant-stop-sites",
                f"{sites} invariant stop(s) in {len(files)} kernel files, "
                f"every one classified ({summary})",
                sites=sites)
    return 0


if __name__ == "__main__":
    sys.exit(main())
