#!/usr/bin/env python3
"""Refuse a kernel function whose stack frame exceeds a ceiling (GitHub issue #1081).

Every kernel stack is 16 KiB (the boot stack, every process stack). The
first #1081 design carried 520 more bytes in an ELF load plan that is
passed by value, and each copy is a stack temporary: frames along the exec
path grew from under 1 KiB to 3.6-6.5 KiB, and the boot stack overflowed in
the debug images. No check before QEMU saw it.

This reads the prologue of every function in an aarch64 object or ELF
(`stp x29, x30, [sp, #-N]!` and `sub sp, sp, #N`) and refuses a frame above
CEILING bytes, unless BUDGET names the function: a listed function may not
exceed its recorded frame, and an entry whose function is gone, or is now
below the ceiling, is refused as stale. It bounds single frames, not paths;
a whole-call-graph stack bound is the stronger, unfiled compiler-side rung.

Usage: buildcheck_frame_size.py OBJECT...
"""
import re
import subprocess
import sys

from pass_line import report_pass

CEILING = 2048

# Functions above the ceiling when it was introduced, with their frame in
# the largest image measured (the qemu debug image) and why each is
# accepted. Lower an entry when its frame shrinks; delete it at or under
# the ceiling.
BUDGET = {
    # Boot-only scheduler probe, run once on the boot stack early in boot.
    "kernel_process_scheduler_probe": 3216,
    # ext2 write path; runs on a process stack with a shallow caller chain.
    "ext2_update_regular_file": 2544,
}

PROLOGUE_LINES = 12


def frames(text):
    """Map function name -> frame bytes from `llvm-objdump -d` output."""
    result = {}
    current = None
    size = 0
    seen = 0
    for line in text.splitlines():
        m = re.match(r"^[0-9a-f]+ <(.+)>:", line)
        if m:
            if current is not None:
                result[current] = max(result.get(current, 0), size)
            current, size, seen = m.group(1), 0, 0
            continue
        if current is None or seen >= PROLOGUE_LINES:
            continue
        seen += 1
        m = re.search(r"stp\s+x29, x30, \[sp, #-(\d+)\]!", line)
        if m:
            size += int(m.group(1))
        m = re.search(r"sub\s+sp, sp, #(0x[0-9a-f]+|\d+)(, lsl #12)?", line)
        if m:
            value = int(m.group(1), 0)
            if m.group(2):
                value <<= 12
            size += value
    if current is not None:
        result[current] = max(result.get(current, 0), size)
    return result


def problems(measured, budget=BUDGET, ceiling=CEILING, check_stale=True):
    out = []
    for name, size in sorted(measured.items()):
        limit = budget.get(name, ceiling)
        if size > limit:
            if name in budget:
                out.append(f"{name}: frame {size} B exceeds its recorded budget "
                           f"{limit} B")
            else:
                out.append(f"{name}: frame {size} B exceeds the {ceiling} B ceiling "
                           f"(a large value passed or held by value? see #1081)")
    if check_stale:
        for name, limit in sorted(budget.items()):
            if name not in measured:
                out.append(f"{name}: budget entry for a function not in the image")
            elif measured[name] <= ceiling:
                out.append(f"{name}: frame {measured[name]} B is within the ceiling; "
                           f"delete its budget entry")
    return out


def objdump(path):
    return subprocess.run(["llvm-objdump-19", "-d", "--no-show-raw-insn", path],
                          check=True, capture_output=True, text=True).stdout


def main(argv):
    if len(argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2
    failed = False
    for path in argv[1:]:
        measured = frames(objdump(path))
        if not measured:
            print(f"FAIL frame-size: {path}: no functions found", file=sys.stderr)
            failed = True
            continue
        # Stale entries are judged against the image their function is in;
        # a target that lacks one (another platform) does not make it stale.
        found = problems(measured, check_stale=False)
        found += [p for p in problems({k: v for k, v in measured.items()
                                       if k in BUDGET})
                  if "not in the image" not in p]
        found = sorted(set(found))
        if found:
            failed = True
            for p in found:
                print(f"FAIL frame-size: {path}: {p}", file=sys.stderr)
        else:
            largest = max(measured.items(), key=lambda kv: kv[1])
            report_pass("frame-size",
                        f"{path}: {len(measured)} functions, largest "
                        f"{largest[0]} {largest[1]} B, ceiling {CEILING} B, "
                        f"{len(BUDGET)} budgeted",
                        functions=len(measured))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
