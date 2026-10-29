#!/usr/bin/env python3
"""The global protection ratchet (GitHub issue #1012 slice 1).

Reads the compiler's `--emit-globals` tables of both kernels
(docs/GLOBAL_PROTECTION.md) and refuses:

- a production `let mut` global whose type shows no protection (protection
  `none`, or a `scratch` global) and that is not listed in
  scripts/global_protection_allowlist.tsv;
- a listed row that no longer names such a global (it was migrated,
  renamed or deleted): the list only shrinks, and a stale row would let
  the next unprotected global of that name in for free;
- a duplicate row, a row without a reader cell, an empty table.

Production means compiled into a kernel image under kernel/ and outside
kernel/tests and kernel/models. The row count of the allow-list is the
ledger category `unprotected_globals` (scripts/check_trust_ledger.py), so a
rise needs an issue there and a fall names its rule.

  buildcheck_global_protection.py QEMU.globals.tsv RPI5.globals.tsv
  buildcheck_global_protection.py --summary TABLE...   counts per class
"""

import collections
import pathlib
import sys

from pass_line import report_pass

ROOT = pathlib.Path(__file__).resolve().parent.parent
ALLOWLIST = ROOT / "scripts" / "global_protection_allowlist.tsv"
FORMAT = 1
HEADER = "# takibi globals, format "
COLUMNS = ("file", "line", "name", "visibility", "qualifier", "type", "protection")
PROTECTED = {"atomic", "lock", "per_cpu", "region", "place", "dma_fixed",
             "protocol", "boot_once", "composite"}
UNPROTECTED = {"none"}


class TableError(Exception):
    pass


def parse_table(text, origin):
    lines = text.splitlines()
    if not lines or not lines[0].startswith(HEADER):
        raise TableError(f"{origin}: not a takibi globals table")
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
        if row["protection"] not in PROTECTED | UNPROTECTED:
            raise TableError(f"{origin}:{number}: unknown protection {row['protection']!r}")
        rows.append(row)
    if not rows:
        raise TableError(f"{origin}: no rows")
    return rows


def production(file):
    parts = pathlib.PurePosixPath(file).parts
    return len(parts) > 1 and parts[0] == "kernel" and parts[1] not in ("tests", "models")


def unprotected(row):
    return row["protection"] in UNPROTECTED or row["qualifier"] == "scratch"


def globals_of(tables):
    """(file, name) -> row, the union over both kernels."""
    found = {}
    for origin, text in tables:
        for row in parse_table(text, origin):
            if production(row["file"]):
                found.setdefault((row["file"], row["name"]), row)
    if not found:
        raise TableError("no production globals in the tables")
    return found


def parse_allowlist(text, origin=str(ALLOWLIST)):
    rows, errors = {}, []
    for number, line in enumerate(text.splitlines(), start=1):
        if not line.strip() or line.startswith("#"):
            continue
        cells = line.split("\t")
        if len(cells) != 3 or not cells[2].strip():
            errors.append(f"{origin}:{number}: want file<TAB>name<TAB>reader")
            continue
        key = (cells[0], cells[1])
        if key in rows:
            errors.append(f"{origin}:{number}: duplicate row {cells[0]} {cells[1]}")
        rows[key] = cells[2]
    return rows, errors


def check(found, allowed):
    errors = []
    open_rows = {k for k, r in found.items() if unprotected(r)}
    for key in sorted(open_rows - set(allowed)):
        row = found[key]
        errors.append(
            f"{row['file']}:{row['line']}: global '{row['name']}: {row['type']}' shows no "
            "protection in its type (AtomicWord, LockedCell, RegionPool, Place, per_cpu, "
            "region, dma_fixed, protocol, BootOnce, or a struct of those); give it one, or "
            "list it in scripts/global_protection_allowlist.tsv with its reader (#1012)")
    for key in sorted(set(allowed) - open_rows):
        why = "is now protected" if key in found else "is no longer a production global"
        errors.append(f"{ALLOWLIST.name}: stale row {key[0]} {key[1]}: {why}; delete the row")
    return errors


def summary(found):
    counts = collections.Counter(
        "scratch" if r["qualifier"] == "scratch" else r["protection"] for r in found.values())
    return ", ".join(f"{k} {v}" for k, v in sorted(counts.items()))


def main(argv):
    show = "--summary" in argv
    paths = [a for a in argv if a != "--summary"]
    if not paths:
        print(__doc__, file=sys.stderr)
        return 2
    try:
        found = globals_of([(p, pathlib.Path(p).read_text(encoding="utf-8")) for p in paths])
    except (TableError, OSError) as error:
        print(f"global-protection: {error}", file=sys.stderr)
        return 1
    if show:
        print(summary(found))
        return 0
    allowed, errors = parse_allowlist(ALLOWLIST.read_text(encoding="utf-8"))
    errors += check(found, allowed)
    if errors:
        for error in errors:
            print(f"global-protection: {error}", file=sys.stderr)
        return 1
    open_count = sum(1 for r in found.values() if unprotected(r))
    report_pass("global-protection",
                f"{len(found)} production globals; {open_count} unprotected, all "
                f"allow-listed ({summary(found)})",
                globals=len(found))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
