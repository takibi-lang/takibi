#!/usr/bin/env python3
"""Every ext2 mutation runs under kernel/fs/ext2/mutation_lock.tkb's guard.

Usage: buildcheck_ext2_mutation_guard.py <kernel>.facts/callgraph.tsv

GitHub issue #533. ext2_claim_directory mints a directory owner from the
directory tree, which is sound only while one core at a time mutates. That
used to be an ADMISSION claim -- every process reaching the filesystem
admitted to core 0 -- and is now a lock. The guard is linear, so a path that
takes it and forgets to release it does not compile.

What the compiler does NOT check is the other direction: a mutating syscall
arm added later would compile perfectly well WITHOUT taking the guard, and
would simply fail to exclude. So this is the check that the set stays
closed.

The rule: every function that calls a mutator, outside the files that
define the mutators and the lock, calls ext2_mutation_take itself, or is
handed the guard as a `borrow Ext2MutationGuard[&ext2_mutation_lock]`
parameter -- or its file is named below with a reason. The parameter form
counts because the compiler checks it: the guard is linear and minted only
by the take, so a caller cannot produce one it does not hold (GitHub issue
#597).

GitHub issue #987: the facts come from the compiler's --facts callgraph.tsv
table of the kernel just compiled (scripts/call_graph_table.py), not from
regular expressions over the source. A call is a resolved call, so a
mutator named in a comment or a string is not one, and a guard taken only
in a comment takes nothing, by construction rather than by a comment
stripper. The kernel recipes run this on each kernel's own table.

Exit code only (0 = pass, 1 = fail).
"""

import sys

import call_graph_table
from pass_line import report_pass

# The operations that rewrite the directory tree or a file's blocks. Readers
# are deliberately absent: they take no lock by design, because
# peer_filesystem.expected measures both CPUs contending for the block device
# and a lock across reads would zero one side of that.
MUTATORS = (
    "ext2_resize_small_file",
    "ext2_create_root_file",
    "ext2_unlink_root_file",
    "ext2_create_file_in",
    "ext2_create_empty_file_in",
    "ext2_truncate_regular_file",
    "ext2_unlink_file_in",
    "ext2_make_directory_in",
    "ext2_claim_directory",
    "ext2_unlink_name",
    "ext2_rename_in",
    "ext2_remove_directory_in",
    "ext2_write_regular_file_range",
    "ext2_replace_regular_file",
    "ext2_bitmap_fill",
    "ext2_bitmap_roundtrip_check",
    "ext2_owner_roundtrip_check",
    "ext2_write_allocations_roundtrip_check",
)
# GitHub issue #1019: write(2)'s own mutator, ext2_write_regular_file_range,
# was missing from the list above, so the check proved nothing about the
# write path once it stopped going through ext2_resize_small_file. The list
# is now closed against the compiler's table: every function of MUTATOR_FILE
# that reaches BLOCK_WRITE there and is called from outside DEFINING must be
# named in MUTATORS.
BLOCK_WRITE = "ext2_block_write"
MUTATOR_FILE = "kernel/fs/ext2/ext2.tkb"
LOCK_FILE = "kernel/fs/ext2/mutation_lock.tkb"
TAKES = {"ext2_mutation_take": LOCK_FILE,
         "ext2_mutation_try_take": LOCK_FILE,
         "ext2_mkdir_mutation_take": "kernel/kernel/syscall.tkb"}
HELD = "guard: borrow Ext2MutationGuard[&ext2_mutation_lock]"

# The files that define the mutators and the lock: they call each other
# without the guard by design.
DEFINING = {MUTATOR_FILE, LOCK_FILE}

# Files permitted to mutate without the guard, and why. Empty since GitHub
# issue #1159 (2026-11-08): the boot fixture takes the guard too, because
# the undo log and the fence are reached only with it (guarded_ref).
UNGUARDED_ALLOWED: dict[str, str] = {}


def mutators_called(row: dict, mutators=MUTATORS) -> list[str]:
    return [call_graph_table.callee_name(entry) for entry in row["callees"]
            if call_graph_table.callee_name(entry) in mutators
            and call_graph_table.callee_file(entry) == MUTATOR_FILE]


def takes_guard(row: dict) -> bool:
    return any(call_graph_table.callee_name(entry) in TAKES
               and call_graph_table.callee_file(entry) == TAKES[call_graph_table.callee_name(entry)]
               for entry in row["callees"]) or HELD in row["params"]


def block_writers(rows: list[dict]) -> set[str]:
    """The MUTATOR_FILE functions whose calls there reach BLOCK_WRITE."""
    callees = {row["name"]: [call_graph_table.callee_name(entry)
                             for entry in row["callees"]
                             if call_graph_table.callee_file(entry) == MUTATOR_FILE]
               for row in rows if row["file"] == MUTATOR_FILE}
    writers = {BLOCK_WRITE}
    grew = True
    while grew:
        grew = False
        for name, called in callees.items():
            if name not in writers and any(c in writers for c in called):
                writers.add(name)
                grew = True
    return writers


def unlisted_mutators(rows: list[dict], mutators) -> list[str]:
    writers = block_writers(rows)
    found = set()
    for row in rows:
        if row["file"] in DEFINING:
            continue
        for entry in row["callees"]:
            name = call_graph_table.callee_name(entry)
            if (call_graph_table.callee_file(entry) == MUTATOR_FILE
                    and name in writers and name not in mutators):
                found.add(name)
    return sorted(found)


def guard_problems(rows: list[dict], mutators=MUTATORS) -> tuple[list[str], int]:
    """Problems found, and how many guarded mutating functions were seen."""
    problems = []
    for name in unlisted_mutators(rows, mutators):
        problems.append(f"{name} in {MUTATOR_FILE} reaches {BLOCK_WRITE} and is "
                        "called from outside it, but is not in MUTATORS: its "
                        "callers are not checked for the guard (GitHub issue #1019)")
    defined = {row["name"] for row in rows if row["file"] == MUTATOR_FILE}
    defined_takes = {row["name"] for row in rows if row["file"] == TAKES.get(row["name"])}
    for name in mutators:
        if name not in defined:
            problems.append(f"mutator {name} is not defined in {MUTATOR_FILE}; "
                            "a renamed mutator would leave this check matching nothing")
    for take in TAKES:
        if take not in defined_takes:
            problems.append(f"{take} is not defined in {TAKES[take]}")
    guarded = 0
    for row in rows:
        if row["file"] in DEFINING:
            continue
        called = mutators_called(row, mutators)
        if not called:
            continue
        if takes_guard(row):
            guarded += 1
            continue
        if row["file"] in UNGUARDED_ALLOWED:
            continue
        problems.append(
            f"{row['file']}:{row['line']} {row['name']} calls "
            f"{', '.join(sorted(set(called)))} and does not take "
            f"{LOCK_FILE}'s guard. An ext2 mutation that excludes nothing "
            "re-opens GitHub issue #533: two claims of one directory entry are "
            "two owners of one block. Take the guard, or add this file to "
            "UNGUARDED_ALLOWED in this script with the reason it cannot race a peer")
    for name in UNGUARDED_ALLOWED:
        if not any(row["file"] == name and mutators_called(row, mutators)
                   for row in rows):
            problems.append(
                f"{name} is allowed to mutate without the guard but no longer "
                "does (or is not compiled): remove the entry rather than "
                "leaving a claim about nothing")
    return problems, guarded


def planted(rows: list[dict], name: str, column: str, change) -> list[dict]:
    """A copy of the table with one row's column changed; the row must exist."""
    matches = [row for row in rows if row["name"] == name]
    if len(matches) != 1:
        raise SystemExit(f"FAIL ext2-mutation-guard: the negative control's subject "
                         f"{name} is in the table {len(matches)} times, not once")
    copy = [dict(row) for row in rows]
    target = next(row for row in copy if row["name"] == name)
    target[column] = change(target[column])
    return copy


DRAIN_PARK = "kernel_process_ext2_drain_park"
DRAIN_LANDING = "kernel_process_ext2_drain_land"
DRAIN_FORBIDDEN = {
    "kernel_process_reap_zombie",
    "arm64_ordinary_depart_exception",
    "arm64_ordinary_depart_ordinary",
    "kernel_process_rollover_backoff",
    "asid_rollover_stopped",
    "world_stop_machine_begin",
    "world_stop_machine_begin_holding_probe",
    "world_stop_machine_begin_kind",
    "*",
}


def drain_landing_problems(rows: list[dict]) -> list[str]:
    callees: dict[str, set[str]] = {}
    for row in rows:
        callees.setdefault(row["name"], set()).update(
            call_graph_table.callee_name(entry) for entry in row["callees"])
    if DRAIN_PARK not in callees or DRAIN_LANDING not in callees[DRAIN_PARK]:
        return ["reader-drain park must reach its dedicated landing directly"]
    if "arm64_ordinary_depart_idle" not in callees[DRAIN_PARK]:
        return ["reader-drain park must directly depart to idle"]
    visited = set()
    pending = [DRAIN_PARK]
    while pending:
        name = pending.pop()
        if name not in visited:
            visited.add(name)
            pending.extend(callees.get(name, ()))
    return [f"reader-drain park reaches {name} with the mutation guard held"
            for name in sorted(visited & DRAIN_FORBIDDEN)]


def controls_fail(rows: list[dict]) -> list[str]:
    """Defects planted in the table that must be refused; the ones that are not."""
    failed = []
    # syscall_ext2_write_locked takes the guard itself. Since #1035 it hands
    # it to ext2_syscall_write_at rather than calling the mutator, so the
    # plant also makes it call that mutator directly: a helper that calls a
    # mutator and no longer takes the guard.
    mutator_call = next(entry for row in rows
                        if row["name"] == "ext2_syscall_write_at"
                        for entry in row["callees"]
                        if call_graph_table.callee_name(entry) in MUTATORS)
    untaken = planted(rows, "syscall_ext2_write_locked", "callees",
                      lambda callees: [c for c in callees
                                       if call_graph_table.callee_name(c) not in TAKES]
                      + [mutator_call])
    if not guard_problems(untaken)[0]:
        failed.append("a helper that no longer takes the guard")
    # ext2_syscall_mkdir (kernel/fs/ext2/ext2_syscall.tkb, #1035) is handed it.
    unborrowed = planted(rows, "ext2_syscall_mkdir", "params",
                         lambda params: [p.replace(HELD, "guard: usize") for p in params])
    if not guard_problems(unborrowed)[0]:
        failed.append("a helper whose guard parameter is a plain word")
    # A mutator renamed out from under MUTATORS.
    renamed = planted(rows, "ext2_claim_directory", "name", lambda _: "ext2_claim_dir")
    if not guard_problems(renamed)[0]:
        failed.append("a renamed mutator")
    # A block-writing mutator dropped from MUTATORS (#1019's shape).
    dropped = tuple(m for m in MUTATORS if m != "ext2_write_regular_file_range")
    if not guard_problems(rows, dropped)[0]:
        failed.append("a block-writing mutator missing from MUTATORS")
    for name in sorted(DRAIN_FORBIDDEN):
        changed = planted(rows, DRAIN_LANDING, "callees",
                          lambda callees: callees + [name if name == "*" else name + "@-"])
        if not drain_landing_problems(changed):
            failed.append(f"reader-drain landing reaching {name}")
    return failed


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__.splitlines()[2], file=sys.stderr)
        return 2
    try:
        rows = call_graph_table.read(sys.argv[1])
    except (OSError, call_graph_table.TableError) as error:
        print(f"FAIL ext2-mutation-guard: {error}")
        return 1
    problems, guarded = guard_problems(rows)
    problems += drain_landing_problems(rows)
    for problem in problems:
        print(f"ERROR ext2-mutation-guard: {problem}")
    if problems:
        print("FAIL ext2-mutation-guard: an ext2 mutation is not excluded")
        return 1
    if not_refused := controls_fail(rows):
        print("FAIL ext2-mutation-guard: negative control(s) "
              f"{'; '.join(not_refused)} were accepted, so this check proves nothing")
        return 1
    report_pass(
        "ext2-mutation-guard",
        f"{guarded} guarded mutating function(s) in {sys.argv[1]}, "
        f"{len(UNGUARDED_ALLOWED)} file exempt with a stated reason, and a "
        "helper stripped of its guard, taken or borrowed, is refused",
        guarded_functions=guarded,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
