#!/usr/bin/env python3
"""No syscall registered as an ext2 reader waits for the ext2 mutation guard.

Usage: buildcheck_ext2_reader_self_wait.py <kernel>.facts/callgraph.tsv

GitHub issue #1015. A syscall that reaches ext2 is counted as a reader at
entry (syscall_ext2_reader_mark, GitHub issue #559) until
syscall_ext2_reader_take releases it. ext2_mutation_take waits until no
reader is counted. A registered syscall that then takes the guard waits for
itself, forever: #967 met this with openat O_CREAT and avoided it by not
registering that path. Nothing in the compiler stops the next mutating
syscall from repeating it, so this check reads the --facts callgraph.tsv table
(GitHub issue #987, scripts/call_graph_table.py) and refuses:

1. a caller of syscall_ext2_reader_mark other than REGISTRAR, or a caller
   of syscall_ext2_reader_take other than RELEASERS -- either would move the
   registered window this check reasons about;
2. any path from the registered window to ext2_mutation_take. The window is
   every callee of REGISTRAR (the dispatch that runs the handler while the
   registration is held), every callee of the releasers other than
   REGISTRAR itself, and the call chains below them. A callee named in
   MUTATING_ARMS is allowed, with the syscall numbers it serves: those are
   numbers syscall_reaches_filesystem does not register;
3. a MUTATING_ARMS entry that no longer reaches the guard (a claim about
   nothing).

What the table cannot say: which syscall NUMBER selects which arm of
REGISTRAR. The rule is function-level: a new mutation written as a helper
the dispatch calls is refused until it is named in MUTATING_ARMS with the
numbers it serves, which is the review point; an arm that takes the guard
inline in REGISTRAR is covered by the ext2_mutation_take entry and by the
comment on syscall_reaches_filesystem, not by this check.

Exit code only (0 = pass, 1 = fail).
"""

import sys

import call_graph_table
from pass_line import report_pass

SYSCALL_FILE = "kernel/kernel/syscall.tkb"
LOCK_FILE = "kernel/fs/ext2/mutation_lock.tkb"
TAKE = "ext2_mutation_take"
MARK = "syscall_ext2_reader_mark"
RELEASE = "syscall_ext2_reader_take"
REGISTRAR = "kernel_syscall_dispatch_action"
RELEASERS = ("kernel_syscall_dispatch", "kernel_syscall_child_exec_return")

# Callees of the registered window that do reach the guard, and the syscall
# numbers they serve. Each number must be one syscall_reaches_filesystem
# answers false for; that function's comment says why.
MUTATING_ARMS = {
    TAKE: "taken inline by REGISTRAR for mkdirat (34), unlinkat (35), "
          "renameat (38) and openat with O_CREAT (56, #967)",
    "syscall_write_segment": "write (64) and sendto with no address (206) "
                             "to an ext2 file, through syscall_ext2_write_locked",
    "syscall_writev_current": "writev (66) to an ext2 file, through "
                              "syscall_ext2_write_locked",
}


def by_name(rows: list[dict]) -> dict[str, dict]:
    return {row["name"]: row for row in rows}


def names(entries: list[str]) -> list[str]:
    return [call_graph_table.callee_name(entry) for entry in entries]


def chain_to_take(rows: dict[str, dict], start: str) -> list[str] | None:
    """A shortest call chain start -> ... -> TAKE, or None."""
    if start == TAKE:
        return [TAKE]
    parent = {start: None}
    frontier = [start]
    while frontier:
        following = []
        for name in frontier:
            row = rows.get(name)
            if row is None:
                continue
            for entry in row["callees"]:
                callee = call_graph_table.callee_name(entry)
                if callee in parent:
                    continue
                if callee == TAKE and call_graph_table.callee_file(entry) != LOCK_FILE:
                    continue
                parent[callee] = name
                if callee == TAKE:
                    chain = [TAKE]
                    while parent[chain[-1]] is not None:
                        chain.append(parent[chain[-1]])
                    return list(reversed(chain))
                following.append(callee)
        frontier = following
    return None


def self_wait_problems(table: list[dict]) -> tuple[list[str], int]:
    """Problems found, and how many window callees were checked."""
    rows = by_name(table)
    problems = []
    for name, file in ((TAKE, LOCK_FILE), (MARK, SYSCALL_FILE),
                       (RELEASE, SYSCALL_FILE), (REGISTRAR, SYSCALL_FILE),
                       *((releaser, SYSCALL_FILE) for releaser in RELEASERS)):
        if name not in rows or rows[name]["file"] != file:
            problems.append(f"{name} is not defined in {file}; a rename would "
                            "leave this check reasoning about nothing")
    if problems:
        return problems, 0
    marks = sorted(set(names(rows[MARK]["callers"])))
    if marks != [REGISTRAR]:
        problems.append(
            f"{MARK} is called by {', '.join(marks) or 'nothing'}, not by "
            f"{REGISTRAR} alone. A new reader registration opens a window this "
            "check does not see: register in the one dispatch, or extend "
            "REGISTRAR in this script with the window it opens")
    releases = sorted(set(names(rows[RELEASE]["callers"])))
    if releases != sorted(RELEASERS):
        problems.append(
            f"{RELEASE} is called by {', '.join(releases) or 'nothing'}, not by "
            f"{', '.join(sorted(RELEASERS))}: the registration is now released "
            "somewhere this check does not include in the window; update RELEASERS")
    # MUTATING_ARMS are dispatch arms: allowed only as REGISTRAR's own
    # callees. A releaser runs for every registered syscall alike.
    window = [(REGISTRAR, callee) for callee in sorted(set(names(rows[REGISTRAR]["callees"])))]
    for releaser in RELEASERS:
        window += [(releaser, callee) for callee in sorted(set(names(rows[releaser]["callees"])))]
    checked = 0
    for owner, callee in window:
        if callee in (REGISTRAR, "*"):
            continue
        checked += 1
        chain = chain_to_take(rows, callee)
        if chain is None:
            continue
        if owner == REGISTRAR and callee in MUTATING_ARMS:
            continue
        problems.append(
            f"{' -> '.join([owner] + chain)}: "
            f"{callee} runs while the syscall is counted as an ext2 reader "
            f"({MARK}) and reaches {TAKE}, which waits for every counted "
            "reader, itself included (GitHub issue #1015). Do not register "
            "the syscall in syscall_reaches_filesystem, or, if it is already "
            "unregistered, name it in MUTATING_ARMS with the numbers it serves")
    for arm in MUTATING_ARMS:
        if (REGISTRAR, arm) not in window or chain_to_take(rows, arm) is None:
            problems.append(
                f"MUTATING_ARMS names {arm}, which is no longer a window "
                f"callee that reaches {TAKE}: remove the entry")
    return problems, checked


def planted(table: list[dict], name: str, change) -> list[dict]:
    """A copy of the table with one row's callees changed; the row must exist."""
    if sum(row["name"] == name for row in table) != 1:
        raise SystemExit(f"FAIL ext2-reader-self-wait: the negative control's "
                         f"subject {name} is not in the table exactly once")
    copy = [dict(row) for row in table]
    target = next(row for row in copy if row["name"] == name)
    target["callees"] = change(list(target["callees"]))
    return copy


def take_entry(table: list[dict]) -> str:
    row = next(row for row in table if row["name"] == TAKE)
    return f"{TAKE}@{row['file']}:{row['line']}"


def mark_entry(table: list[dict]) -> str:
    row = next(row for row in table if row["name"] == MARK)
    return f"{MARK}@{row['file']}:{row['line']}"


def with_caller(table: list[dict], callee: str, caller: str) -> list[dict]:
    """Record caller in callee's callers too, as the compiler would."""
    row = next(row for row in table if row["name"] == caller)
    for target in table:
        if target["name"] == callee:
            target["callers"] = target["callers"] + [f"{caller}@{row['file']}:{row['line']}"]
    return table


def controls_fail(table: list[dict]) -> list[str]:
    """Self-waits planted in the table that must be refused; the ones that are not."""
    failed = []
    take = take_entry(table)
    # A reader handler (openat without O_CREAT) that takes the guard: the
    # #967 shape.
    if not self_wait_problems(planted(table, "syscall_openat",
                                      lambda callees: callees + [take]))[0]:
        failed.append("a registered reader handler that takes the guard")
    # The exec prepare, run after dispatch with the registration still held.
    if not self_wait_problems(planted(table, "kernel_syscall_child_exec_return",
                                      lambda callees: callees + [take]))[0]:
        failed.append("a releaser that takes the guard before releasing")
    # A second registration site.
    second = planted(table, "syscall_ext2_write_locked",
                     lambda callees: callees + [mark_entry(table)])
    if not self_wait_problems(with_caller(second, MARK, "syscall_ext2_write_locked"))[0]:
        failed.append("a second reader registration")
    return failed


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__.splitlines()[2], file=sys.stderr)
        return 2
    try:
        table = call_graph_table.read(sys.argv[1])
    except (OSError, call_graph_table.TableError) as error:
        print(f"FAIL ext2-reader-self-wait: {error}")
        return 1
    problems, checked = self_wait_problems(table)
    for problem in problems:
        print(f"ERROR ext2-reader-self-wait: {problem}")
    if problems:
        print("FAIL ext2-reader-self-wait: a registered ext2 reader can wait for itself")
        return 1
    if not_refused := controls_fail(table):
        print("FAIL ext2-reader-self-wait: negative control(s) "
              f"{'; '.join(not_refused)} were accepted, so this check proves nothing")
        return 1
    report_pass(
        "ext2-reader-self-wait",
        f"{checked} callee(s) of the registered reader window in {sys.argv[1]} "
        f"checked, {len(MUTATING_ARMS)} unregistered mutating arm(s) named, and "
        "a planted reader self-wait is refused",
        window_callees=checked,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
