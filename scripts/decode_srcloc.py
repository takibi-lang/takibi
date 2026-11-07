#!/usr/bin/env python3
"""Decode a SrcLoc back into file:line (GitHub issue #1024).

src_loc() returns an opaque SrcLoc, one u32: the file's index in the
compile's table << 20 | the line. The compiler writes the table as
srcloc.tsv under `--facts DIR` (one "index<TAB>path" row per file of the
`use` closure). user_payload's fail_if prints a failing check as
"srcloc=0x<8 hex digits>"; a lane runs this on its capture.

It changes no verdict: it prints one "srcloc: 0x... = file:line" line per
SrcLoc it finds and exits 0, so the lane's own checks still decide.

Usage:
  decode_srcloc.py TABLE 0xVALUE ...      decode the given values
  decode_srcloc.py TABLE --log CAPTURE    decode every srcloc= in a capture
A missing TABLE (a lane that did not build the payload) prints nothing.
"""

import re
import sys

LINE_BITS = 20
SRCLOC_RE = re.compile(r"srcloc=(0x[0-9a-fA-F]{1,8})")


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


def decode_log(table, lines):
    """One decoded line per srcloc= in the capture, in order."""
    out = []
    for text in lines:
        for match in SRCLOC_RE.finditer(text):
            value = int(match.group(1), 16)
            out.append(f"srcloc: {match.group(1)} = {decode(table, value)}")
    return out


def main(argv):
    if len(argv) < 3:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    try:
        table = read_table(argv[1])
    except FileNotFoundError:
        return 0
    if argv[2] == "--log":
        with open(argv[3], encoding="utf-8", errors="replace") as f:
            for line in decode_log(table, f):
                print(line)
        return 0
    for text in argv[2:]:
        print(f"srcloc: {text} = {decode(table, int(text, 0))}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
