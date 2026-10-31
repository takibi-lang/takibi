#!/usr/bin/env python3
"""The global protection ratchet (GitHub issue #1012 slice 1).

Reads the compiler's `--facts globals.tsv` tables of both kernels
(docs/GLOBAL_PROTECTION.md) and refuses:

- a production `let mut` global whose type shows no protection (protection
  `none`, or a `scratch` global) and that is not listed in
  scripts/global_protection_allowlist.tsv;
- a listed row that no longer names such a global (it was migrated,
  renamed or deleted): the list only shrinks, and a stale row would let
  the next unprotected global of that name in for free;
- a duplicate row, a row without a reader cell, an empty table;
- a reader cell that is neither `unreviewed...` nor `read-by NAME[,NAME...]: why`,
  or a NAME that is not a reader of that global: a function must have a use of
  the global other than a write in the uses table, and a path with a slash must
  be a file naming the global. This shows the reader exists, nothing about
  whether it is correct (docs/GLOBAL_PROTECTION.md).

Production means compiled into a kernel image under kernel/ and outside
kernel/tests and kernel/models. The row count of the allow-list is the
ledger category `unprotected_globals` (scripts/check_trust_ledger.py), so a
rise needs an issue there and a fall names its rule.

  buildcheck_global_protection.py QEMU.facts/globals.tsv RPI5.facts/globals.tsv
  buildcheck_global_protection.py --summary TABLE...   counts per class

GitHub issue #1201: a migration deletes its rows with the script rather than
with a hand filter (one emptied the whole list during #1012 slice 3):

  buildcheck_global_protection.py --drop NAME [--drop NAME...] TABLE...
  buildcheck_global_protection.py --prune TABLE...

NAME is a global's name, or FILE:NAME when two files share it. --drop
removes the rows it names, and refuses a name that matches no row or that
still names an unprotected global. --prune removes every stale row. Either
writes the list only if every still-unprotected global keeps its row and
nothing but the removed rows changed; comments and order are kept. The
tables are the kernelbuild's, GLOBAL_PROTECTION_TABLES in the Makefile:
kernel/build/{qemu,rpi5}/main.o.facts/globals.tsv.
"""

import collections
import pathlib
import re
import sys

from pass_line import report_pass

ROOT = pathlib.Path(__file__).resolve().parent.parent
ALLOWLIST = ROOT / "scripts" / "global_protection_allowlist.tsv"
FORMAT = 3
USES_MARK = "# uses"
WRITE_KINDS = {"write", "atomic_store"}
READ_BY = re.compile(r"read-by ([^\s:,]+(?:,[^\s:,]+)*): \S")
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
        # Format 2 (GitHub issue #769): the uses table follows; this reader
        # needs only the globals.
        if line == USES_MARK:
            break
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


def parse_uses(text):
    """global name -> the functions with a use of it that is not a write."""
    readers = collections.defaultdict(set)
    lines = text.splitlines()
    if USES_MARK not in lines:
        return readers
    for line in lines[lines.index(USES_MARK) + 2:]:
        cells = line.split("\t")
        if len(cells) == 5 and cells[3] not in WRITE_KINDS:
            readers[cells[2]].add(cells[4])
    return readers


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


def reader_errors(allowed, readers, root=ROOT):
    """A reviewed row's named readers exist; `unreviewed` rows name none."""
    errors = []
    for (file, name), cell in sorted(allowed.items()):
        if cell.startswith("unreviewed"):
            continue
        match = READ_BY.match(cell)
        if not match:
            errors.append(f"{ALLOWLIST.name}: {file} {name}: reader is neither unreviewed "
                          "nor 'read-by NAME[,NAME...]: why'")
            continue
        for reader in match.group(1).split(","):
            if "/" in reader:
                path = root / reader
                if not path.is_file() or not re.search(
                        rf"\b{re.escape(name)}\b", path.read_text(encoding="utf-8")):
                    errors.append(f"{ALLOWLIST.name}: {file} {name}: {reader} does not "
                                  "exist or does not name the global")
            elif reader not in readers.get(name, ()):
                errors.append(f"{ALLOWLIST.name}: {file} {name}: {reader} has no use of "
                              "the global other than a write")
    return errors


def unreviewed_count(allowed):
    return sum(1 for cell in allowed.values() if cell.startswith("unreviewed"))


def stale_keys(found, allowed):
    open_rows = {k for k, r in found.items() if unprotected(r)}
    return set(allowed) - open_rows


def drop_keys(found, allowed, names):
    """The rows NAMES select, or the errors that refuse the drop."""
    keys, errors = set(), []
    stale = stale_keys(found, allowed)
    for name in names:
        if ":" in name:
            file, bare = name.rsplit(":", 1)
            matches = {k for k in allowed if k == (file, bare)}
        else:
            matches = {k for k in allowed if k[1] == name}
        if not matches:
            errors.append(f"--drop {name}: no row of {ALLOWLIST.name} names it")
        for key in sorted(matches - stale):
            errors.append(f"--drop {name}: {key[0]} {key[1]} is still an unprotected "
                          "global; protect it before dropping its row")
        keys |= matches & stale
    return keys, errors


def rewrite_allowlist(text, found, removed):
    """TEXT without the rows REMOVED, or TableError when the result would
    lose a row an unprotected global still needs, or change anything else."""
    kept_lines = []
    for line in text.splitlines(keepends=True):
        cells = line.rstrip("\n").split("\t")
        if (line.strip() and not line.startswith("#") and len(cells) == 3
                and (cells[0], cells[1]) in removed):
            continue
        kept_lines.append(line)
    result = "".join(kept_lines)
    before, before_errors = parse_allowlist(text)
    after, after_errors = parse_allowlist(result)
    if before_errors or after_errors:
        raise TableError("the allow-list is malformed; fix it by hand first: "
                         + "; ".join(before_errors + after_errors))
    lost = {k for k, r in found.items() if unprotected(r)} - set(after)
    if lost:
        raise TableError("refusing to write: rows for still-unprotected globals would "
                         "be lost: " + ", ".join(f"{f} {n}" for f, n in sorted(lost)))
    if set(before) - set(after) != set(removed) or set(after) - set(before):
        raise TableError("refusing to write: the rewrite changed rows other than "
                         "the ones removed")
    if any(after[k] != before[k] for k in after):
        raise TableError("refusing to write: a kept row's reader changed")
    return result


def summary(found):
    counts = collections.Counter(
        "scratch" if r["qualifier"] == "scratch" else r["protection"] for r in found.values())
    return ", ".join(f"{k} {v}" for k, v in sorted(counts.items()))


def edit(found, drops, prune):
    text = ALLOWLIST.read_text(encoding="utf-8")
    allowed, errors = parse_allowlist(text)
    if errors:
        for error in errors:
            print(f"global-protection: {error}", file=sys.stderr)
        return 1
    removed, errors = drop_keys(found, allowed, drops)
    if prune:
        removed |= stale_keys(found, allowed)
    if errors:
        for error in errors:
            print(f"global-protection: {error}", file=sys.stderr)
        return 1
    try:
        result = rewrite_allowlist(text, found, removed)
    except TableError as error:
        print(f"global-protection: {error}", file=sys.stderr)
        return 1
    ALLOWLIST.write_text(result, encoding="utf-8")
    for file, name in sorted(removed):
        print(f"global-protection: dropped {file} {name}")
    print(f"global-protection: {len(allowed)} -> {len(allowed) - len(removed)} rows")
    return 0


def main(argv):
    show = "--summary" in argv
    prune = "--prune" in argv
    drops, paths, index = [], [], 0
    while index < len(argv):
        arg = argv[index]
        if arg == "--drop":
            if index + 1 >= len(argv):
                print("global-protection: --drop needs a NAME", file=sys.stderr)
                return 2
            drops.append(argv[index + 1])
            index += 2
            continue
        if arg not in ("--summary", "--prune"):
            paths.append(arg)
        index += 1
    if not paths:
        print(__doc__, file=sys.stderr)
        return 2
    try:
        tables = [(p, pathlib.Path(p).read_text(encoding="utf-8")) for p in paths]
        found = globals_of(tables)
    except (TableError, OSError) as error:
        print(f"global-protection: {error}", file=sys.stderr)
        return 1
    if show:
        print(summary(found))
        return 0
    if drops or prune:
        return edit(found, drops, prune)
    allowed, errors = parse_allowlist(ALLOWLIST.read_text(encoding="utf-8"))
    errors += check(found, allowed)
    readers = collections.defaultdict(set)
    for _, text in tables:
        for name, functions in parse_uses(text).items():
            readers[name] |= functions
    errors += reader_errors(allowed, readers)
    if errors:
        for error in errors:
            print(f"global-protection: {error}", file=sys.stderr)
        return 1
    open_count = sum(1 for r in found.values() if unprotected(r))
    report_pass("global-protection",
                f"{len(found)} production globals; {open_count} unprotected, all "
                f"allow-listed, {unreviewed_count(allowed)} of those rows unreviewed "
                f"({summary(found)})",
                globals=len(found))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
