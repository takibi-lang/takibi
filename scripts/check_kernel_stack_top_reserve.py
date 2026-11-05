#!/usr/bin/env python3
"""Every kernel stack keeps its preempt word in the last 16 bytes of its run.

GitHub issue #638 (maintainer, option A): a preempt count kept per stack
lives at the top of each stack's 0x8000-aligned run, where sp | 0x7fff finds
it from any address on that stack, and the poison scan of the half below the
stack keeps its whole range. That holds only while every stack's top, where
SP stands when the stack is empty, is the run's end less 16 and no frame is
placed above it:

- in both linker scripts, each of boot_stack_top, secondary_stack_top,
  overflow_stack_top and irq_stack_top is defined as `. - 16`, directly
  after the `. += 0x4000` that ends its run;
- kernel/kernel/process.tkb defines KERNEL_STACK_TOP_RESERVE as 16, places
  a process's first saved SP and its first frames below it, and zeroes the
  word when it fills a fresh stack with poison;
- both entry files zero the word of each stack a core stands on before
  anything runs on it.

Reads tracked files only. A self-test plants each break in a copy of the
text and expects it to be refused.
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LINKERS = ("kernel/arch/arm64/boot/link.ld",
           "kernel/arch/arm64/boot/link_qemu.ld")
ENTRIES = ("kernel/arch/arm64/boot/entry.S",
           "kernel/arch/arm64/boot/entry_qemu.S")
PROCESS = "kernel/kernel/process.tkb"
TOPS = ("boot_stack_top", "secondary_stack_top", "overflow_stack_top",
        "irq_stack_top")
RESERVE = 16


def linker_errors(name, text):
    errors = []
    for top in TOPS:
        found = re.search(r"\.\s*\+=\s*0x4000;\s*(?:/\*.*?\*/\s*)?"
                          + top + r"\s*=\s*\.\s*-\s*(\d+)\s*;", text, re.S)
        if found is None or int(found.group(1)) != RESERVE:
            errors.append(f"{name}: {top} is not the end of its run less "
                          f"{RESERVE}")
    return errors


def process_errors(text):
    errors = []
    if not re.search(r"const KERNEL_STACK_TOP_RESERVE: usize = %d;" % RESERVE,
                     text):
        errors.append(f"{PROCESS}: KERNEL_STACK_TOP_RESERVE is not {RESERVE}")
    # A first frame or saved SP at the run's very end would sit on the word.
    if re.search(r"KERNEL_PROCESS_STACK_SIZE\s*-\s*EXC_CONTEXT_SIZE", text):
        errors.append(f"{PROCESS}: a frame is placed at the stack's end, over "
                      "the preempt word")
    if re.search(r"saved_sp\s*=\s*\n?\s*bottom \+ KERNEL_PROCESS_STACK_SIZE;",
                 text):
        errors.append(f"{PROCESS}: a first saved SP is the stack's end, so "
                      "the first push would overwrite the preempt word")
    if "KERNEL_STACK_RUN_BYTES - KERNEL_STACK_TOP_RESERVE" not in text:
        errors.append(f"{PROCESS}: a fresh stack's preempt word is not zeroed "
                      "after the poison fill")
    return errors


def entry_errors(name, text):
    errors = []
    if not re.search(r"add\s+x0, x0, :lo12:boot_stack_top\n(?:\s*//.*\n)*"
                     r"\s*str\s+xzr, \[x0\]", text):
        errors.append(f"{name}: the boot stack's preempt word is not zeroed")
    for top in ("overflow_stack_top", "irq_stack_top"):
        if text.count(f"add     x9, x9, :lo12:{top}\n    str     xzr, [x9") != 2:
            errors.append(f"{name}: {top}'s preempt word is not zeroed on "
                          "every core")
    return errors


def check(files):
    errors = []
    for name in LINKERS:
        errors += linker_errors(name, files[name])
    errors += process_errors(files[PROCESS])
    for name in ENTRIES:
        errors += entry_errors(name, files[name])
    return errors


def self_test(files):
    plants = [
        (LINKERS[0], "boot_stack_top = . - 16;", "boot_stack_top = .;"),
        (LINKERS[1], "irq_stack_top = . - 16;", "irq_stack_top = . - 8;"),
        (PROCESS, "KERNEL_PROCESS_STACK_SIZE - KERNEL_STACK_TOP_RESERVE - "
                  "EXC_CONTEXT_SIZE",
         "KERNEL_PROCESS_STACK_SIZE - EXC_CONTEXT_SIZE"),
        (ENTRIES[0], ":lo12:irq_stack_top\n    str     xzr, [x9, x0]",
         ":lo12:irq_stack_top\n    nop"),
    ]
    for name, before, after in plants:
        if before not in files[name]:
            return f"control anchor missing in {name}: {before!r}"
        copy = dict(files)
        copy[name] = files[name].replace(before, after, 1)
        if not check(copy):
            return f"a planted break in {name} was accepted"
    return None


def main():
    files = {name: (ROOT / name).read_text()
             for name in LINKERS + ENTRIES + (PROCESS,)}
    errors = check(files)
    for error in errors:
        print(f"ERROR kernel-stack-top-reserve: {error}")
    if errors:
        print("FAIL kernel-stack-top-reserve: a stack's top no longer "
              "leaves room for its preempt word")
        return 1
    failure = self_test(files)
    if failure:
        print(f"FAIL kernel-stack-top-reserve controls: {failure}")
        return 1
    print("PASS kernel-stack-top-reserve: 4 stack tops in 2 linker scripts, "
          "the process stack and 2 entry files leave the last 16 bytes of "
          "each run to its preempt word; 4 planted breaks refused")
    return 0


if __name__ == "__main__":
    sys.exit(main())
