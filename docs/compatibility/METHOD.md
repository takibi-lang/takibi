# Establishing a contract with external software or hardware

This directory records contracts with pinned external software. This document
records how to establish one, because the ordering of evidence has repeatedly
decided whether an investigation took minutes or days.

## Board and peripheral bring-up

Prefer, in order:

1. **The board's own device tree**, for anything address, routing, clock,
   reset, or board-integration shaped. Board-level integration facts exist
   nowhere else. A Raspberry Pi 5 USB investigation stalled across four
   methodical hardware isolation tests, each ruling out a hypothesis without
   localizing the fault; the answer was a `dma-ranges` property in the board's
   own `.dtsi` stating that the peripheral's bus masters reach system RAM only
   at an offset, and no controller specification could have contained it.
2. **A real driver's source for the same controller.** U-Boot's is often the
   closest match for bare-metal work: polling based, no interrupts, no
   operating-system abstractions. Linux's carries the fullest correctness
   detail.
3. **The formal specification**, mainly for per-bit register field meanings
   that drivers assume without restating.

Specification PDFs are frequently paywalled or blocked, while driver sources
and device trees are freely fetchable. Reaching for the specification first is
usually both the slower and the less informative path.

## Syscall ABI behavior for a pinned userspace binary

Prefer, in order:

1. **The exact pinned version's real source.** This repository pins exact
   package versions, so reading the tagged source is not the slower path. A
   trace proves only what happened in the one run captured; it cannot show an
   unobserved branch, a different option value, or an error path. The source
   shows the actual contract: whether a return value is checked, the exact
   structure layout expected, and every reachable branch for that version.
2. **A live trace, to confirm reachability only** -- whether this binary calls
   this syscall at all -- not as the evidence for correct semantics. A trace
   is only a valid reference when its run conditions match the kernel's: an
   empty environment matters here, because processes receive an empty `envp`
   and a trace taken with a normal environment exercises different paths.
3. **Real hardware**, as final confirmation that the implementation does not
   regress the real integration, not as a substitute for understanding the
   contract first.

A summary of source code produced by an intermediary is not the same as
reading the source. When the exact argument or return-value contract matters,
fetch the file and read it; a paraphrase once asserted the opposite of what
the code did, and a whole scenario was built on it before the file itself was
read.

## Differences from Linux

Resolve a difference from Linux as soon as it is found, because it will
otherwise be forgotten, and "found" has to mean measured. The cheapest
reliable probe is a small program per case, run on this development
container's own Linux, printing the resulting error name. Reasoning about
which error a case produces has been wrong repeatedly where a probe was
decisive in minutes.

Keep the measurement, not only the fix. The probe table belongs in the commit
message, in `HISTORY.md`, and in any issue filed for the parts not done: the
code can be re-derived from the table, and not the other way round. When a
measured difference is too large for the session, file it with the numbers
rather than a prose statement that the behavior differs.
