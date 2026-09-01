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

## Search for hidden consumers

Before changing what a value means, search for its arithmetic shape, not only
its name: `+ 1`, `- 1`, array indexing, shifts, and small literals may encode
undeclared consumers. Run `make allbuild`; whole-program callers live in
multiple trees and regex surveys miss unanticipated syntax shapes.
