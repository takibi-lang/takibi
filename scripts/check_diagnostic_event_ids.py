#!/usr/bin/env python3
"""Reject duplicate or out-of-range fixed diagnostic event ids."""

import re
import sys
from pathlib import Path


SOURCE = Path("kernel/lib/diagnostic_ring.tkb")
PATTERN = re.compile(
    r"^const\s+(DiagnosticEvent[A-Za-z0-9_]*)\s*:\s*usize\s*=\s*"
    r"(0x[0-9a-fA-F]+|[0-9]+)\s*;",
    re.MULTILINE,
)


def main() -> int:
    declarations = PATTERN.findall(SOURCE.read_text())
    if not declarations:
        print("FAIL diagnostic-event-ids: no fixed event ids found", file=sys.stderr)
        return 1
    values: dict[int, str] = {}
    failed = False
    for name, literal in declarations:
        value = int(literal, 0)
        if value == 0 or value > 0xFFFF:
            print(
                f"FAIL diagnostic-event-ids: {name}={literal} is outside 1..0xffff",
                file=sys.stderr,
            )
            failed = True
        previous = values.get(value)
        if previous is not None:
            print(
                f"FAIL diagnostic-event-ids: {name} and {previous} both use {literal}",
                file=sys.stderr,
            )
            failed = True
        values[value] = name
    if failed:
        return 1
    print(
        f"PASS diagnostic-event-ids: {len(declarations)} fixed ids are unique and 16-bit"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
