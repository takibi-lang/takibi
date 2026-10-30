#!/usr/bin/env python3
"""Controls for buildcheck_unread_globals.py over a small fixture tree."""

from __future__ import annotations

import collections
import pathlib
import sys
import tempfile

from buildcheck_unread_globals import find_unread, load
from pass_line import report_pass

SOURCE = """\
atomic_word_store(&stored, 0);
atomic_word_fetch_add(&counted, 1);
let v = atomic_word_fetch_add(&used, 1) + 1;
atomic_word_load(&loaded);
atomic_word_store(&gdb_read, 0);
"""
USES = {
    "stored": [("a.tkb", 1, "address")],
    "counted": [("a.tkb", 2, "address")],
    "used": [("a.tkb", 3, "address")],
    "loaded": [("a.tkb", 4, "address")],
    "gdb_read": [("a.tkb", 5, "address")],
    "assigned": [("a.tkb", 1, "write")],
    "read_too": [("a.tkb", 1, "write"), ("a.tkb", 1, "read")],
    "uart_rx_handler": [("a.tkb", 1, "write")],
}
GLOBALS = {name: "a.tkb" for name in USES}
GLOBALS.update({"unused": "a.tkb", "claim": "<builtin region>"})
EXPECTED = ["assigned", "counted", "stored", "unused"]


def main() -> int:
    with tempfile.TemporaryDirectory() as tmp:
        root = pathlib.Path(tmp)
        (root / "a.tkb").write_text(SOURCE)
        (root / "scripts").mkdir()
        (root / "scripts/p.gdb").write_text("x/4gu &gdb_read\n")
        table = root / "globals.tsv"
        table.write_text("# takibi globals\n"
                         "file\tline\tname\tv\tq\tt\tprotection\n"
                         "a\t1\tbacking\tp\t-\tT\tdma_fixed\n"
                         "a\t2\tplain\tp\t-\tT\tnone\n"
                         "# uses\nfile\tline\tname\tkind\tfunction\n"
                         "a\t3\tplain\twrite\tf\n")
        loaded: dict = {}
        loaded_uses: dict = collections.defaultdict(list)
        load(table, loaded, loaded_uses)
        if list(loaded) != ["plain"] or loaded_uses["plain"] != [("a", 3, "write")]:
            print(f"ERROR unread-globals controls: load read {loaded}",
                  file=sys.stderr)
            return 1
        uses = collections.defaultdict(list, USES)
        got = [row.split(": ")[1].split()[0]
               for row in find_unread(GLOBALS, uses, root)]
    if got != EXPECTED:
        print(f"ERROR unread-globals controls: got {got}, expected {EXPECTED}",
              file=sys.stderr)
        return 1
    report_pass("unread-globals controls",
                f"{len(GLOBALS)} claims -- stores, whole-statement fetch_adds, "
                "assignments and unused globals are refused; a used fetch_add, "
                "a load, a real read, a gdb reader, a dma_fixed backing, a "
                "builtin and the listed indirect call are not",
                cases=len(GLOBALS))
    return 0


if __name__ == "__main__":
    sys.exit(main())
