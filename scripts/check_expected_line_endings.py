#!/usr/bin/env python3
"""Reject tracked stdout fixtures that mix LF and CRLF terminators."""

from __future__ import annotations

import pathlib
import subprocess
import sys


ROOT = pathlib.Path(__file__).resolve().parents[1]
FIXTURE_ROOTS = ("kernel", "linux_user", "examples")


def tracked_fixtures() -> list[pathlib.Path]:
    result = subprocess.run(
        ["git", "ls-files", "-z", "--", *FIXTURE_ROOTS],
        cwd=ROOT,
        check=True,
        stdout=subprocess.PIPE,
    )
    return [
        ROOT / pathlib.Path(raw.decode("utf-8"))
        for raw in result.stdout.split(b"\0")
        if raw.endswith(b".expected")
    ]


def display_path(path: pathlib.Path) -> str:
    try:
        return path.resolve().relative_to(ROOT).as_posix()
    except ValueError:
        return str(path)


def main() -> int:
    fixtures = [pathlib.Path(arg) for arg in sys.argv[1:]] or tracked_fixtures()
    mixed = False
    for path in fixtures:
        data = path.read_bytes()
        crlf_count = data.count(b"\r\n")
        lf_count = data.count(b"\n") - crlf_count
        if lf_count and crlf_count:
            mixed = True
            print(
                f"ERROR expected-line-endings: {display_path(path)} mixes "
                f"LF={lf_count} CRLF={crlf_count}",
                file=sys.stderr,
            )

    if mixed:
        return 1

    print(
        f"PASS expected-line-endings: {len(fixtures)} stdout fixtures use "
        "one newline convention each"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
