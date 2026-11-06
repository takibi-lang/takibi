#!/usr/bin/env python3
"""Every kernel stack keeps its preempt word in the last 16 bytes of its run.

GitHub issue #638 (maintainer, option A): a preempt count kept per stack
lives at the top of each stack's 0x8000-aligned run, where sp | 0x7fff finds
it from any address on that stack, and the poison scan of the half below the
stack keeps its whole range. That holds only while every stack's top, where
SP stands when the stack is empty, is the run's end less 16 and no frame is
placed above it:

- in both linker scripts, each of boot_stack_top, secondary_stack_top,
  overflow_stack_top and irq_stack_top is defined once, as `. - 16`, at
  the end of its run;
- kernel/kernel/process.tkb defines KERNEL_STACK_TOP_RESERVE as 16, places
  a process's first saved SP and its first frames below it, and zeroes the
  word when it fills a fresh stack with poison;
- both entry files zero the word of each stack a core stands on before
  anything runs on it;
- every idle entry user_entry.S branches to (kernel_idle_*_reenter in
  secondary.tkb) resets the idle stack's word before the loop: the idle loop's own
  start leaves a span raised there when it resumes a process (a tick entry
  without the reset stopped the stage 8 land, #638);
- every IRQ exception_entry runs its handler on irq_stack_top, and the
  compiler's dispatch-stack sequence zeroes that stack's word on an entry
  that is not nested: a tick that switched leaves its span raised there
  (#1382).

Reads tracked files only. A self-test plants each break in a copy of the
text and expects it to be refused.
"""

import re
import sys
from pathlib import Path

from pass_line import report_pass

ROOT = Path(__file__).resolve().parent.parent
LINKERS = ("kernel/arch/arm64/boot/link.ld",
           "kernel/arch/arm64/boot/link_qemu.ld")
ENTRIES = ("kernel/arch/arm64/boot/entry.S",
           "kernel/arch/arm64/boot/entry_qemu.S")
PROCESS = "kernel/kernel/process.tkb"
USER_ENTRY = "kernel/arch/arm64/kernel/user_entry.S"
SECONDARY = "kernel/arch/arm64/kernel/secondary.tkb"
EXCEPTION_FRAME = "kernel/arch/arm64/kernel/exception_frame.tkb"
CODEGEN = "lib/llvm_gen.ml"
IRQ_RESET = '\\tmov\\tsp, x1\\n\\tstr\\txzr, [x1]\\n.L%s_nested:'
TOPS = ("boot_stack_top", "secondary_stack_top", "overflow_stack_top",
        "irq_stack_top")
RESERVE = 16


def linker_errors(name, text):
    errors = []
    for top in TOPS:
        found = re.findall(r"\b" + top + r"\s*=\s*\.\s*-\s*(\d+)\s*;", text)
        if len(found) != 1 or int(found[0]) != RESERVE:
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
    if text.count("    str     xzr, [x0]\n") != 2:
        errors.append(f"{name}: the boot and secondary stacks' preempt "
                      "words are not both zeroed")
    for top in ("overflow_stack_top", "irq_stack_top"):
        if text.count(f"add     x9, x9, :lo12:{top}\n    str     xzr, [x9") != 2:
            errors.append(f"{name}: {top}'s preempt word is not zeroed on "
                          "every core")
    return errors


def idle_entry_errors(entry_text, secondary_text):
    errors = []
    names = sorted(set(re.findall(r"adr\s+x5,\s+(kernel_idle_\w+_reenter)",
                                  entry_text)))
    if not names:
        errors.append(f"{USER_ENTRY}: no idle entry found")
    for name in names:
        body = re.search(r"\nfn " + name + r"\(\) \{\n(.*?)\n\}", secondary_text,
                         re.S)
        if body is None:
            errors.append(f"{SECONDARY}: {name} is not defined")
            continue
        first = [l.strip() for l in body.group(1).split("\n")]
        if ("preempt_count_after_switch();" not in first or
                "kernel_idle_loop();" not in first or
                first.index("preempt_count_after_switch();") >
                first.index("kernel_idle_loop();")):
            errors.append(f"{SECONDARY}: {name} does not reset the idle "
                          "stack's preempt word before the idle loop")
    return errors


def irq_entry_errors(frame_text, codegen_text):
    errors = []
    entries = re.findall(r"exception_entry (\w+) \{(.*?)\n\}", frame_text, re.S)
    irq = [(n, b) for n, b in entries if re.search(r"dispatch:\s*\w*irq_dispatch", b)]
    if not irq:
        errors.append(f"{EXCEPTION_FRAME}: no IRQ exception_entry found")
    for name, body in irq:
        if not re.search(r"\n\s*dispatch_stack:\s*irq_stack_top;", body):
            errors.append(f"{EXCEPTION_FRAME}: {name} does not run its handler "
                          "on irq_stack_top, whose preempt word the entry resets")
    if IRQ_RESET not in codegen_text:
        errors.append(f"{CODEGEN}: the dispatch-stack entry no longer zeroes "
                      "the stack's preempt word when it is not nested")
    return errors


def check(files):
    errors = idle_entry_errors(files[USER_ENTRY], files[SECONDARY])
    errors += irq_entry_errors(files[EXCEPTION_FRAME], files[CODEGEN])
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
        (ENTRIES[1], "    str     xzr, [x0]\n", ""),
        (SECONDARY, "preempt_count_after_switch();", ""),
        (EXCEPTION_FRAME, "dispatch_stack: irq_stack_top;", ""),
        (CODEGEN, IRQ_RESET, IRQ_RESET.replace("\\tstr\\txzr, [x1]\\n", "")),
    ]
    refused = 0
    for name, before, after in plants:
        if before not in files[name]:
            return f"control anchor missing in {name}: {before!r}", refused
        copy = dict(files)
        copy[name] = files[name].replace(before, after, 1)
        if not check(copy):
            return f"a planted break in {name} was accepted", refused
        refused += 1
    return None, refused


def main():
    files = {name: (ROOT / name).read_text()
             for name in LINKERS + ENTRIES + (PROCESS, USER_ENTRY, SECONDARY,
                                               EXCEPTION_FRAME, CODEGEN)}
    errors = check(files)
    for error in errors:
        print(f"ERROR kernel-stack-top-reserve: {error}")
    if errors:
        print("FAIL kernel-stack-top-reserve: a stack's top no longer "
              "leaves room for its preempt word")
        return 1
    failure, refused = self_test(files)
    if failure:
        print(f"FAIL kernel-stack-top-reserve controls: {failure}")
        return 1
    report_pass("kernel-stack-top-reserve",
                "every stack top in the linker scripts, the process stack "
                "and the entry files leaves the last 16 bytes of its run to "
                "its preempt word; planted breaks refused",
                stack_tops=len(TOPS) * len(LINKERS),
                files=len(files), controls=refused)
    return 0


if __name__ == "__main__":
    sys.exit(main())
