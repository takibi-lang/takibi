#!/usr/bin/env python3
"""Keep the sysinit boot-log snapshot before the variable-length trace report.

The hosted #609 armed lane retained 257 records in a 256-record ring, so
the first boot marker disappeared. Trace size depends on observed scheduling
and its buffer can hold 512 events. Snapshot before the trace instead of
budgeting for a particular run's event count. This checks the two canonical
bare commands in the maintained script, not arbitrary shell control flow.
"""

import pathlib
import re
import sys

from pass_line import report_pass

ROOT = pathlib.Path(__file__).resolve().parents[1]
INIT = ROOT / "kernel/tests/ext2/init.sh"


def check(text):
    positions = []
    for command in ("/bin/dmesg", "/bin/protocol-trace"):
        matches = list(re.finditer(rf"^\s*{re.escape(command)}\s*$", text, re.M))
        if len(matches) != 1:
            return positions, f"expected one bare {command} command, found {len(matches)}"
        positions.append(matches[0].start())
    if positions[0] > positions[1]:
        return positions, "boot dmesg must precede protocol-trace to preserve the first marker"
    return positions, None


def main():
    try:
        positions, problem = check(INIT.read_text(encoding="ascii"))
    except (OSError, UnicodeError) as error:
        problem = str(error)
    if problem:
        print(f"FAIL boot-log-snapshot: {problem}")
        return 1
    report_pass("boot-log-snapshot",
                "the boot dmesg snapshot precedes the variable-length protocol report",
                commands=len(positions))
    return 0


if __name__ == "__main__":
    sys.exit(main())
