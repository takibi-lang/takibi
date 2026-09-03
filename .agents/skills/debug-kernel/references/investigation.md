# Investigation techniques

## Intermittent failures

If a previously failing test passes on rerun, do not call it fixed or a flake
without estimating the failure rate. If the observed probability is `p`, the
chance of seeing zero failures in `n` independent runs is `(1 - p)^n`. State the
sample size and uncertainty.

Prefer experiments that distinguish mechanisms: disable the suspect, remove
the proposed mechanism, or add a canary that must fire. A clean repetition
count alone usually eliminates no theory.

Instrumentation changes timing and layout. Record into globals rather than
printing inside the suspect window. A change that merely makes a
perturbation-sensitive reproduction disappear does not verify a fix; measure
the mechanism or invariant directly.

## Work from evidence

- Re-read existing output before generating more. Ask what it would mean if
  the current theory had not already been chosen.
- When one caller fails and another equivalent-looking caller does not, compare
  where they execute and what surrounds them before theorizing about the shared
  operation.
- Instrument the other side of a two-party protocol. A silent peer may have
  received the response after its own timeout.
- Bisect a cheap proxy for the changed invariant rather than repeatedly running
  an expensive QEMU or hardware reproduction.
- Measure an invariant before enforcing it, then deliberately violate the
  proposed bound to prove the counter or assertion is reachable.
- When a fault handler misbehaves while every input looks healthy, suspect
  disagreement between two authorities for the same fact -- the active address
  space root versus the recorded one, a live handle versus a snapshot. Print
  the value through both from the failure site. A counter reporting a valid
  sentinel answers its own question truthfully and a different question
  silently.

## Failures that are not the change under test

Before diagnosing a QEMU lane failure, check it against these. Each was paid
for once; re-deriving one costs a day.

**The guest stops emitting mid-boot on a loaded host.** A lane fails with a
harness diagnosis naming whatever it was still waiting for -- an interactive
HTTPd lifecycle stall, an unobserved ash boundary -- while the UART capture
simply ends part way through the boot, at the same line every time, well
before the driver's deadline. The driver now says which of the two happened:
"the guest then sent nothing for N seconds of its budget -- it stopped rather
than ran late". When it says that, the change under test is not implicated.

What causes it is host CPU saturation, and concurrent runs of the whole suite
are what saturate: measured on 24 cores, twelve concurrent lanes all passed
while three concurrent aggregates failed every lane. `make kernelcheck` and
`make allcheck` take the `suite` lease for that reason, so this should not
arise from ordinary parallel work. If it does, that itself is new evidence.
Add what you observe to the open investigation on GitHub issue #509 rather
than starting again; it carries the reproduction, the measured rates, and the
exact line the guest stops on.

**`records MISSING uses=16 reason=2` on a boot that runs to completion.** A
different failure, tracked separately, and not caused by load: it appears at
roughly one boot in six on an idle host too.

## Suspect the instrument

A truncating or otherwise broken diagnostic reads exactly like a real
measurement: there is no ellipsis and no error, so a formatter that drops
digits reports a live register as zero. Before concluding that hardware is
broken:

- Obtain a second, independent witness. Everything known about a suspect
  register should not have come from that register.
- Treat several independent quantities being wrong in the same direction as
  evidence about the instrument. One broken register does not do that.
- Look for a shape in what printed successfully, such as every correct value
  having the same digit count.
- A capability bound justified as "covers everything this codebase prints" is
  a claim about the whole future, usually written where only part of the
  codebase reads it. When such a bound expires anywhere it has expired
  everywhere; fix every copy or remove the duplication.
- Keep the formatter under a host-native test that needs no board.

## Probing a path that cannot log

The effect system rejects logging inside an `!{interrupt}` function, and a
wedged system parks every process, so the two obvious probes are both gone.
The shape that works is:

1. record the facts into plain globals from the handler, with no logging and
   no allocation;
2. print them from a non-interrupt path that still runs, such as the syscall
   dispatch guarded by a one-shot flag;
3. temporarily patch the test harness so something keeps generating syscalls.

## After a mechanical change appears to have made something slower

"It got slower" is unfalsifiable until the mechanism is named, and it is the
most seductive hypothesis after a large mechanical change. Refute cheap
hypotheses one probe each before believing it, and compare against the last
known-good commit with the same probes applied.

When an array access is replaced by a validated accessor, the cost lands in
the caller, not in the accessor: one compare becomes a tag lookup plus a header
read, which is nothing per call and decisive at millions of calls. Count the
calls at a boot milestone before optimising anything, then fix the scan that
asks too many times rather than the accessor. When a test involves a host-side
peer, instrument the peer; a late response and a missing one look identical
from one side.

## When many view expectations fail at once

After a change to process topology or boot sequence, most failing views are
usually tests whose meaning expired with the topology they were written
against, not regressions. Ask of each one whether the line is missing because
the event is gone by design; if so the expected file is what is wrong.

Capture one boot log and re-run the view comparison offline over all views.
The runner's own loop exits at the first mismatch, so its output reports one
failure when many exist. Mirror its filter and expected selection rule exactly,
platform-specific file over common, or pairing a broad filter with a narrow
expectation manufactures phantom failures. When a marker string changes, grep
the whole repository for it rather than only the expected files: harness
drivers wait on those literals too.

## Search for hidden consumers

Before changing what a value means, search for its arithmetic shape, not only
its name: `+ 1`, `- 1`, array indexing, shifts, and small literals may encode
undeclared consumers. Run `make allbuild`; whole-program callers live in
multiple trees and regex surveys miss unanticipated syntax shapes.
