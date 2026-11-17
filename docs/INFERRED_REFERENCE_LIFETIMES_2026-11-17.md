# Inferred reference lifetime review

Baseline: published 52d4017b. Review date: 2026-11-17. This is the scoped
ordinary-helper inference experiment and migration, not completion of the
memory-safety umbrella or a soundness theorem. SPEC.md states the rules.

## Concrete gap and remedy

An unannotated `project(row: &mut Row) -> []u8` could return the inline bytes
of its argument, and `escape()` could return `project(&local_row)`. The
baseline accepts the dangling slice. Adding the explicit checked dependency
rejects it. The inferred summary now provides that dependency without a new
source annotation. Invalid objects were never executed.

The proposer records parameter-origin sets for stable local binding IDs,
result dependencies and possible retention. It follows references, slice
formation, local aliases, aggregate/variant values, branches and calls.
Scalar reads are copied values; an array field converted to a pointer/slice
is a place dependency. Pointer-derived integers keep their origins.
Unknown external/indirect calls are potentially retaining. The existing
body checker validates a proposed contract before acceptance; a missing
proposal is not permission to pass a checked local reference to a retaining
parameter.

Direct reference/slice and non-resource pointer helpers are the automatic
boundary. Existing explicit aggregate contracts remain available and are
not removed by this experiment. Legacy `@` result relations and separately
owned resource results keep their reviewed boundary. They are not inferred
heap-separation or physical guard/backing proofs. A scalar address result
can make an input potentially retaining; numeric conversion does not erase
its dependency. No new runtime field, unsafe block, source annotation,
trusted mint, pool or fallback is added to maintained kernel/native code.

## Why inference terminates

For a function with P parameters and B binding IDs, each binding has a subset
of those P parameter bits. Local propagation only adds bits. There are at
most B*P local additions; the result and retention rows each have at most P
bits. A new iteration allocates no new abstract binding identity.

At program scope, each summary change adds at least one result/retention bit,
so there are at most twice the sum of parameter counts such additions.
A queue initially visits each body, then revisits only registered callers of
a changed callee. Each registered call edge is finite. Recursion uses these
same finite updates; it does not recursively unfold the callee. The local
and interprocedural transfers are monotone joins. This is a termination
argument for this implementation strategy, not a machine-checked proof of
its OCaml implementation or a fixed wall-time guarantee for arbitrary input.
Z3 is not involved in proposing these dependencies.

The maintained regression constructs 1024 caller-before-callee definitions,
with and without a cycle. It checks every final result/retention row and a
linear bound of three visits per function for that fixture. End-to-end
controls through 256 definitions compile live uses and reject escapes.
At 1024, the positive whole compiler hits the older IRQ-mask summary bound
on both baseline and candidate; the lifetime pass is tested independently
rather than raising that unrelated bound or reporting the whole compiler
positive as green.

## Independent controls and coverage

The regressions pair live indexed code generation with local escapes,
recursive and mutually recursive calls, later definitions, branch unions,
independent global results, actual retention, and unknown external calls.
Former retaining-call negatives with empty bodies now actually store the
argument; an empty-body helper has its own inferred non-retention positive.
This preserves a meaningful negative under the newly accepted programs.

A disposable compiler that drops direct-call result origins accepts both
the plain and explicitly annotated dangling-slice controls. The candidate
rejects both. The generated bad objects are not executed. This tests transfer
state independently of Z3 re-checking facts extracted by the same compiler.

The full population build found native diagnostic-ring address helpers where
the proposal missed array-field pointer decay. The independent body checker
rejected the proposal. Preserving that place dependency fixes the inference
without annotating or rewriting those helpers; paired regression controls
cover the raw address boundary and rejection at a local reference boundary.

## Cost and acceptance boundary

No maintained kernel/native annotation is added or removed. Compile time,
allocation and maximum resident memory are compared with the same source
sets and flags, sequentially against baseline and candidate compilers.
The experiment evidence keeps source, commands, statuses and diagnostics.
Final source-bound measurements and image comparison accompany publication.
Single-run wall-time differences are observations, not statistical claims.

The storage workload remains the standard boot and exec/teardown using the
same four exec windows. Normal/debug QEMU and RPi5 images, named writable
symbols, reservation starts and LLVM static frames are compared separately.
This stage adds static inference, not a changed allocator or occupancy
workload. No new Linux/FreeBSD comparison is needed for this boundary.

Inference is intentionally conservative. An unsupported call/storage shape
may require more analysis or an explicit contract; it must be presented to
the maintainer before an annotation migration. No automatic annotation
fallback is enabled. General heap aliases, allocation identity, raw backing,
reclamation, concurrency and compiler soundness remain obligations in the
memory-safety inventory.
