#!/usr/bin/env python3
# Static, hardware-free regression guard for a real bug found on real RPi5
# hardware during GitHub issue #228: kernel/arch/arm64/kernel/
# user_payload.tkb is compiled standalone and linked (with user_payload_
# asm.S) into a flat, position-independent blob via user_payload.ld, then
# objcopied to raw bytes and embedded into the kernel image with
# embed_file. That whole blob -- code AND any top-level mutable globals
# alike -- is mapped as a single read+execute-only page at runtime (see
# HISTORY.md's 2026-08-07 issue #228 entry): a write into a global lands
# in kernel/mm/user_memory.tkb's user_range_check(), which correctly and
# safely returns UserRangeResult::Fault (surfaced to the payload as a
# clean -EFAULT, no crash) -- but since this fixture's own convention on
# any check failure is to spin forever silently (matching the original
# hand-written asm's `.Luser_fail: b .Luser_fail`), the result looks like
# an unexplained hang, not an actionable error, and took real hardware
# A/B testing to diagnose the first time.
#
# Any scratch buffer this payload writes into at runtime MUST be a plain
# local (stack) variable instead, matching the original hand-written
# asm's own use of `sub sp, sp, #N` for exactly this reason -- the stack
# page is mapped separately as rw+xn. This script inspects the linked
# user_payload.elf's section headers and fails the build if a `.data` or
# `.bss` section with nonzero size exists, which is exactly what a
# top-level mutable global compiles into. It cannot tell WHY a global
# exists (a constant that happens to need `let mut` for some other
# reason would also be flagged), but that is a feature here: nothing in
# this specific standalone-flat-binary payload should ever need one.
#
# Exit code only (0 = pass, 1 = fail); intended to run as part of the
# Makefile's $(KERNEL_USER_PAYLOAD_BIN) rule, right after user_payload.elf
# is linked and before it is objcopied into the embedded binary.

import re
import subprocess
import sys

LLVM_READELF = "llvm-readelf-19"

# Matches e.g. "  [ 3] .bss              NOBITS          ... 000004 00  WA  0   0  8"
SECTION_RE = re.compile(
    r"^\s*\[\s*\d+\]\s+(\S+)\s+\S+\s+[0-9a-f]+\s+[0-9a-f]+\s+([0-9a-f]+)\s"
)

FLAGGED_PREFIXES = (".data", ".bss")


def section_sizes(elf_path):
    out = subprocess.run(
        [LLVM_READELF, "-S", elf_path],
        check=True, capture_output=True, text=True,
    ).stdout
    sizes = []
    for line in out.splitlines():
        m = SECTION_RE.match(line)
        if not m:
            continue
        name, size_hex = m.group(1), m.group(2)
        sizes.append((name, int(size_hex, 16)))
    return sizes


def check_no_rw_globals(elf_path):
    failures = []
    for name, size in section_sizes(elf_path):
        if name.startswith(FLAGGED_PREFIXES) and size > 0:
            failures.append(
                "issue #228 regression: %s has a nonzero-size '%s' section "
                "(%d bytes) -- this payload is loaded as a single "
                "read+execute-only page at runtime, so a top-level mutable "
                "global here (which is what a '.data'/'.bss' section with "
                "content means) will silently fail every runtime write into "
                "it. Move it to a local (stack) variable inside the "
                "function that uses it instead (see HISTORY.md's "
                "2026-08-07 issue #228 entry)."
                % (elf_path, name, size)
            )
    return failures


def main():
    if len(sys.argv) != 2:
        print("usage: check_user_payload_no_rw_globals.py <user_payload.elf>",
              file=sys.stderr)
        return 1
    failures = check_no_rw_globals(sys.argv[1])
    if failures:
        for f in failures:
            print("FAIL user_payload/no-rw-globals: %s" % f, file=sys.stderr)
        return 1
    print("PASS user_payload/no-rw-globals: no writable globals in the "
          "flat EL0 payload blob")
    return 0


if __name__ == "__main__":
    sys.exit(main())
