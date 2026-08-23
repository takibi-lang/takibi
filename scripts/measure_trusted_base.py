#!/usr/bin/env python3
# GitHub issue #238: repeatable, quantitative measurement of the trusted
# base #236 documents qualitatively. Run from the repo root after
# `make kernelbuild` (the two --forbid-trap depfiles this script reads are
# a build product, not checked in -- see kernel/build/{rpi5,qemu}/main.o.d).
#
# Counting rules (kept explicit here since #238's acceptance criteria
# require documented, stable rules, not just numbers):
#
# - "unsafe block" = a literal `unsafe {` occurrence in kernel/**/*.tkb.
#   Every unsafe construct in this language is block-form (`unsafe { ... }`,
#   issue #315) -- there is no longer a bare `unsafe expr` spelling, so this
#   substring count cannot over- or under-count relative to the grammar.
#   The `!{unsafe}` function-effect annotation (a different thing: marks a
#   function as calling into unsafe code, not a use site itself) does not
#   match this pattern, so it is correctly excluded.
# - "handwritten assembly" = total lines of kernel/**/*.S. These are
#   hand-written source, never generated (generated fragments in this repo
#   are .inc files, `.include`d from the containing .S, not standalone .S
#   files).
# - "kernel Takibi code under --forbid-trap" = the union of every .tkb file
#   listed as a prerequisite in kernel/build/rpi5/main.o.d and
#   kernel/build/qemu/main.o.d (the exact file set the last real
#   `--forbid-trap` build actually compiled, via --emit-depfile -- not a
#   guess from directory scanning, which could include a file that is not
#   actually reachable from either kernel entry point).
# - "raw pointer cast" = a literal `as *` occurrence in kernel/**/*.tkb.
#   The TOTAL is kept as-is so every figure already recorded (HISTORY.md
#   quotes these) stays comparable; issue #394 split it three ways because
#   the total moved by two dozen when issue #392 added diagnostic messages,
#   and a metric that moves for reasons unrelated to trust stops being
#   read. The split is by cast TARGET where the language distinguishes one,
#   not by the operand:
#     * device registers -- `as *io T`. The MMIO boundary. Trusted, but
#       what is trusted is a datasheet address, not an argument about
#       aliasing with kernel memory; issue #218 already made constructing
#       one a hard unsafe error. Computed operands are normal here
#       (`(base + offset) as *io i32`), so the target is the only reliable
#       discriminator.
#     * string constants -- an operand ending in `"`. Not a pointer
#       computation at all: static storage, immortal, no aliasing and no
#       alignment question. `as *u8` is simply how this language spells a
#       string constant's address.
#     * memory -- everything else, and the only bucket where a wrong cast
#       can alias or corrupt a kernel data structure. This is the number to
#       watch.
#   None of the three is "safe" unconditionally; they are three different
#   things to be trusted, and lumping them hid which one was growing.
# - Supplementary metrics (raw pointer casts, #218 audit warnings) are
#   informational, not part of #238's required three.

import re
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
KERNEL_DIR = REPO_ROOT / "kernel"
TAKIBI = REPO_ROOT / "_build/default/bin/main.exe"


def read_depfile_sources(depfile: Path) -> list[str]:
    if not depfile.exists():
        sys.exit(
            f"error: {depfile} does not exist -- run `make kernelbuild` first "
            "so this script can read the exact --forbid-trap file set it "
            "produced (see this script's own top-of-file comment)"
        )
    text = depfile.read_text().replace("\\\n", " ")
    # Depfile format: "target: prereq1 prereq2 ...". Drop the target itself
    # (part before the first ':') and keep only .tkb sources -- other
    # prerequisites (the compiler binary itself, if ever added) are not
    # kernel Takibi source and would corrupt the line count.
    _, _, prereqs = text.partition(":")
    return sorted(set(
        p for p in prereqs.split() if p.endswith(".tkb")
    ))


def count_lines(paths: list[str]) -> int:
    total = 0
    for p in paths:
        total += len((REPO_ROOT / p).read_text().splitlines())
    return total


def count_unsafe_blocks(tkb_files: list[Path]) -> int:
    total = 0
    for f in tkb_files:
        total += len(re.findall(r"unsafe\s*\{", f.read_text()))
    return total


def classify_raw_pointer_casts(tkb_files: list[Path]) -> dict[str, int]:
    """Split `as *T` by what is being trusted, keeping the total intact.

    The three buckets are decided by the CAST TARGET where possible, not by
    the operand, because the target is what the language itself
    distinguishes.
    """
    counts = {"total": 0, "device": 0, "string": 0, "memory": 0}
    for f in tkb_files:
        text = f.read_text()
        for m in re.finditer(r"\bas\s+\*", text):
            counts["total"] += 1
            if text[m.end():m.end() + 3] == "io ":
                counts["device"] += 1
            elif text[:m.start()].rstrip().endswith('"'):
                counts["string"] += 1
            else:
                counts["memory"] += 1
    return counts


def count_issue_218_warnings(qemu_sources: list[str]) -> int | None:
    if not TAKIBI.exists():
        return None
    result = subprocess.run(
        [str(TAKIBI), *qemu_sources,
         "--target", "aarch64-none-elf", "--cpu", "cortex-a53",
         "-o", "/dev/null"],
        cwd=REPO_ROOT, capture_output=True, text=True,
    )
    return result.stderr.count("issue #218")


def main() -> None:
    rpi5_sources = read_depfile_sources(KERNEL_DIR / "build/rpi5/main.o.d")
    qemu_sources = read_depfile_sources(KERNEL_DIR / "build/qemu/main.o.d")
    forbid_trap_sources = sorted(set(rpi5_sources) | set(qemu_sources))

    all_tkb_files = sorted(KERNEL_DIR.rglob("*.tkb"))
    all_asm_files = sorted(KERNEL_DIR.rglob("*.S"))

    unsafe_blocks = count_unsafe_blocks(all_tkb_files)
    asm_lines = count_lines([str(p.relative_to(REPO_ROOT)) for p in all_asm_files])
    forbid_trap_lines = count_lines(forbid_trap_sources)
    raw_ptr_casts = classify_raw_pointer_casts(all_tkb_files)
    issue_218_warnings = count_issue_218_warnings(qemu_sources)

    print("Takibi trusted-base metrics")
    print("============================")
    print(f"unsafe blocks (kernel/**/*.tkb)              : {unsafe_blocks}")
    print(f"handwritten assembly lines (kernel/**/*.S)    : {asm_lines}")
    print(f"kernel .tkb lines under --forbid-trap         : {forbid_trap_lines}")
    print(f"  ({len(forbid_trap_sources)} files, union of RPi5+QEMU depfiles)")
    print()
    print("Supplementary")
    print("-------------")
    print(f"raw pointer casts, `as *T` (kernel/**/*.tkb)  : {raw_ptr_casts['total']}")
    print(f"  of which memory (may alias kernel data)     : {raw_ptr_casts['memory']}")
    print(f"  device registers (`as *io T`)               : {raw_ptr_casts['device']}")
    print(f"  string constants (`\"...\" as *u8`)           : {raw_ptr_casts['string']}")
    if issue_218_warnings is None:
        print("issue #218 audit warnings (QEMU target)       : (run `dune build` first)")
    else:
        print(f"issue #218 audit warnings (QEMU target)       : {issue_218_warnings}")


if __name__ == "__main__":
    main()
