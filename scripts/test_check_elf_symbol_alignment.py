#!/usr/bin/env python3
"""Positive and faithful negative controls for the ELF alignment guard."""

from pathlib import Path
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parent.parent
CHECKER = ROOT / "scripts" / "check_elf_symbol_alignment.py"
LLVM_MC = "llvm-mc-19"


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

        positive = subprocess.run(
            [sys.executable, str(CHECKER), str(obj), "aligned_pool", "16"],
            capture_output=True,
            text=True,
        )
        if positive.returncode != 0:
            print("FAIL elf-symbol-alignment control: aligned fixture failed")
            print(positive.stdout + positive.stderr, end="")
            return 1

        negative = subprocess.run(
            [sys.executable, str(CHECKER), str(obj), "misaligned_pool", "16"],
            capture_output=True,
            text=True,
        )
        expected = "misaligned_pool at 0x8 is not 16-byte aligned"
        if negative.returncode == 0:
            print("FAIL elf-symbol-alignment control: bad fixture succeeded")
            return 1
        if expected not in negative.stderr:
            print("FAIL elf-symbol-alignment control: wrong diagnostic")
            print(negative.stdout + negative.stderr, end="")
            return 1

    print("PASS elf-symbol-alignment controls: positive and negative fixtures")
    return 0


if __name__ == "__main__":
    sys.exit(main())
