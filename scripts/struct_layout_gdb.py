#!/usr/bin/env python3
"""GDB convenience variables for named structs, from a compile's structs.tsv.

Usage: struct_layout_gdb.py <facts>/structs.tsv STRUCT...

`takibi --facts DIR` writes every struct's LLVM layout to DIR/structs.tsv
(GitHub issue #1027 step 2; CLI.md lists the fact files): one row per
field, then a `.size` and a `.members` row. The kernel's debugger helpers
source `set $takibi_<struct>_<field> = <offset>` lines; this prints them for
each STRUCT in the order given, so no second offset table exists. A STRUCT
the table does not hold is an error, never an empty block.
"""

import sys


def read_structs(path):
    structs = {}
    with open(path, encoding="ascii") as handle:
        header = handle.readline().rstrip("\n")
        if header != "struct\tfield\tvalue":
            raise SystemExit(f"{path}: unexpected header {header!r}")
        for number, line in enumerate(handle, start=2):
            cells = line.rstrip("\n").split("\t")
            if len(cells) != 3:
                raise SystemExit(f"{path}:{number}: expected 3 cells")
            structs.setdefault(cells[0], []).append((cells[1], cells[2]))
    return structs


def gdb_lines(name, rows):
    prefix = "takibi_" + name.lower() + "_"
    out = [f"# GENERATED from structs.tsv (takibi --facts), struct {name}",
           "# LLVM target layout; source this file from gdb before its reader."]
    fields = [(f, v) for f, v in rows if not f.startswith(".")]
    meta = dict((f, v) for f, v in rows if f.startswith("."))
    out += [f"set ${prefix}{field} = {value}" for field, value in fields]
    out.append(f"set ${prefix}size = {meta['.size']}")
    out.append(f"set ${prefix}members = {meta['.members']}")
    return out


def main(argv):
    if len(argv) < 3:
        raise SystemExit(__doc__.strip().splitlines()[2])
    structs = read_structs(argv[1])
    lines = []
    for name in argv[2:]:
        if name not in structs:
            raise SystemExit(f"FAIL struct-layout: {argv[1]} has no struct {name!r}")
        lines += gdb_lines(name, structs[name])
    sys.stdout.write("\n".join(lines) + "\n")


if __name__ == "__main__":
    main(sys.argv)
