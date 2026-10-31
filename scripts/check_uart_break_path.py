#!/usr/bin/env python3
"""A serial BREAK goes through scripts/uart_break.py (#1300).

pyserial's send_break releases after about 100 ms whatever duration it is
given, and the release can corrupt the DDB prompt arriving at that moment.
uart_break.py explains the mechanism and holds the line past the answer.

THE RULE. No scripts/*.py calls `.send_break(...)` or `tcsendbreak`. A fake
port may still define a method of that name; only calls are refused.
"""

import ast
import sys
from pathlib import Path

from pass_line import report_pass
from source_scan import per_file

ROOT = Path(__file__).resolve().parent.parent
REFUSED = {"send_break", "tcsendbreak"}


@per_file
def problems_in(source, name):
    """Each refused call in one module's source, as a message."""
    found = []
    for node in ast.walk(ast.parse(source)):
        if (isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute)
                and node.func.attr in REFUSED):
            found.append(f"{name}:{node.lineno}: .{node.func.attr}() releases "
                         "the BREAK early; use uart_break.hold_break (#1300)")
    return tuple(found)


def problems(source):
    return problems_in(source, "<source>")


def main():
    found = []
    scripts = sorted((ROOT / "scripts").glob("*.py"))
    for path in scripts:
        found += problems_in(path.read_text(), path.name)
    if found:
        print("\n".join(found), file=sys.stderr)
        return 1
    report_pass("uart-break-path", "no script sends a BREAK that releases early",
                scripts=len(scripts))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
