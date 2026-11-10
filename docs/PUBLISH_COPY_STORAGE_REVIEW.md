# Publication-copy temporary storage review

The compiler uses the existing function-entry allocation helper for the
private scalar result of `publish_copy`. The zero reset remains at each
copy site, before the first acquire read; the success write and final load
remain in their existing blocks. The address reaches only those two stores
and one load, never a caller or the copied payload.

## Workload and evidence

Baseline: b95036dffe406fbeb1905e72a74db9ce46da6919. Rebuilt normal and debug
QEMU/RPi5 kernels use the same maintained sources and build options before
and after the correction. `PUBLISH_COPY_STORAGE_REVIEW.json` records the
compiler source hash, all eight before/after object and ELF hashes, section
sizes, changed symbol sizes and image boundaries. Full object instruction
comparison finds only `diagnostic_trace_copy_cpu` changed in each object.

| Artifact | Baseline text | Corrected text | Change |
|---|---:|---:|---:|
| QEMU normal ELF | 822760 | 822728 | -32 |
| QEMU debug ELF | 899316 | 899300 | -16 |
| RPi5 normal ELF | 4207492 | 4207460 | -32 |
| RPi5 debug ELF | 4292880 | 4292848 | -32 |

Data and BSS sizes, all data/BSS symbol sizes, and `usable_ram_start` are
unchanged in all four linked kernels. Code alignment accounts for the
linked deltas differing from the function's byte delta. There is no new
pool, retained allocation or allocator workload, so the existing occupancy
evidence remains applicable; this is an incremental compiler correction.

## Stack boundary

Actual normal `diagnostic_trace_copy_cpu` had a 112-byte initial frame and
an additional 16-byte SP decrement at each executed copy, released only at
function exit. Debug had a 192-byte initial frame and the same repeated
16-byte allocation. The existing eight-iteration loop therefore permits
240/320-byte paths respectively by source and machine inspection. Those
calculations are not a new general stack proof or an observed overflow.

Corrected normal objects reserve a fixed 112 bytes; corrected debug objects
reserve a fixed 192 bytes. Their loop bodies no longer change SP. The
existing frame checker accepts all four objects with its unchanged global
2048-byte ceiling and existing 3312/2640-byte exceptions. This correction
does not establish arbitrary backend-frame completeness, total call-chain,
recursion, interrupt or assembly-stack bounds.

## Regression and recurrence

An in-process AArch64 test uses the real `publish_copy` inside an eight-pass
loop and consumes both sequence and copied payload. It checks one entry
allocation, only the internal stores/load, and a zero reset outside entry.
The old lowering fails specifically on entry placement. The existing native
publication fixture also alternates committed and abandoned writes at one
loop copy site, checking fresh success values, zero failure results and the
retained snapshot through its expected stdout.

The other direct `build_alloca` sites allocate parameters, mutable lets,
mutable patterns and debug-only immutable bindings before generating the
function body. They already execute at entry and require no lifetime change.
The existing entry helper imposes bounded private storage in generated IR;
LLVM lowering remains trusted. A source type error or multicore model would
not repair this compiler insertion-point error. No new language rule,
annotation, model, lane or metadata mechanism is introduced.

Measure again when temporary lowering, kernel storage/allocation workload,
or the next completed kernel feature/layout stage changes this boundary.
