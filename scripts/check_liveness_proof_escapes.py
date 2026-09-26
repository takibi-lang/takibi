#!/usr/bin/env python3
"""Every place that drops a pool's liveness proof is declared here.

`kernel/lib/intrusive_pool.tkb` hands out a linear proof that a slot is
occupied -- an `IntrusiveSlotView` from a probe, an `IntrusiveOwner` from an
allocation -- and its payload accessors return a pointer TIED to that proof,
so the pointer cannot outlive it (GitHub issue #488).

`intrusive_pool_payload_unproven_of` and `intrusive_pool_ref_unproven` are the
escapes. They still require a successful probe, so they cannot read a free
slot as a T; what they drop is the lifetime relation. `kernel/CONCURRENCY.md`
says of them: "Laundering is not forbidden; it is a number."

Nothing made it a number. This does. Adding a call site here is a claim that
this particular caller cannot hold the proof for the pointer's life -- which
in every current case means it RETURNS the pointer, so removing the escape is
a migration of that accessor's callers rather than a local edit.

Why this rather than a compiler rule: the escapes are legitimate, so the
language cannot forbid them. What can go wrong is the SET growing quietly,
one convenient call at a time, until the guarantee is decorative. A migration
loop already over-applied them once by seven -- an escape and a `borrow`
produce the same silence, so nothing but a declared list distinguishes "had
to" from "was easier".

Exit code only (0 = pass, 1 = fail).
"""

import pathlib
import re
import sys

from pass_line import report_pass

ROOTS = (pathlib.Path("kernel"), pathlib.Path("linux_user"))
DEFINING_FILE = pathlib.Path("kernel/lib/intrusive_pool.tkb")

# Deliberately matches the NAME alone rather than the name plus its first
# argument. The first version required `(&` on the same line and silently
# missed every wrapped call -- two of them, in the file this whole issue is
# about. A checker that under-detects is worse than none, because it reports
# a number that reads as complete.
ESCAPE_RE = re.compile(
    r"\bintrusive_pool_(?:payload_unproven_of|ref_unproven)\s*\(")
FN_RE = re.compile(r"^(?:private )?fn ([A-Za-z_0-9]+)")

# (file, enclosing function) -> why this caller cannot hold the proof.
# GitHub issue #482: each entry names what keeps the payload alive after
# the pool's view is dropped -- the lifetime the caller supplies instead --
# not merely that the function returns a pointer. A new entry has to find
# its own answer.
ALLOWED = {
    ("kernel/kernel/fd_table.tkb", "fd_context_at"):
        "a process's fd context is released only when the process is reaped "
        "(or its creation is rolled back before anyone sees it); until then "
        "only the process's own syscalls and, after it exits, its reaper reach "
        "it",
    ("kernel/kernel/fd_table.tkb", "fd_block_at"):
        "descriptor blocks belong to one fd context and are released only "
        "with it, so fd_context_at's lifetime covers them",
    ("kernel/kernel/fd_table.tkb", "unified_object_at"):
        "a shared object is freed only when its reference count reaches zero "
        "under object_refcount_lock, and every reader reaches it through a "
        "descriptor that holds one of those references",
    ("kernel/kernel/process.tkb", "scheduled_process_record_at"):
        "a record leaves the pool only through scheduled_process_slot_remove, "
        "which requires the process-run guard (#482); a reader of another "
        "process's record holds that lock, and a reader of its own is not "
        "yet reaped. Returns the pointer to 77 call sites that still take a "
        "bare slot (#492)",
    ("kernel/kernel/process.tkb", "scheduled_process_record_peek"):
        "deliberately tolerates a dead slot for crash and trace paths, and "
        "returns the pointer",
    ("kernel/mm/address_space.tkb", "address_space_backing_at"):
        "a backing is released only when its process is reaped, and only a "
        "process holding a Running token (or its reaper) activates or edits "
        "it",
    ("kernel/mm/address_space.tkb", "address_space_backing_existing_at"):
        "the same lifetime as address_space_backing_at",
    ("kernel/mm/process_image.tkb", "process_image_record_at"):
        "an image record is released only when its process is reaped, and "
        "only that process's exec and fault paths, or its reaper, reach it",
    ("kernel/net/tcp.tkb", "tcp_frame_slice"):
        "a frame belongs to one connection and is released only with it or "
        "displaced by a holder of that connection's owner",
    ("kernel/net/tcp.tkb", "tcp_connection_payload"):
        "a connection is freed only by tcp_connection_free, which consumes "
        "its owner; every caller holds the owner while it uses the payload",
    ("kernel/net/tcp.tkb", "tcp_connection_alloc"):
        "uses the payload after the pool owner is discharged into "
        "TcpConnectionOwner, which is the ownership handoff GitHub issue "
        "#462 settled deliberately",
}


def escapes():
    """Return the proof-dropping call sites and the files scanned."""
    found = []
    scanned = 0
    for root in ROOTS:
        if not root.is_dir():
            continue
        for path in sorted(root.rglob("*.tkb")):
            if path == DEFINING_FILE:
                continue
            scanned += 1
            enclosing = "<file scope>"
            for number, line in enumerate(path.read_text().splitlines(), 1):
                match = FN_RE.match(line)
                if match:
                    enclosing = match.group(1)
                if ESCAPE_RE.search(line):
                    found.append((str(path), enclosing, number))
    return found, scanned


def main():
    found, scanned = escapes()
    failures = []
    for path, function, number in found:
        if (path, function) not in ALLOWED:
            failures.append(
                "%s:%d: %s drops a pool liveness proof and is not declared "
                "in this script. Either hold the proof across the read and "
                "release it after, or add the caller here with the reason it "
                "cannot" % (path, number, function))

    declared = {key for key in ALLOWED}
    seen = {(path, function) for path, function, _ in found}
    for key in sorted(declared - seen):
        failures.append(
            "%s / %s is declared here but no longer drops a proof; remove the "
            "entry so the list keeps meaning something" % key)

    if failures:
        for line in failures:
            print("FAIL liveness-proof-escapes: " + line, file=sys.stderr)
        return 1

    report_pass("liveness-proof-escapes",
                "%d declared escape(s) across %d files, each with a stated "
                "reason" % (len(found), scanned),
                files=scanned)
    return 0


if __name__ == "__main__":
    sys.exit(main())
