# Stopped scalar store space review

## Boundary and workload

This milestone adds the compiler operation `stopped_store`; it migrates no
kernel consumer or retained storage. The maintained kernel and native sources
are identical between published GREEN3e and the published08d compiler-fix base.
The candidate combines published08d with this operation. No stop/mint/lock,
model action, global classifier, allocator, pool or workload is changed.

Both normal target kernels were actually rebuilt by the candidate compiler.
`STOPPED_STORE_SPACE.json` binds the selected ELF/object hashes to verified
GREEN3e copies and the candidate. The archive was read-only; selected artifacts
were copied and verified against its manifest before inspection. No baseline
rebuild or input-only objcopy was used. Full logs and source/argv bindings are
retained externally under `1159-stopped-store-20261110`.

## Actual linked image and object observations

| Artifact | GREEN3e bytes | Candidate bytes | Observation |
| --- | ---: | ---: | --- |
| QEMU production ELF | 1314888 | 1314888 | Byte-identical |
| QEMU production main.o | 3000424 | 3000424 | Byte-identical |
| RPi5 production ELF | 4736400 | 4736400 | Byte-identical |
| RPi5 production main.o | 6542008 | 6542008 | Byte-identical |
| RPi5 existing debug object | 12105728 | 12106544 | Debug metadata differs |

Exact production equality includes code, data, BSS declarations, unwind,
relocations, symbols, linked image span, `usable_ram_start`, and frame code.
There is no production image, retained-payload, pool metadata or reserved-page
delta, and no claim of newly freed usable pages. Prior occupancy observations
retain only their unchanged allocation/lifetime-workload scope; this compiler
API is not itself a new exercised kernel workload.

The debug object has 10781 allocated sections: each section's type, size and
bytes (or NOBITS size) matches the baseline. Section-size differences are
`.debug_line` +774 and `.debug_str` +43 bytes. The candidate directory prefix
is 43 bytes longer; replacing that prefix in `.debug_str` makes its bytes
identical. Raw section tables and the allocated-section comparison are
retained. These metadata differences are not executable code growth. No new
debug ELF or guest was built solely for this review.

## Operation and trust boundary

The declared-entry AArch64 scalar fixture compiles to an actual indexed
`str` after a GOT address load, with a 16-byte frame in this small fixture.
The GOT `ldr` is not a destination-record read. In-process LLVM controls check
usize/bool/enum stores and reject destination-rooted loads, while allowing
ordinary parameter loads. Checked indices produce no bounds traps; separate
unbounded root/nested-index controls retain two checks, also inside `unsafe`.
This is static compiler evidence, not measured physical cycles, cache
coherence, interrupt latency, or whole-callgraph stack cost.

Only the root foreign-CPU index receives authority from the original bare
borrowed complete MachineStopped parameter. The actual mutable global binding,
inline scalar/enum leaf, ordinary privacy/guarded fields, value refinements and
inner bounds are checked. No pointer, reference, slice, aggregate or reusable
view is returned. The complete-stop mint and protocol remain trusted; this
operation does not prove semantic invariants of arbitrary CPU-state mutations.
Existing stopped_read behavior is unchanged. There are no allowance removals
and no whole-kernel typed-protection completion claim.

## Assessment and next measurement

Adopt the scoped compiler operation with zero measured production-image cost
for the unchanged maintained callers. The first real consumer must review its
actual stop lifetime, iteration/closure and writer contracts, then measure its
linked/frame/storage and workload effects. No physical run was required for
this compile-only API milestone. Physical timing/concurrency claims require
separate real-workload evidence; instruction counts do not supply it.
