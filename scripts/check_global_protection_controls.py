#!/usr/bin/env python3
"""Negative controls for buildcheck_global_protection.py (GitHub issue #1012).

The ratchet itself runs in kernelbuild on the compiler's tables; these
controls feed it synthetic tables, so they need no build: an unlisted
unprotected global, a stale row (migrated or deleted), a duplicate row, a
row with no reader, a scratch global, a test or model file, an empty table,
another format and an unknown class must each be refused or handled as the
docstring there says. The tracked allow-list is also read for shape.
"""

import sys

import buildcheck_global_protection as g
from pass_line import report_pass

HEAD = "# takibi globals, format 2; see docs/GLOBAL_PROTECTION.md\n" + "\t".join(g.COLUMNS) + "\n"


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
           refused(lambda: g.parse_table(HEAD.replace("format 2", "format 1"), "t")))
    # GitHub issue #769: format 2's uses table follows the rows.
    expect("the uses table after the rows is not read as globals",
           len(g.parse_table(table(row("kernel/a.tkb", "x", "atomic"))
                             + "# uses\nfile\tline\tname\tkind\tfunction\n"
                             + "kernel/a.tkb\t3\tx\tread\tf\n", "t")) == 1)
    expect("unknown class is refused",
           refused(lambda: g.parse_table(table(row("kernel/a.tkb", "x", "locked")), "t")))

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
