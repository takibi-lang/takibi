#!/usr/bin/env python3
"""Split a batched UART stream and compare each case with its fixture."""

import pathlib
import re
import sys


MARKER = re.compile(rb"@@TAKIBI_TEST:([A-Za-z0-9_]+)@@\n")


def escaped(data: bytes) -> str:
    return repr(data)[1:]


def load_manifest(path: pathlib.Path) -> list[tuple[str, pathlib.Path]]:
    cases = []
    for line_number, line in enumerate(path.read_text(encoding="ascii").splitlines(), 1):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        fields = line.split()
        if len(fields) != 2:
            raise ValueError(f"{path}:{line_number}: expected NAME EXPECTED_PATH")
        cases.append((fields[0], pathlib.Path(fields[1])))
    return cases


def main() -> int:
    if len(sys.argv) != 3:
        print(
            "usage: check_suite_output.py OUTPUT MANIFEST",
            file=sys.stderr,
        )
        return 2

    output = pathlib.Path(sys.argv[1]).read_bytes()
    requested = load_manifest(pathlib.Path(sys.argv[2]))
    matches = list(MARKER.finditer(output))
    actual_names = [match.group(1).decode("ascii") for match in matches]
    requested_names = [name for name, _ in requested]

    if actual_names != requested_names:
        print(
            "ERROR\tmarker order mismatch: expected "
            + ",".join(requested_names)
            + " got "
            + ",".join(actual_names)
        )
        return 1

    failed = False
    for index, (name, expected_path) in enumerate(requested):
        start = matches[index].end()
        end = matches[index + 1].start() if index + 1 < len(matches) else len(output)
        actual = output[start:end]
        expected = expected_path.read_bytes()
        if actual == expected:
            print(f"PASS\t{name}")
        else:
            failed = True
            print(f"FAIL\t{name}\t{escaped(expected)}\t{escaped(actual)}")

    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
