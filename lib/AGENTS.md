# Compiler library

These instructions apply to compiler implementation work under `lib/`.

## Synchronized implementations

`type_inf.ml` and `llvm_gen.ml` independently derive several properties,
including `sizeof`/`offsetof`, literal materialization, and struct field
indexing. A change to one often requires the corresponding change in the
other; `scripts/check_compiler_sync_rules.py` checks declared pairs.

Struct layout has three implementations: `type_layout.ml`, LLVM generation's
size computation, and LLVM DataLayout. Preserve agreement between all three;
`Type_layout.check_against_codegen` rejects divergence.

## Diagnostics

A construct the compiler can establish is invalid, dangerously ambiguous,
redundant at a trust boundary, or contrary to a maintained invariant is a
compile error by default. Do not introduce warnings as a migration mechanism
for in-repository callers. A warning requires a concrete legitimate program
that rejection would exclude and repo-wide evidence that false positives are
understood. Prefer no diagnostic until the analysis is precise enough.

When language behavior changes, update `SPEC.md` in the same change and add
the appropriate compiler tests. Use the `add-takibi-test` skill to select the
test tier.

## Target limitations

- Literal shift amounts are checked against the actual LLVM operand width and
  rejected when out of range. Preserve the narrow-integer widening behavior:
  narrow non-literal operands execute as i32, so literal siblings must not be
  materialized at an incompatible i8 or i16 width.
- `interrupt_wait` and `interrupt_notify` support ARM/AArch64 only. AMD64 and
  RISC-V must reject them until an equally race-free retained-event protocol
  exists; a bare `hlt` or `wfi` is not equivalent.
- RISC-V has no lowering for `dma_prepare_tx`, `dma_prepare_rx`, or
  `dma_finish_rx`. Reject these operations instead of silently lowering them
  to a barrier. AArch64 uses real VA-range cache maintenance.

Language-level limitations belong in `SPEC.md`; historical investigations
belong in `HISTORY.md`, not in this file.
