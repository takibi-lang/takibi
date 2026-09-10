#!/usr/bin/env python3
"""Positive and faithful negative controls for the ELF alignment guard."""

from pathlib import Path
import subprocess
import sys
import tempfile

from pass_line import CaseCount, report_pass


ROOT = Path(__file__).resolve().parent.parent
CHECKER = ROOT / "scripts" / "buildcheck_elf_symbol_alignment.py"
LLVM_MC = "llvm-mc-19"


# GitHub issue #526: a control asserts the number of scenarios it ran.
CASES = CaseCount()


def checked(obj, symbol, alignment):
    """One scenario: run the guard against a fixture and take its result."""
    CASES.note()
    return subprocess.run(
        [sys.executable, str(CHECKER), str(obj), symbol, str(alignment)],
        capture_output=True,
        text=True,
    )


def main():
    with tempfile.TemporaryDirectory() as directory:
        source = Path(directory) / "alignment.s"
        obj = Path(directory) / "alignment.o"
        source.write_text(
            ".section .bss,\"aw\",@nobits\n"
            ".byte 0\n"
            ".p2align 3\n"
            ".globl misaligned_pool\n"
            "misaligned_pool:\n"
            ".space 8\n"
            ".p2align 4\n"
            ".globl aligned_pool\n"
            "aligned_pool:\n"
            ".space 8\n",
            encoding="ascii",
        )
        subprocess.run(
            [LLVM_MC, "--triple=aarch64-none-elf", "--filetype=obj",
             str(source), "-o", str(obj)],
            check=True,
        )

        positive = checked(obj, "aligned_pool", 16)
        if positive.returncode != 0:
            print("FAIL elf-symbol-alignment control: aligned fixture failed")
            print(positive.stdout + positive.stderr, end="")
            return 1

        negative = checked(obj, "misaligned_pool", 16)
        expected = "misaligned_pool at 0x8 is not 16-byte aligned"
        if negative.returncode == 0:
            print("FAIL elf-symbol-alignment control: bad fixture succeeded")
            return 1
        if expected not in negative.stderr:
            print("FAIL elf-symbol-alignment control: wrong diagnostic")
            print(negative.stdout + negative.stderr, end="")
            return 1

    report_pass(
        "elf-symbol-alignment controls",
        "positive and negative fixtures",
        cases=CASES.ran)
    return 0


if __name__ == "__main__":
    sys.exit(main())
