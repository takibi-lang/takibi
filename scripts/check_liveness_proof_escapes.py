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

GitHub issue #343 adds the other half: a non-private function in a pool
library that hands out a pointer or reference to the element type (`*T`,
`&mut T`, `*IntrusiveSlot(T)`) must bind it to an authority with `@`, so
there is no public way to get a payload pointer that outlives its proof.
Allocator metadata (`*usize`, `*IntrusiveChunkHeader`) is not the payload
and is not covered.

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


POOL_FILES = tuple(pathlib.Path("kernel/lib") / name for name in (
    "intrusive_pool.tkb", "freelist.tkb", "slotmap.tkb",
    "refcount_slotmap.tkb", "occupancy.tkb"))
PUBLIC_FN_RE = re.compile(r"^(?:inline |noinline )?fn ([A-Za-z_0-9]+)\(")
# The element type reached by a returned pointer or reference: `T` itself
# or a generic instance carrying it, e.g. `IntrusiveSlot(T)`.
PAYLOAD_RETURN_RE = re.compile(
    r"->\s*(?:\*|&mut\s+|&\s*)(?:T\b|[A-Za-z_0-9]+\(T\))")


def unbound_payload_returns(sources):
    """Return (path, function) for each public unbound payload pointer."""
    found = []
    for path, text in sources:
        lines = text.splitlines()
        for index, line in enumerate(lines):
            match = PUBLIC_FN_RE.match(line)
            if not match:
                continue
            header = line
            follow = index
            while "{" not in header and follow + 1 < len(lines):
                follow += 1
                header += " " + lines[follow].strip()
            signature = header.split("{", 1)[0]
            returned = signature.split("->", 1)
            if len(returned) != 2:
                continue
            ret = "->" + returned[1].split("!", 1)[0]
            if PAYLOAD_RETURN_RE.search(ret) and "@" not in ret:
                found.append((str(path), match.group(1)))
    return found


def pool_payload_controls():
    """The rule refuses the shapes it exists for and admits the bound one."""
    failures = []
    for bad in ("fn leak(T: type, p: &mut Pool(T)) -> *T {",
                "fn leak(T: type, p: &mut Pool(T),\n        o: borrow O[a]) -> &mut T !{unsafe} {",
                "inline fn leak(T: type) -> *IntrusiveSlot(T) {"):
        if not unbound_payload_returns([("control.tkb", bad)]):
            failures.append("control accepted an unbound payload return: %r" % bad)
    for good in ("fn ok(T: type, o: borrow O[a]) -> *T @ a {",
                 "private fn inner(T: type) -> *T {",
                 "fn meta(T: type) -> *usize {",
                 "fn header(T: type) -> *IntrusiveChunkHeader {"):
        if unbound_payload_returns([("control.tkb", good)]):
            failures.append("control refused an allowed return: %r" % good)
    return failures


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

    pool_sources = [(path, path.read_text()) for path in POOL_FILES
                    if path.is_file()]
    for path, function in unbound_payload_returns(pool_sources):
        failures.append(
            "%s: %s is public and returns a payload pointer with no `@` "
            "binding; tie it to the owner, view or guard that keeps the slot "
            "alive, or make it private (GitHub issue #343)" % (path, function))
    failures += pool_payload_controls()

    if failures:
        for line in failures:
            print("FAIL liveness-proof-escapes: " + line, file=sys.stderr)
        return 1

    report_pass("liveness-proof-escapes",
                "%d declared escape(s) across %d files, each with a stated "
                "reason; %d pool file(s) hand out no unbound payload pointer"
                % (len(found), scanned, len(pool_sources)),
                files=scanned, pool_files=len(pool_sources))
    return 0


if __name__ == "__main__":
    sys.exit(main())
