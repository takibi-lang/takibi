#!/usr/bin/env python3
"""The defect catalog's claims, checked against the tree they describe.

`docs/wont-compile/` exists to be believed. Each entry says a program is
rejected by the compiler, names the Alcotest case that pins that rejection,
and shows the diagnostic. Every one of those is a transcription, and a
transcription is a verdict with no verifier -- the shape
`scripts/check_documented_counts.py` was written to describe. A stale entry
and a true one look identical, and this catalog is read by people deciding
whether the project's central claim is real, so a wrong one is expensive in
the way a wrong count is not.

This check covers the half that can be established by reading tracked files:
that an entry has the fields it promises, that the test case it names exists,
that its figure has a source and is referenced, and that the index agrees
with the entries. The other half -- that the sample programs actually compile
and fail the way the entry says -- needs the compiler, so it lives in
`scripts/buildcheck_wont_compile_samples.py`, which runs from the rule that
builds it.

The split is deliberate and neither half is sufficient. This one would pass a
catalog whose every sample had stopped being rejected; that one would pass a
catalog whose entries named no test at all.

Usage: check_wont_compile_catalog.py [repo_root]
"""

from __future__ import annotations

import pathlib
import re
import sys

from pass_line import report_pass

REPO = pathlib.Path(__file__).resolve().parent.parent

CATALOG = "docs/wont-compile"
TEST_FILE = "test/test_takibi.ml"

ENTRY_NAME = re.compile(r"^(\d{4})-([a-z0-9][a-z0-9-]*)\.md$")
TITLE = re.compile(r"^# (\d{4})\. (\S.*?)\s*$", re.M)
FIELD_ROW = re.compile(r"^\|\s*([A-Z][A-Za-z ]*?)\s*\|\s*(.+?)\s*\|$", re.M)
FENCE = re.compile(r"^```([a-z]*)\n(.*?)^```\s*$", re.M | re.S)
FIGURE_REF = re.compile(r"\]\(assets/([^)]+)\)")
INDEX_ROW = re.compile(
    r"^\|\s*\[(\d{4})\]\((\d{4}-[a-z0-9-]+\.md)\)\s*\|\s*(.+?)\s*\|\s*(.+?)\s*\|$",
    re.M,
)

# Four digits, assigned in order, never reused. The number is a permanent
# handle that appears in talks and commit messages, so a renumbering would
# silently repoint a citation at a different defect.
REQUIRED_FIELDS = ("Status", "Check", "Test case", "Introduced")
STATUS = re.compile(r"^(Enforced|Partial|Withdrawn|Superseded by \d{4})$")

REJECTED_HEADING = "## Code that does not compile"
ACCEPTED_HEADING = "## Code that does compile"


def section(text: str, heading: str) -> str | None:
    """The body under one `## ` heading, up to the next one."""
    start = text.find(heading + "\n")
    if start < 0:
        return None
    rest = text[start + len(heading) + 1:]
    end = rest.find("\n## ")
    return rest if end < 0 else rest[:end]


def fences(body: str) -> list[tuple[str, str]]:
    return [(m.group(1), m.group(2)) for m in FENCE.finditer(body)]


def rejected_samples(body: str, name: str, errors: list[str]) -> list[tuple[str, str]]:
    """Each rejected program paired with the diagnostic printed beside it.

    The pairing is the format: a ```takibi block followed immediately by a
    ```text block. An unpaired program would be a sample nothing asserts
    anything about, which reads in the rendered page exactly like one that is
    checked.
    """
    blocks = fences(body)
    pairs: list[tuple[str, str]] = []
    index = 0
    while index < len(blocks):
        lang, code = blocks[index]
        if lang != "takibi":
            errors.append(
                f"{name}: a `{lang or 'plain'}` block appears under "
                f"\"{REJECTED_HEADING}\" where a takibi program was expected")
            index += 1
            continue
        if index + 1 >= len(blocks) or blocks[index + 1][0] != "text":
            errors.append(
                f"{name}: a rejected program under \"{REJECTED_HEADING}\" is "
                "not followed by a ```text block holding its diagnostic")
            index += 1
            continue
        pairs.append((code, blocks[index + 1][1]))
        index += 2
    if not pairs:
        errors.append(f"{name}: no rejected program found under "
                      f"\"{REJECTED_HEADING}\"")
    return pairs


def accepted_samples(body: str, name: str, errors: list[str]) -> list[str]:
    """The programs the entry says do compile.

    An entry that shows only rejection cannot distinguish a working check
    from a compiler that rejects everything nearby, which is the failure a
    reader of this catalog is least able to spot for themselves.
    """
    programs = []
    for lang, code in fences(body):
        if lang == "takibi":
            programs.append(code)
        else:
            errors.append(
                f"{name}: a `{lang or 'plain'}` block appears under "
                f"\"{ACCEPTED_HEADING}\"; an accepted program has no "
                "diagnostic to show")
    if not programs:
        errors.append(f"{name}: no accepted program found under "
                      f"\"{ACCEPTED_HEADING}\"")
    return programs


class Entry:
    def __init__(self, path: pathlib.Path, number: str, slug: str) -> None:
        self.path = path
        self.number = number
        self.slug = slug
        self.text = path.read_text(encoding="utf-8")
        self.fields: dict[str, str] = {}
        self.status = ""
        self.test_case = ""
        self.rejected: list[tuple[str, str]] = []
        self.accepted: list[str] = []


def unbacktick(value: str) -> str | None:
    if len(value) > 2 and value.startswith("`") and value.endswith("`"):
        return value[1:-1]
    return None


def load_entries(catalog: pathlib.Path, errors: list[str]) -> list[Entry]:
    entries = []
    for path in sorted(catalog.glob("*.md")):
        if path.name == "README.md":
            continue
        matched = ENTRY_NAME.match(path.name)
        if not matched:
            errors.append(
                f"{path.name}: an entry is named NNNN-slug.md, four digits "
                "and a lowercase slug")
            continue
        entry = Entry(path, matched.group(1), matched.group(2))
        entries.append(entry)
        name = path.name

        title = TITLE.search(entry.text)
        if not title:
            errors.append(f"{name}: no `# NNNN. Title` heading")
        elif title.group(1) != entry.number:
            errors.append(
                f"{name}: the heading is numbered {title.group(1)} and the "
                f"file {entry.number}; a citation can only follow one of them")

        entry.fields = {m.group(1): m.group(2) for m in FIELD_ROW.finditer(entry.text)}
        for field in REQUIRED_FIELDS:
            if field not in entry.fields:
                errors.append(f"{name}: the header table has no `{field}` row")

        entry.status = entry.fields.get("Status", "")
        if entry.status and not STATUS.match(entry.status):
            errors.append(
                f"{name}: Status is \"{entry.status}\"; it must be Enforced, "
                "Partial, Withdrawn, or Superseded by NNNN")

        raw_case = entry.fields.get("Test case", "")
        if raw_case:
            case = unbacktick(raw_case)
            if case is None:
                errors.append(
                    f"{name}: the Test case value is not backticked, so what "
                    "is compared against the suite is ambiguous")
            else:
                entry.test_case = case

        figures = FIGURE_REF.findall(entry.text)
        expected = f"{entry.number}-{entry.slug}.svg"
        if expected not in figures:
            errors.append(
                f"{name}: does not show assets/{expected}; an entry leads "
                "with its figure")

        body = section(entry.text, REJECTED_HEADING)
        if body is None:
            errors.append(f"{name}: no \"{REJECTED_HEADING}\" section")
        else:
            entry.rejected = rejected_samples(body, name, errors)

        body = section(entry.text, ACCEPTED_HEADING)
        if body is None:
            errors.append(f"{name}: no \"{ACCEPTED_HEADING}\" section")
        else:
            entry.accepted = accepted_samples(body, name, errors)

    return entries


def check_test_cases(entries: list[Entry], test_file: pathlib.Path,
                     errors: list[str]) -> None:
    """Every named Alcotest case exists, spelled exactly.

    This is the load-bearing link. It is what makes a compiler regression
    turn a test red instead of quietly turning a documented guarantee into
    fiction, and it only holds while the name in the entry is the name in the
    suite -- a renamed case leaves the entry pointing at nothing, and nothing
    about the rendered page looks different.
    """
    suite = test_file.read_text(encoding="utf-8")
    for entry in entries:
        if not entry.test_case:
            continue
        if f'"{entry.test_case}"' not in suite:
            errors.append(
                f"{entry.path.name}: names the test case "
                f"\"{entry.test_case}\", which is not in "
                f"{test_file.name}; the entry's guarantee is pinned by "
                "nothing")


def check_figures(entries: list[Entry], catalog: pathlib.Path,
                  errors: list[str]) -> int:
    """Each figure has a source, and each source has an entry."""
    assets = catalog / "assets"
    stems = {f"{entry.number}-{entry.slug}" for entry in entries}
    counted = 0

    for entry in entries:
        stem = f"{entry.number}-{entry.slug}"
        svg = assets / f"{stem}.svg"
        dot = assets / f"{stem}.dot"
        if not svg.exists():
            errors.append(f"{entry.path.name}: assets/{stem}.svg is missing")
            continue
        if not dot.exists():
            errors.append(
                f"{entry.path.name}: assets/{stem}.svg has no {stem}.dot "
                "beside it; a figure whose source is gone can be looked at "
                "but never corrected")
            continue
        counted += 1

    for path in sorted(assets.glob("*")):
        if path.suffix not in (".dot", ".svg"):
            errors.append(f"assets/{path.name}: not a figure source or a "
                          "generated figure")
        elif path.stem not in stems:
            errors.append(f"assets/{path.name}: no entry claims this figure")

    return counted


def check_index(entries: list[Entry], catalog: pathlib.Path,
                errors: list[str]) -> None:
    """The index lists every entry, with the status the entry itself states.

    An index is the first thing a visitor reads and the last thing an author
    updates.
    """
    readme = catalog / "README.md"
    rows = {m.group(1): m for m in INDEX_ROW.finditer(
        readme.read_text(encoding="utf-8"))}

    for entry in entries:
        row = rows.pop(entry.number, None)
        if row is None:
            errors.append(
                f"README.md: entry {entry.number} is not in the index table")
            continue
        if row.group(2) != entry.path.name:
            errors.append(
                f"README.md: the row for {entry.number} links "
                f"{row.group(2)}, not {entry.path.name}")
        if row.group(4) != entry.status:
            errors.append(
                f"README.md: the row for {entry.number} says status "
                f"\"{row.group(4)}\" and the entry says \"{entry.status}\"")

    for number, row in rows.items():
        errors.append(
            f"README.md: the index lists {number} ({row.group(2)}), which "
            "does not exist")


def main(root: pathlib.Path) -> int:
    catalog = root / CATALOG
    errors: list[str] = []

    entries = load_entries(catalog, errors)
    if not entries:
        print("ERROR wont-compile-catalog: no entries found in "
              f"{CATALOG}; the check would report about nothing",
              file=sys.stderr)
        return 1

    check_test_cases(entries, root / TEST_FILE, errors)
    figures = check_figures(entries, catalog, errors)
    check_index(entries, catalog, errors)

    for error in errors:
        print(f"ERROR wont-compile-catalog: {error}", file=sys.stderr)
    if errors:
        return 1

    samples = sum(len(e.rejected) + len(e.accepted) for e in entries)
    report_pass(
        "wont-compile-catalog",
        f"{len(entries)} entries name a test case that exists, show "
        f"{samples} sample programs, and carry {figures} figures with their "
        "sources; the index agrees with all of them",
        entries=len(entries),
        samples=samples,
        figures=figures,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main(pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else REPO))
