#!/usr/bin/env python3
"""Controls for space_delta.py's arguments: an option is never a base ref."""

from __future__ import annotations

import contextlib
import io
import sys

from pass_line import report_pass
from space_delta import parse_args


def exit_code(argv: list[str]) -> int | None:
    with contextlib.redirect_stdout(io.StringIO()), \
            contextlib.redirect_stderr(io.StringIO()):
        try:
            parse_args(argv)
        except SystemExit as stop:
            return stop.code
    return None


def main() -> int:
    claims = [
        (parse_args([]).base == "origin/main", "no argument is not origin/main"),
        (parse_args(["abc123"]).base == "abc123", "a ref is not taken as the base"),
        (exit_code(["--help"]) == 0, "--help did not exit 0 before any build"),
        (exit_code(["--bogus"]) == 2, "an unknown option was not refused"),
    ]
    bad = [why for held, why in claims if not held]
    for row in bad:
        print(f"ERROR space-delta controls: {row}", file=sys.stderr)
    if bad:
        return 1
    report_pass("space-delta controls",
                "default and named bases are taken; --help and an unknown "
                "option stop before any build", cases=len(claims))
    return 0


if __name__ == "__main__":
    sys.exit(main())
