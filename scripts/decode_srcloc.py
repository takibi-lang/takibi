#!/usr/bin/env python3
"""Decode a SrcLoc back into file:line (GitHub issues #1024, #1412).

src_loc() returns an opaque SrcLoc, one u32: the file's index in the
compile's table << 20 | the line. The compiler writes the table as
srcloc.tsv under `--facts DIR` (one "index<TAB>path" row per file of the
`use` closure). A SrcLoc means something only against the table of the
compile that made it, so a failing EL0 check prints which image it is:

    user_payload:   ... failed srcloc=0x<8 hex>           (untagged)
    other probes:   ... FAIL srcloc[<object>]=0x<8 hex>   (el0_fail.tkb)

where <object> names <object>.o.facts/srcloc.tsv under the build directory.
A lane runs this on its capture. It changes no verdict: it prints one
"srcloc: ... = file:line" line per SrcLoc it finds and exits 0.

Usage:
  decode_srcloc.py TABLE 0xVALUE ...      decode the given values
  decode_srcloc.py TABLE --log CAPTURE    decode every untagged srcloc=
  decode_srcloc.py --facts-dir DIR --default OBJECT --log CAPTURE
      decode every srcloc= and srcloc[OBJECT]=; an untagged one against
      DIR/OBJECT.o.facts/srcloc.tsv
A missing table prints nothing for its values (a lane that did not build
the image).
"""

import os
import re
import sys

LINE_BITS = 20
SRCLOC_RE = re.compile(r"srcloc(?:\[([A-Za-z0-9_.-]+)\])?=(0x[0-9a-fA-F]{1,8})")


def read_table(path):
    """{index: path} from a srcloc.tsv."""
    table = {}
    with open(path, encoding="utf-8") as f:
        for line in f:
            if line.startswith("#") or not line.strip():
                continue
            index, name = line.rstrip("\n").split("\t", 1)
            table[int(index)] = name
    return table


def decode(table, value):
    """'file:line' for one SrcLoc value."""
    index = value >> LINE_BITS
    line = value & ((1 << LINE_BITS) - 1)
    name = table.get(index, f"<file index {index} not in the table>")
    return f"{name}:{line}"


def decode_log(tables, lines, default=None):
    """One decoded line per srcloc= in the capture, in order. `tables` maps
    an object name (None for the untagged form) to its table; a SrcLoc
    whose table is missing is skipped."""
    out = []
    for text in lines:
        for match in SRCLOC_RE.finditer(text):
            tag = match.group(1) or default
            table = tables.get(tag)
            if table is None:
                continue
            value = int(match.group(2), 16)
            label = f"[{match.group(1)}]" if match.group(1) else ""
            out.append(f"srcloc{label}: {match.group(2)} = {decode(table, value)}")
    return out


def tables_from_dir(directory):
    """{object: table} for every <object>.o.facts/srcloc.tsv in directory."""
    tables = {}
    try:
        entries = os.listdir(directory)
    except FileNotFoundError:
        return tables
    for entry in entries:
        if entry.endswith(".o.facts"):
            path = os.path.join(directory, entry, "srcloc.tsv")
            if os.path.exists(path):
                tables[entry[:-len(".o.facts")]] = read_table(path)
    return tables


def main(argv):
    if len(argv) >= 6 and argv[1] == "--facts-dir" and argv[3] == "--default" \
            and argv[5] == "--log" and len(argv) == 7:
        tables = tables_from_dir(argv[2])
        with open(argv[6], encoding="utf-8", errors="replace") as f:
            for line in decode_log(tables, f, default=argv[4]):
                print(line)
        return 0
    if len(argv) < 3:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    try:
        table = read_table(argv[1])
    except FileNotFoundError:
        return 0
    if argv[2] == "--log":
        with open(argv[3], encoding="utf-8", errors="replace") as f:
            for line in decode_log({None: table}, f):
                print(line)
        return 0
    for text in argv[2:]:
        print(f"srcloc: {text} = {decode(table, int(text, 0))}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
