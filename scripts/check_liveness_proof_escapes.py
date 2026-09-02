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
ALLOWED = {
    ("kernel/kernel/fd_table.tkb", "fd_context_at"):
        "returns the pointer to callers that index it directly",
    ("kernel/kernel/fd_table.tkb", "fd_block_at"):
        "returns the pointer",
    ("kernel/kernel/fd_table.tkb", "unified_object_at"):
        "returns the pointer",
    ("kernel/kernel/process.tkb", "scheduled_process_record_at"):
        "the counted process-record accessor; returns the pointer to 77 "
        "call sites that still take a bare slot (GitHub issue #492)",
    ("kernel/kernel/process.tkb", "scheduled_process_record_peek"):
        "deliberately tolerates a dead slot for crash and trace paths, and "
        "returns the pointer",
    ("kernel/mm/address_space.tkb", "address_space_backing_at"):
        "returns the pointer",
    ("kernel/mm/address_space.tkb", "address_space_backing_existing_at"):
        "returns the pointer",
    ("kernel/mm/process_image.tkb", "process_image_record_at"):
        "returns the pointer",
    ("kernel/net/tcp.tkb", "tcp_frame_slice"):
        "returns a slice of the payload, which outlives the view",
    ("kernel/net/tcp.tkb", "tcp_connection_payload"):
        "returns the pointer",
    ("kernel/net/tcp.tkb", "tcp_connection_alloc"):
        "uses the payload after the pool owner is discharged into "
        "TcpConnectionOwner, which is the ownership handoff GitHub issue "
        "#462 settled deliberately",
}


def escapes():
    found = []
    for root in ROOTS:
        if not root.is_dir():
            continue
        for path in sorted(root.rglob("*.tkb")):
            if path == DEFINING_FILE:
                continue
            enclosing = "<file scope>"
            for number, line in enumerate(path.read_text().splitlines(), 1):
                match = FN_RE.match(line)
                if match:
                    enclosing = match.group(1)
                if ESCAPE_RE.search(line):
                    found.append((str(path), enclosing, number))
    return found


def main():
    found = escapes()
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

    print("PASS liveness-proof-escapes: %d declared escape(s), each with a "
          "stated reason" % len(found))
    return 0


if __name__ == "__main__":
    sys.exit(main())
