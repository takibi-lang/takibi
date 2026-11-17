# Inferred reference lifetime review

Implementation: 429795db. Baseline: published 52d4017b. Review date: 2026-11-17. This is the scoped
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


## Final source-bound measurements

Three sequential baseline/candidate pairs per target, same sources and CLI
flags, on the same host. Wall time is the compiler process, not allbuild or
allcheck. RSS is the median of each process's maximum resident set in KiB.

| Target | Median seconds before / after | Median peak RSS before / after, KiB | Allocated OCaml words before / after |
| --- | --- | --- | --- |
| QEMU | 11.60 / 11.69 | 541232 / 545668 | 757793402 / 775415449 |
| RPi5 | 12.82 / 12.97 | 598284 / 599012 | 846333615 / 866045158 |

Wall medians increase 0.8% and 1.2%; RSS medians increase 0.8% and 0.1%.
Allocation increases about 2.3% on both targets and is deterministic over
these three pairs. Wall samples overlap; these are observed costs, not a
statistical latency guarantee. The maintained qemu allbuild invocation
measured 775406715 words, within its unchanged 946000000 ceiling. Its flags
are not silently conflated with the paired CLI invocation's word count.
No compile, solver, lane or timeout ceiling is raised.

| Image | Text | Writable data | BSS |
| --- | --- | --- | --- |
| QEMU normal | 827880 | 4608 | 1310720 |
| QEMU debug | 905252 | 4608 | 1310720 |
| RPi5 normal | 4221044 | 5584 | 1916928 |
| RPi5 debug | 4307232 | 5584 | 1830912 |

Every value above equals the baseline. Normal object/ELF SHA256 hashes match.
Debug objects/ELFs differ in DWARF working-directory paths; after stripping
debug information their complete hashes match. Independently, every allocated
section's bytes, flags, address and size matches in all four images. Named
writable symbols, usable_ram_start and every LLVM static frame match.
The exec pool remains four windows / 8192 bytes with unchanged metadata.
No retained-page or workload-occupancy saving is inferred from image identity.

Frozen implementation validation: make allbuild passed, including all 3170
unit tests, 281 static checks, 37 slow checks, native builds and both kernel
populations. Both debug builds passed. Final clean hardware-inclusive
allcheck is a separate publication gate, not replaced by these observations.
The 1024-case whole-compiler positive limitation is not included as success.

Additional alias controls cover plain and linear result records, parameter
shadowing and local global-store escape. Local addresses are activated when
a safe slice is formed and at a checked result boundary, rather than losing
the dormant source behind a reference alias. Legacy reference-field addresses
use the referenced object, not the local reference wrapper's storage. The
native pointer-decay defect and these local storage cases are excluded
statically; they were not moved to an unsafe or new trusted boundary.
