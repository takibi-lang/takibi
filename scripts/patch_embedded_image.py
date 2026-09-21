#!/usr/bin/env python3
"""Replace one exact embedded image in a linked binary."""

import argparse
from pathlib import Path
import sys


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("binary", type=Path)
    parser.add_argument("original", type=Path)
    parser.add_argument("replacement", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()

    binary = args.binary.read_bytes()
    original = args.original.read_bytes()
    replacement = args.replacement.read_bytes()
    if len(original) != len(replacement):
        print("error: embedded image replacement size differs", file=sys.stderr)
        return 1
    occurrences = binary.count(original)
    if occurrences != 1:
        print(
            "error: expected embedded image exactly once, "
            f"found {occurrences}",
            file=sys.stderr,
        )
        return 1
    patched = binary.replace(original, replacement, 1)
    temporary = args.output.with_name(args.output.name + ".tmp")
    temporary.write_bytes(patched)
    temporary.chmod(args.binary.stat().st_mode)
    temporary.replace(args.output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
