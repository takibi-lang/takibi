#!/usr/bin/env python3
"""A pool slot is cleared before it starts answering Live, not after.

`intrusive_pool_insert_unchecked` reads the free-chain link out of the slot's
own storage -- the link and the payload's first word are the same bytes
(issue #348) -- and then stamps a generation. The stamp is what makes
`intrusive_pool_probe_slot` answer `Live`, so between the stamp and whatever
clears the storage, the pool reports an occupied slot whose payload is the
previous occupant's chain link: a well-formed slot address, which reads as a
plausible pointer rather than as obvious rubbish.

That was the order, and it was measured (issue #514): a lockless walker read
`0x403b07e0` and `0x403b0000` as a payload's first word, one
`IntrusiveSlot(T)` stride apart. `intrusive_pool_insert_zeroed` cleared the
storage, but from outside `insert_unchecked`, after the stamp had already
happened.

The repair was to move the clear one step earlier, ahead of the stamp. It
costs nothing -- the same bytes, under the same guard -- and there is nothing
in the type system that holds it there. Two statements in one function whose
order is the whole property, and whose wrong order is silent: every lane stays
green, because the window needs a second core reading without the lock to be
seen at all.

So this compares their positions. It is not a parser: it finds one named
function and two literal statements inside it.

Exit code only (0 = pass, 1 = fail).
"""

import pathlib
import sys

from pass_line import report_pass

POOL = pathlib.Path("kernel/lib/intrusive_pool.tkb")
FUNCTION = "private fn intrusive_pool_insert_unchecked"
CLEAR = "if (zero_payload) {"
STAMP = "slot.generation = generation;"


def body(text: str) -> str:
    """The text of insert_unchecked, from its signature to the next fn."""
    start = text.find(FUNCTION)
    if start < 0:
        return ""
    after = text.find("\nfn ", start)
    private_after = text.find("\nprivate fn ", start + len(FUNCTION))
    ends = [end for end in (after, private_after) if end > 0]
    return text[start:min(ends)] if ends else text[start:]


def check(text: str) -> tuple:
    """Return (failure, lines scanned). An empty failure means it holds."""
    span = body(text)
    scanned = len(span.splitlines())
    if not span:
        return (f"{POOL} has no {FUNCTION!r}. The clear-before-stamp order "
                "this checks belongs to that function; if it was renamed, "
                "rename it here too rather than deleting the check.", scanned)
    clear = span.find(CLEAR)
    stamp = span.find(STAMP)
    if clear < 0:
        return (f"{FUNCTION} no longer contains {CLEAR!r}, so nothing clears "
                "a slot's storage before it starts answering Live. A slot's "
                "first payload word is the free-chain link until something "
                "overwrites it (issue #514).", scanned)
    if stamp < 0:
        return (f"{FUNCTION} no longer contains {STAMP!r}, so this check "
                "cannot tell where the slot starts answering Live.", scanned)
    if clear > stamp:
        return (f"{FUNCTION} stamps the generation before clearing the "
                "payload, which is the order issue #514 was filed about: "
                "between the two the pool reports a Live slot whose payload "
                "is the previous occupant's free-chain link, and a lockless "
                "walker reads that link as a payload field.", scanned)
    return "", scanned


def main() -> int:
    if not POOL.exists():
        print(f"FAIL pool-zero-before-stamp: {POOL} is missing",
              file=sys.stderr)
        return 1
    failure, scanned = check(POOL.read_text())
    if failure:
        print(f"FAIL pool-zero-before-stamp: {failure}", file=sys.stderr)
        return 1
    report_pass("pool-zero-before-stamp",
                "intrusive_pool_insert_unchecked clears a slot's storage "
                "before stamping the generation that makes it answer Live",
                lines_scanned=scanned)
    return 0


if __name__ == "__main__":
    sys.exit(main())
