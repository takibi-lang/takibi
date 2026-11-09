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
from source_scan import code_only, py_code_only
from layout_text import layout_count

SECONDARY = pathlib.Path("kernel/arch/arm64/kernel/secondary.tkb")
ATOMIC = pathlib.Path("kernel/lib/atomic_word.tkb")
READER = pathlib.Path("scripts/gdb_tick_count.py")

DECLARATION = re.compile(
    r"^\s*(?:private\s+)?let\s+mut\s+secondary_tick_count\s*:\s*"
    r"\[\s*AtomicWord\s*;\s*KERNEL_MAX_CORES\s*\]\s*;", re.M)
ATOMIC_WORD = re.compile(r"^\s*struct\s+(?:no_copy\s+)?AtomicWord\s*\{([^}]*)\}", re.M)
SINGLE_USIZE = re.compile(r"^\s*(?:private\s+)?\w+\s*:\s*usize\s*;?\s*$")
STRIDE = re.compile(r"&secondary_tick_count\s*\+\s*\{8\s*\*\s*core\}")


# The same shared secondary source owns the scheduler's contiguous prefix.
# These bounded source premises supplement AtomicWord typing and the compiled
# caller table. They do not prove hardware CPU_ON completion or CPU identity.
ONLINE_CLEAR = """fn kernel_secondary_boot_state_clear() !{unsafe} {
    process_image_pool_init_before_secondary();
    address_space_backing_pool_init_before_secondary();
    for core: usize in 0..<KERNEL_MAX_CORES {
        atomic_word_store(&kernel_secondary_boot_state[core], 0);
    }
    atomic_word_store(&kernel_online_cores, 1);
}"""
ONLINE_NOTE = """fn kernel_online_core_note_cpu_on(
        core: {0..<KERNEL_MAX_CORES as usize}, status: usize) {
    let online: usize = atomic_word_load(&kernel_online_cores);
    if (status == 0 && core == online && online < KERNEL_MAX_CORES) {
        atomic_word_store(&kernel_online_cores, online + 1);
    }
}"""
ONLINE_COUNT = """fn kernel_online_core_count() -> usize {
    let online: usize = atomic_word_load(&kernel_online_cores);
    if (online >= 1 && online <= KERNEL_MAX_CORES) {
        return online;
    }
    return 1;
}"""
ONLINE_CALLERS = {
    "kernel_secondary_boot_state_clear": "kernel/init/secondary_boot.tkb:kernel_secondary_boot_report",
    "kernel_online_core_note_cpu_on": "kernel/init/secondary_boot.tkb:kernel_secondary_boot_attempt",
    "kernel_secondary_boot_attempt": "kernel/init/secondary_boot.tkb:kernel_secondary_boot_report",
    "kernel_secondary_boot_report": "kernel/platform/qemu/init.tkb:main,kernel/platform/rpi5/init.tkb:main",
}


def online_problems(source, callers):
    failures = []
    for label, shape in (
            ("private atomic prefix", "private let mut kernel_online_cores: AtomicWord;"),
            ("CPU_ON prefix predicate", ONLINE_NOTE),
            ("bounded read and fallback", ONLINE_COUNT),
            ("boot initialization", ONLINE_CLEAR)):
        if layout_count(source, shape) != 1:
            failures.append(f"online prefix: {label} changed")
    # Declaration, clear, note load/store and count load: no alias or extra
    # store, including a store added elsewhere in this private global's file.
    if len(re.findall(r"\bkernel_online_cores\b", source)) != 5:
        failures.append("online prefix: expected exactly five global occurrences")
    rows = [line.split("\t") for line in callers.splitlines()
            if line.strip() and not line.startswith("#")]
    for helper, allowed in ONLINE_CALLERS.items():
        matching = [row for row in rows if len(row) == 5 and row[1] == helper]
        if len(matching) != 1 or matching[0][2] != allowed:
            failures.append(f"online prefix: closed boot caller row for {helper} changed")
    return failures


def main() -> int:
    failures = online_problems(code_only(SECONDARY.read_text()),
                               pathlib.Path("scripts/allowed_callers.tsv").read_text())
    facts = 0
    if not DECLARATION.search(code_only(SECONDARY.read_text(encoding="utf-8"))):
        failures.append(f"{SECONDARY}: secondary_tick_count is no longer "
                        "[AtomicWord; KERNEL_MAX_CORES]")
    else:
        facts += 1
    match = ATOMIC_WORD.search(code_only(ATOMIC.read_text(encoding="utf-8")))
    if not match or not SINGLE_USIZE.match(match.group(1).strip()):
        failures.append(f"{ATOMIC}: AtomicWord is no longer one usize field")
    else:
        facts += 1
    if not STRIDE.search(py_code_only(READER.read_text(encoding="utf-8"))):
        failures.append(f"{READER}: the tick read no longer steps 8 bytes per core")
    else:
        facts += 1
    if failures:
        for line in failures:
            print(f"ERROR\tsecondary-tick-count-layout: {line}; the gdb "
                  "progress bounds (#865, #867) would read the wrong word")
        print(f"FAIL secondary-tick-count-layout: {len(failures)} mismatch(es)")
        return 1
    report_pass("secondary-tick-count-layout",
                "secondary_tick_count is one 8-byte AtomicWord per core, as "
                "the gdb tick read assumes; online prefix atomic accesses, predicate, "
                "fallback and closed boot caller rows hold", facts=facts)
    return 0


if __name__ == "__main__":
    sys.exit(main())
