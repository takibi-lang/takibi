#!/usr/bin/env python3
"""Every ext2 release and create writes through the undo log.

Usage: buildcheck_ext2_release_log.py <kernel>.callgraph.tsv

GitHub issue #1088. O_TRUNC, the last unlink of a file, rename over a file
and rmdir used to write their blocks one after another with no way back: a
rejected write part way leaked blocks or an inode, left the free counts
disagreeing with the bitmaps, or -- for rename -- lost the target name. They
now log every range they rewrite (ext2_undo_save + ext2_undo_write) and free
their blocks last, in the one bitmap write of ext2_release_commit, so a
rejected write before that puts the log back. GitHub issue #1120 put the
operations that add a name -- create, mkdir and rename to a new name --
on the same log: they write the blocks they claim while those blocks' bits
are still clear (ext2_claimed_write) and set the bits last, in the one
bitmap write of ext2_create_commit. The linear Ext2Undo token
makes every path end in a commit or an abort; what the compiler does NOT
check is that a release writes only through the log. A helper added later
that calls ext2_block_write itself would compile and silently reopen #1088.

So this reads the compiler's --emit-call-graph table (GitHub issue #987,
scripts/call_graph_table.py) and refuses any function reachable from a
release root, inside kernel/fs/ext2/ext2.tkb, that calls ext2_block_write
or the raw block_write, other than the writers named below with the reason
each may, and any reached function but a root that opens a log of its own
(ext2_undo_begin): such a helper, ext2_directory_remove for one, commits its
write at once, outside the release's rollback. The walk does not descend
into the writers. It also refuses a root or a writer that no longer exists
or is no longer reached: a claim about nothing.

Exit code only (0 = pass, 1 = fail).
"""

import sys

import call_graph_table
from pass_line import report_pass

FILE = "kernel/fs/ext2/ext2.tkb"
BLOCK_LAYER = "kernel/drivers/block/memory.tkb"
FENCED_WRITE = "ext2_block_write"
RAW_WRITE = "block_write"
BEGIN = "ext2_undo_begin"

ROOTS = (
    "ext2_truncate_regular_file_with",
    "ext2_unlink_name_with",
    "ext2_rename_over",
    "ext2_rmdir_release",
    "ext2_create_file_in_with",
    "ext2_create_empty_file_in_with",
    "ext2_make_directory_in_with",
    "ext2_rename_new",
)

WRITERS = {
    "ext2_undo_write": "the logged write: its row joins the log when it lands",
    "ext2_undo_put_back": "the rollback, which puts a logged range back",
    "ext2_release_commit": "the commit's one bitmap write, then the recount "
                           "and the scrub that follow it",
    "ext2_walk_visit": "only its Scrub mode writes, and only "
                       "ext2_release_commit runs it, after the commit",
    "ext2_claimed_write": "a block the create claims, whose bit stays clear "
                          "until the commit, so nothing reads it and a "
                          "rollback leaves it free",
    "ext2_create_commit": "the create's commit: one bitmap write marking "
                          "the claimed blocks, then the recount",
}


def writes(row: dict) -> list[str]:
    found = []
    for entry in row["callees"]:
        name = call_graph_table.callee_name(entry)
        where = call_graph_table.callee_file(entry)
        if (name == FENCED_WRITE and where == FILE) or \
           (name == RAW_WRITE and where == BLOCK_LAYER):
            found.append(name)
    return found


def problems_in(rows: list[dict]) -> tuple[list[str], int]:
    """Problems, and how many functions the walk reached."""
    table = {row["name"]: row for row in rows if row["file"] == FILE}
    problems = []
    for name in ROOTS + tuple(WRITERS):
        if name not in table:
            problems.append(f"{name} is not defined in {FILE}; a rename "
                            "would leave this check matching nothing")
    if problems:
        return problems, 0
    reached = set()
    seen_writers = set()
    todo = list(ROOTS)
    while todo:
        name = todo.pop()
        if name in reached:
            continue
        reached.add(name)
        if name in WRITERS:
            seen_writers.add(name)
            continue
        row = table[name]
        if found := writes(row):
            problems.append(
                f"{FILE}:{row['line']} {name} is reached from a release and "
                f"calls {', '.join(sorted(set(found)))} itself. A release "
                "or create writes through ext2_undo_save/ext2_undo_write and "
                "frees or claims its blocks in ext2_release_commit or "
                "ext2_create_commit, so a rejected write can be put back "
                "(GitHub issues #1088, #1120); route the write through the "
                "log, or name the function in WRITERS with the reason")
        if name not in ROOTS and any(
                call_graph_table.callee_name(entry) == BEGIN
                for entry in row["callees"]):
            problems.append(
                f"{FILE}:{row['line']} {name} is reached from a release and "
                f"opens its own undo log ({BEGIN}), which commits outside the "
                "release's rollback (GitHub issue #1088); pass the release's "
                "log down instead")
        for entry in row["callees"]:
            if call_graph_table.callee_file(entry) == FILE:
                todo.append(call_graph_table.callee_name(entry))
    for name in WRITERS:
        if name not in seen_writers:
            problems.append(f"{name} is allowed to write but no release "
                            "reaches it: remove the entry")
    return problems, len(reached)


def planted_refused(rows: list[dict], callee: str) -> bool:
    """ext2_inode_clear_logged given one more callee must be refused."""
    subject = "ext2_inode_clear_logged"
    copy = [dict(row) for row in rows]
    target = [row for row in copy
              if row["name"] == subject and row["file"] == FILE]
    if len(target) != 1:
        return False
    target[0]["callees"] = target[0]["callees"] + [f"{callee}@{FILE}:1"]
    return bool(problems_in(copy)[0])


def control_refused(rows: list[dict]) -> bool:
    """A direct write, and a log of its own, planted in a logged helper."""
    return planted_refused(rows, FENCED_WRITE) and planted_refused(rows, BEGIN)


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__.splitlines()[2], file=sys.stderr)
        return 2
    try:
        rows = call_graph_table.read(sys.argv[1])
    except (OSError, call_graph_table.TableError) as error:
        print(f"FAIL ext2-release-log: {error}")
        return 1
    problems, reached = problems_in(rows)
    for problem in problems:
        print(f"ERROR ext2-release-log: {problem}")
    if problems:
        print("FAIL ext2-release-log: a release writes outside its undo log")
        return 1
    if not control_refused(rows):
        print("FAIL ext2-release-log: a negative control (a logged helper "
              "calling ext2_block_write, or opening its own log) was "
              "accepted, so this check proves nothing")
        return 1
    report_pass(
        "ext2-release-log",
        f"{reached} function(s) reached from {len(ROOTS)} release root(s) "
        f"write only through {len(WRITERS)} named writer(s), and a planted "
        "direct write or nested log is refused",
        reached_functions=reached,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
