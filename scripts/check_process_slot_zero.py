#!/usr/bin/env python3
"""No process is slot 0 (GitHub issue #831).

WHY THIS EXISTS. Until #831 slot value 0 named a static bootstrap record:
the boot fixtures stood on it, PID 1 was it, and a dozen places in the
scheduler, the stack-run accounting and the address-space code answered
"is this slot 0" before asking anything else. Each of those branches was a
special case nobody re-asked when the code around it changed, and the work
of #831 met two of them as defects: "the parent is PID 1" was spelled "the
parent is slot 0", which silently refused every init child once PID 1 moved
to the pool, and a root read back as slot 0 was looked up as a process
record, which counted as a missing record. Since #831 every process record,
the boot thread's and PID 1's included, is a pool slot, and 0 names none.

THE RULE.
1. The static bootstrap's names do not come back anywhere in kernel/.
2. In the functions that place a process, account its kernel stack, reach
   its record or select its root (PLACEMENT, in kernel/kernel/process.tkb),
   no comparison of a slot with 0 and no slot-is-boot predicate. Root 0, the
   kernel's own address space, is answered by one function each in
   address_space.tkb and process.tkb (ROOT_ZERO), which are not checked.
3. No per-process call in kernel/ names process slot 0 as a literal.

WHAT IT IS NOT. Lexical: a 0 passed through a variable is not seen. The
missing-record counter (process table: records MISSING) is the runtime
backstop for that.

WHAT THE TYPES TOOK OVER (GitHub issue #858). The placement, record-access
and root-selection APIs of kernel/kernel/process.tkb take a ProcessSlot,
minted only by that file, and roots are a separate RootSlot
(kernel/mm/address_space.tkb), so a literal 0 or a root slot where a process
is meant no longer type-checks there; those calls left PROCESS_FIRST and
PROCESS_SECOND. What remains here is what the types do not see: the
per-process tables that key their indexed evidence by the slot WORD (the
fd-context table's unified_* calls and scheduled_process_set_image_record),
the bootstrap names of rule 1, and rule 2's slot-0 branch on a slot WORD
(usize). A ProcessSlot compared with 0 is a type error since GitHub issue
#884, so rule 2 now matters only where a placement function still holds the
slot as a word.
"""

import pathlib
import re
import sys

from pass_line import report_pass
from source_scan import code_only

KERNEL = pathlib.Path("kernel")
PROCESS = KERNEL / "kernel" / "process.tkb"

GONE = re.compile(
    r"\b(scheduled_process_boot_record|scheduled_process_boot_live|"
    r"scheduled_process_boot_generation|process_slot_is_boot|"
    r"scheduled_process_alloc_bootstrap|BootstrapProcessHandle|"
    r"ScheduledBootstrapProcessAllocResult)\b")

PLACEMENT = {
    "kernel_process_cpu_allows_slot", "kernel_process_core0_leave_excluded",
    "kernel_process_tick_leave_excluded", "kernel_process_stack_owner_probe",
    "kernel_process_spread_timer_progress", "kernel_stack_run_depth",
    "kernel_stack_bottom", "kernel_process_frame_belongs_to",
    "kernel_process_crash_frame_usable", "scheduled_process_record_locked",
    "scheduled_process_record_current", "scheduled_process_record_owned",
    "scheduled_process_record_stopped", "scheduled_process_scalar_snapshot",
    "scheduled_process_first_slot", "scheduled_process_next_slot",
    "scheduled_process_handle_matches", "scheduled_process_slot_valid",
    "scheduled_process_slot_remove", "scheduled_process_ddb_record",
    "scheduled_process_handle_of_slot",
    "scheduled_process_address_space_root_owned",
    "scheduled_process_address_space_root_locked",
    "scheduled_process_address_space_root_current",
    "scheduled_process_address_space_root_stopped",
}
SLOT_ZERO = re.compile(r"\bslot\s*[!=]=\s*0\b|\b0\s*[!=]=\s*slot\b")

# Calls whose first argument is a process slot.
PROCESS_FIRST = (
    "unified_fd_context_ensure", "unified_fd_context_release",
    "unified_fd_context_lookup", "unified_fd_install", "unified_fd_alloc",
    "unified_fd_close", "unified_fd_duplicate", "unified_file_lookup",
    "unified_terminal_stdio_open", "unified_terminal_is_open",
    "unified_fd_destroy", "unified_fd_clone", "unified_fd_offset",
    "unified_process_fd_limit_configure", "unified_process_heap_break",
    "unified_process_heap_range_configure",
    "scheduled_process_set_image_record", "scheduled_process_set_fd_context",
    "scheduled_process_slot_key_valid")
LITERAL_FIRST = re.compile(
    r"\b(" + "|".join(PROCESS_FIRST) + r")\(\s*0\s*[,)]")

FN_RE = re.compile(r"^(?:private )?(?:inline |noinline )?fn (\w+)\(")


def problems(root: pathlib.Path):
    found = []
    files = 0
    placement_seen = set()
    for path in sorted((root / KERNEL).rglob("*.tkb")):
        if "build" in path.parts:
            continue
        files += 1
        relative = path.relative_to(root)
        code = code_only(path.read_text(encoding="ascii"))
        enclosing = None
        for number, line in enumerate(code.splitlines(), start=1):
            match = FN_RE.match(line)
            if match:
                enclosing = match.group(1)
            where = f"{relative}:{number}"
            if GONE.search(line):
                found.append(f"{where}: names the static bootstrap record, "
                             "which #831 removed; every process is a pool slot")
            for regex in (LITERAL_FIRST,):
                hit = regex.search(line)
                if hit:
                    found.append(f"{where}: {hit.group(1)} is given process "
                                 "slot 0, which names no process since #831; "
                                 "use the process the call is about")
            if relative == PROCESS and enclosing in PLACEMENT:
                placement_seen.add(enclosing)
                if SLOT_ZERO.search(line):
                    found.append(f"{where}: {enclosing} branches on slot 0; "
                                 "placement, stack-run accounting, record "
                                 "access and root selection name no slot "
                                 "(#831)")
    if (root / PROCESS).exists():
        for name in sorted(PLACEMENT - placement_seen):
            found.append(f"{PROCESS}: {name} is listed as a placement "
                         "function and no longer exists; update PLACEMENT")
    return found, files


def main() -> int:
    root = pathlib.Path.cwd()
    found, files = problems(root)
    if found:
        for problem in found:
            print(f"ERROR\tprocess-slot-zero: {problem}", file=sys.stderr)
        print(f"FAIL process-slot-zero: {len(found)} place(s) treat slot 0 "
              "as a process", file=sys.stderr)
        return 1
    report_pass("process-slot-zero",
                "no static bootstrap name, no slot-0 branch in placement, "
                "stack-run, record or root selection, and no per-process "
                "call given slot 0",
                files=files, placement_functions=len(PLACEMENT))
    return 0


if __name__ == "__main__":
    sys.exit(main())
