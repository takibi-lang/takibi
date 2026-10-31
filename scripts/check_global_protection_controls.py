#!/usr/bin/env python3
"""Negative controls for buildcheck_global_protection.py (GitHub issue #1012).

The ratchet itself runs in kernelbuild on the compiler's tables; these
controls feed it synthetic tables, so they need no build: an unlisted
unprotected global, a stale row (migrated or deleted), a duplicate row, a
row with no reader, a scratch global, a test or model file, an empty table,
another format and an unknown class must each be refused or handled as the
docstring there says. The --drop/--prune rewrite (#1201) must refuse a drop
or a write that loses an unprotected global's row. A reviewed row's named
reader must be a real non-write use or a file naming the global. The tracked
allow-list is also read for shape.
"""

import sys

import buildcheck_global_protection as g
from pass_line import report_pass

HEAD = "# takibi globals, format 3; see docs/GLOBAL_PROTECTION.md\n" + "\t".join(g.COLUMNS) + "\n"


def table(*rows):
    return HEAD + "".join("\t".join(r) + "\n" for r in rows)


def row(file, name, protection="none", qualifier="-"):
    return (file, "1", name, "private", qualifier, "usize", protection)


def errors(text, allow):
    allowed, errs = g.parse_allowlist(allow, "allow")
    return errs + g.check(g.globals_of([("t", text)]), allowed)


def refused(fn):
    try:
        fn()
    except g.TableError:
        return True
    return False


def main():
    failures = []
    checked = []

    def expect(what, ok):
        checked.append(what)
        if not ok:
            failures.append(what)

    base = table(row("kernel/a.tkb", "x"), row("kernel/a.tkb", "w", "atomic"))
    expect("listed unprotected global passes", errors(base, "kernel/a.tkb\tx\tddb\n") == [])
    expect("unlisted unprotected global is refused",
           any("shows no protection" in e for e in errors(base, "")))
    expect("protected global listed is stale",
           any("now protected" in e for e in errors(base, "kernel/a.tkb\tx\tr\nkernel/a.tkb\tw\tr\n")))
    expect("deleted global listed is stale",
           any("no longer" in e for e in errors(base, "kernel/a.tkb\tx\tr\nkernel/a.tkb\tgone\tr\n")))
    expect("duplicate row is refused",
           any("duplicate" in e for e in errors(base, "kernel/a.tkb\tx\tr\nkernel/a.tkb\tx\tr\n")))
    expect("row without reader is refused",
           any("want file" in e for e in errors(base, "kernel/a.tkb\tx\t \n")))
    scratch = table(row("kernel/a.tkb", "s", "none", "scratch"), row("kernel/a.tkb", "w", "atomic"))
    expect("scratch global counts as unprotected", errors(scratch, "") != [])
    tests = table(row("kernel/tests/t.tkb", "x"), row("kernel/models/m.tkb", "y"),
                  row("kernel/a.tkb", "w", "atomic"))
    expect("test and model globals are not production", errors(tests, "") == [])
    expect("two tables are unioned", len(g.globals_of(
        [("q", table(row("kernel/a.tkb", "x"))), ("r", table(row("kernel/a.tkb", "x")))])) == 1)
    expect("empty table is refused", refused(lambda: g.globals_of([("t", HEAD)])))
    expect("no production rows is refused",
           refused(lambda: g.globals_of([("t", table(row("kernel/tests/t.tkb", "x")))])))
    expect("other format is refused",
           refused(lambda: g.parse_table(HEAD.replace("format 3", "format 1"), "t")))
    # GitHub issue #769: format 2's uses table follows the rows.
    expect("the uses table after the rows is not read as globals",
           len(g.parse_table(table(row("kernel/a.tkb", "x", "atomic"))
                             + "# uses\nfile\tline\tname\tkind\tfunction\n"
                             + "kernel/a.tkb\t3\tx\tread\tf\n", "t")) == 1)
    expect("unknown class is refused",
           refused(lambda: g.parse_table(table(row("kernel/a.tkb", "x", "locked")), "t")))

    # GitHub issue #1201: the --drop/--prune rewrite.
    moved = table(row("kernel/a.tkb", "x"), row("kernel/a.tkb", "w", "atomic"),
                  row("kernel/b.tkb", "x", "atomic"))
    found = g.globals_of([("t", moved)])
    allow = "# head\nkernel/a.tkb\tx\tr\nkernel/a.tkb\tw\tr\nkernel/b.tkb\tx\tr\n"
    allowed, _ = g.parse_allowlist(allow, "allow")
    keys, errs = g.drop_keys(found, allowed, ["w"])
    expect("drop of a protected global's row is accepted",
           errs == [] and keys == {("kernel/a.tkb", "w")})
    keys, errs = g.drop_keys(found, allowed, ["x"])
    expect("drop of a name an unprotected global still holds is refused",
           any("still an unprotected" in e for e in errs))
    keys, errs = g.drop_keys(found, allowed, ["kernel/b.tkb:x"])
    expect("FILE:NAME drops one file's row", errs == [] and keys == {("kernel/b.tkb", "x")})
    keys, errs = g.drop_keys(found, allowed, ["nothing"])
    expect("drop of an unknown name is refused", any("no row" in e for e in errs))
    expect("prune takes every stale row",
           g.stale_keys(found, allowed) == {("kernel/a.tkb", "w"), ("kernel/b.tkb", "x")})
    kept = g.rewrite_allowlist(allow, found, g.stale_keys(found, allowed))
    expect("rewrite keeps comments and the unprotected row",
           kept == "# head\nkernel/a.tkb\tx\tr\n")
    expect("rewrite that loses an unprotected global's row is refused",
           refused(lambda: g.rewrite_allowlist(allow, found, {("kernel/a.tkb", "x")})))
    expect("rewrite of an emptied list is refused",
           refused(lambda: g.rewrite_allowlist(allow, found, set(allowed))))

    # A named reader must exist; it is not judged correct.
    uses = g.parse_uses(table(row("kernel/a.tkb", "x")) + "# uses\nfile\tline\tname\tkind\tfunction\n"
                        "kernel/a.tkb\t3\tx\tload\tf\nkernel/a.tkb\t4\tx\twrite\tw\n"
                        "kernel/a.tkb\t5\tx\tatomic_store\ts\n")

    def reader(cell, name="x"):
        return g.reader_errors({("kernel/a.tkb", name): cell}, uses, g.ROOT)

    expect("unreviewed names no reader", reader("unreviewed; no idea") == [])
    expect("a function with a read passes", reader("read-by f: because") == [])
    expect("a missing function is refused", any("no use" in e for e in reader("read-by nope: because")))
    expect("a function that only writes is refused", reader("read-by w: because") != [])
    expect("a function that only atomically stores is refused", reader("read-by s: because") != [])
    expect("one bad name among several is refused", reader("read-by f,nope: because") != [])
    expect("a cell of plain prose is refused", any("neither" in e for e in reader("the debugger")))
    expect("read-by with no reason is refused", any("neither" in e for e in reader("read-by f:")))
    expect("a script naming the global passes",
           reader("read-by scripts/buildcheck_global_protection.py: because", "USES_MARK") == [])
    expect("a script not naming the global is refused",
           reader("read-by scripts/buildcheck_global_protection.py: because", "no_such_word") != [])
    expect("a missing script is refused", reader("read-by scripts/no_such_file: because") != [])
    expect("unreviewed rows are counted", g.unreviewed_count(
        {("a", "x"): "unreviewed", ("a", "y"): "read-by f: why"}) == 1)

    tracked, shape = g.parse_allowlist(g.ALLOWLIST.read_text(encoding="utf-8"))
    expect("tracked allow-list is well formed", shape == [])
    if failures:
        for f in failures:
            print(f"FAIL global-protection-controls: {f}", file=sys.stderr)
        return 1
    report_pass("global-protection-controls",
                f"{len(checked)} controls refused or passed as specified; allow-list {len(tracked)} rows",
                rows=len(tracked))
    return 0


if __name__ == "__main__":
    sys.exit(main())
