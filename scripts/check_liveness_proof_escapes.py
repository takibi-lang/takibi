#!/usr/bin/env python3
"""Every place that drops a pool's liveness proof is declared here.

`kernel/lib/intrusive_pool.tkb` hands out a linear proof that a slot is
occupied -- an `IntrusiveSlotView` from a probe, an `IntrusiveOwner` from an
allocation -- and its payload accessors return a pointer TIED to that proof,
so the pointer cannot outlive it (GitHub issue #488).

The two historical escape names are retired. No maintained caller may drop
the relation through either name. This gate preserves the completed migration
and catches a reintroduced legacy definition or call outside the pool file.
It is source containment; the compiler establishes the lifetime of actual
authority-derived loans.

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
FN_RE = re.compile(r"^(?:private )?(?:inline |noinline )?fn ([A-Za-z_0-9]+)")

# (file, enclosing function) -> why this caller cannot hold the proof.
# GitHub issue #482: each entry names what keeps the payload alive after
# the pool's view is dropped -- the lifetime the caller supplies instead --
# not merely that the function returns a pointer. A new entry has to find
# its own answer.
ALLOWED = {}


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
