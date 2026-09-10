#!/usr/bin/env python3
"""Reject a linked ELF when a required symbol is under-aligned."""

import subprocess
import sys

from pass_line import report_pass


LLVM_NM = "llvm-nm-19"


def symbol_address(elf_path, symbol):
    result = subprocess.run(
        [LLVM_NM, "--defined-only", elf_path],
        check=True,
        capture_output=True,
        text=True,
    )
    matches = []
    defined = 0
    for line in result.stdout.splitlines():
        fields = line.split()
        if len(fields) < 3:
            continue
        defined += 1
        if fields[-1] == symbol:
            matches.append(int(fields[0], 16))
    if len(matches) != 1:
        raise ValueError(
            "expected exactly one defined symbol named %s, found %d"
            % (symbol, len(matches))
        )
    return matches[0], defined


def main():
    if len(sys.argv) != 4:
        print(
            "usage: buildcheck_elf_symbol_alignment.py <elf> <symbol> <alignment>",
            file=sys.stderr,
        )
        return 1

    elf_path, symbol = sys.argv[1], sys.argv[2]
    try:
        alignment = int(sys.argv[3], 0)
        if alignment <= 0 or alignment & (alignment - 1):
            raise ValueError("alignment must be a positive power of two")
        address, defined_symbols = symbol_address(elf_path, symbol)
    except (OSError, subprocess.CalledProcessError, ValueError) as error:
        print("FAIL elf-symbol-alignment: %s" % error, file=sys.stderr)
        return 1

    if address & (alignment - 1):
        print(
            "FAIL elf-symbol-alignment: %s at 0x%x is not %d-byte aligned"
            % (symbol, address, alignment),
            file=sys.stderr,
        )
        return 1

    report_pass(
        "elf-symbol-alignment",
        "%s at 0x%x is %d-byte aligned" % (symbol, address, alignment),
        defined_symbols=defined_symbols,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
