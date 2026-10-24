"""Reader for the compiler's --emit-call-graph table (GitHub issue #987).

docs/CALL_GRAPH.md is the format. A check that needs to know which function
calls which reads this table, written by the compiler from its own name
resolution, instead of re-deriving the call graph from .tkb text with
regular expressions -- the shadow parsers GitHub issue #567 counted.

The reader refuses what it does not understand: another format version, a
missing column, or a table with no rows. A check over an empty or
misread table would otherwise report PASS about nothing.
"""

import pathlib

FORMAT = 1
HEADER = "# takibi call graph, format "
COLUMNS = ("file", "line", "end_line", "name", "qualifiers", "declared",
           "effects", "params", "callees", "callers", "values", "body_hash")
LIST_COLUMNS = ("qualifiers", "effects", "callees", "callers", "values")


class TableError(Exception):
    pass


def parse(text: str, origin: str = "call graph") -> list[dict]:
    """Rows as dicts; list columns as lists, '-' as empty."""
    lines = text.splitlines()
    if not lines or not lines[0].startswith(HEADER):
        raise TableError(f"{origin}: not a takibi call graph table")
    version = lines[0][len(HEADER):].split(";", 1)[0]
    if version != str(FORMAT):
        raise TableError(f"{origin}: format {version}, this reader knows {FORMAT}")
    if len(lines) < 2 or tuple(lines[1].split("\t")) != COLUMNS:
        raise TableError(f"{origin}: column header is not {COLUMNS}")
    rows = []
    for number, line in enumerate(lines[2:], start=3):
        cells = line.split("\t")
        if len(cells) != len(COLUMNS):
            raise TableError(f"{origin}:{number}: {len(cells)} cells, not {len(COLUMNS)}")
        row = dict(zip(COLUMNS, cells))
        for column in LIST_COLUMNS:
            row[column] = [] if row[column] == "-" else row[column].split(",")
        row["params"] = [] if row["params"] == "-" else row["params"].split(", ")
        rows.append(row)
    if not rows:
        raise TableError(f"{origin}: no rows")
    return rows


def read(path) -> list[dict]:
    path = pathlib.Path(path)
    return parse(path.read_text(encoding="utf-8"), str(path))


def callee_name(entry: str) -> str:
    """`name@file:line` -> name; `*` (an indirect call) stays `*`."""
    return entry.split("@", 1)[0]


def callee_file(entry: str) -> str:
    """`name@file:line` -> file; '-' for a callee with no definition."""
    if "@" not in entry:
        return "-"
    return entry.split("@", 1)[1].rsplit(":", 1)[0]
