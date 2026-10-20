#!/usr/bin/env python3
"""The gdb tick read and the kernel agree on secondary_tick_count's layout.

GitHub issues #865 and #867: gdb checks bound their stages by the ticks each
core took, read from the kernel's secondary_tick_count between slices as
`*(unsigned long *)(&secondary_tick_count + 8 * core)`
(scripts/gdb_tick_count.py). That arithmetic holds only while the array is
one AtomicWord per core, indexed by core, and an AtomicWord is exactly one
usize (8 bytes on arm64). A change to either would make every progress
bound read the wrong word -- a stall could look like progress -- with no
error anywhere. So this checks the three facts the read relies on:

  - kernel/arch/arm64/kernel/secondary.tkb declares
    `secondary_tick_count: [AtomicWord; KERNEL_MAX_CORES]`;
  - kernel/lib/atomic_word.tkb's AtomicWord has exactly one field, a usize;
  - scripts/gdb_tick_count.py reads `8 * core` from that symbol.

Exit code only (0 = pass, 1 = fail).
"""

import pathlib
import re
import sys

from pass_line import report_pass

SECONDARY = pathlib.Path("kernel/arch/arm64/kernel/secondary.tkb")
ATOMIC = pathlib.Path("kernel/lib/atomic_word.tkb")
READER = pathlib.Path("scripts/gdb_tick_count.py")

DECLARATION = re.compile(
    r"^\s*(?:private\s+)?let\s+mut\s+secondary_tick_count\s*:\s*"
    r"\[\s*AtomicWord\s*;\s*KERNEL_MAX_CORES\s*\]\s*;", re.M)
ATOMIC_WORD = re.compile(r"^\s*struct\s+(?:no_copy\s+)?AtomicWord\s*\{([^}]*)\}", re.M)
SINGLE_USIZE = re.compile(r"^\s*(?:private\s+)?\w+\s*:\s*usize\s*;?\s*$")
STRIDE = re.compile(r"&secondary_tick_count\s*\+\s*\{8\s*\*\s*core\}")


def code(text: str) -> str:
    return "\n".join(line.split("//", 1)[0] for line in text.splitlines())


def main() -> int:
    failures = []
    if not DECLARATION.search(code(SECONDARY.read_text(encoding="utf-8"))):
        failures.append(f"{SECONDARY}: secondary_tick_count is no longer "
                        "[AtomicWord; KERNEL_MAX_CORES]")
    match = ATOMIC_WORD.search(code(ATOMIC.read_text(encoding="utf-8")))
    if not match or not SINGLE_USIZE.match(match.group(1).strip()):
        failures.append(f"{ATOMIC}: AtomicWord is no longer one usize field")
    reader = "\n".join(line for line in READER.read_text(encoding="utf-8").splitlines()
                       if not line.lstrip().startswith("#"))
    if not STRIDE.search(reader):
        failures.append(f"{READER}: the tick read no longer steps 8 bytes per core")
    if failures:
        for line in failures:
            print(f"ERROR\tsecondary-tick-count-layout: {line}; the gdb "
                  "progress bounds (#865, #867) would read the wrong word")
        print(f"FAIL secondary-tick-count-layout: {len(failures)} mismatch(es)")
        return 1
    report_pass("secondary-tick-count-layout",
                "secondary_tick_count is one 8-byte AtomicWord per core, as "
                "the gdb tick read assumes", files=3)
    return 0


if __name__ == "__main__":
    sys.exit(main())
