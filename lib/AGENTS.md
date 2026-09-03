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

Because inter-field alignment padding is emitted as explicit members, a
declared field position is not an LLVM member position. Every path from a
field name to a member index must go through `struct_llvm_field_index`:
`field_info` and its callers, the runtime struct-literal initializer, the
constant struct-literal evaluator, the struct-layout reporter behind
`--emit-struct-layout`, and the DWARF member-offset loop. A new path that
skips the mapping breaks struct literals long before anyone notices an
offset. `alignof` reports the effective alignment rather than the ABI
alignment, because LLVM has nowhere to record a declared `align(N)`, and
alignment propagates outward from a member to its containing struct.

Struct offsets are the ABI; the LLVM member list is not. A by-value argument
is nevertheless lowered from the member list, so materializing padding as
members changes calling conventions while changing no offset. Emit padding
only where it changes an offset. When changing struct lowering, inspect the
emitted argument registers and prologue, not only `sizeof` and `offsetof`.

## Adding a type the compiler did not have

Exhaustiveness checking catches a forgotten case, never a case handled with
the wrong semantics. Two distinct checklists apply.

For a new primitive integer type that deliberately does not unify with an
existing one:

- binary-operation codegen does not thread a type hint to literal operands, so
  a type-specific literal transform must be applied at the operation site, not
  only in the generic literal case;
- range-proving optimizations tied to a specific operator may be sound for
  ordinary integers and unsound for the new type; re-derive each one's
  justification against what the new bit pattern means;
- any "value arrives at a fixed arithmetic width" helper needs the type added
  explicitly, because a wildcard fallback produces mixed-width IR that fails
  only when real code runs;
- compile-time `sizeof` and `offsetof` exist in several independent duplicated
  copies across `parser.mly`, `type_inf.ml`, and `llvm_gen.ml`, and a fix
  applied to one looks complete while the others still reject the type;
- literal materialization likewise has a separate evaluator for global and
  constant initializers. Grep every site that turns a literal into an LLVM
  constant, not only the one already being edited. Comparisons resolve a
  constant back to its literal inline, so a bug here can stay invisible until
  the first assignment of such a constant into a field.

For a new wrapper or pointer-shaped `Ast.type_expr` constructor, check
`type_inf.ml`'s core type matches, which the compiler checks for
exhaustiveness; `llvm_gen.ml`'s `Ast.type_expr` matches, which it does not;
and `monomorphize.ml`'s pre-typecheck generic inference, which works on raw
syntactic shape and is likewise unchecked.

Exercise a new type end to end through a `linux_user/` program, and through
real kernel code when it will appear inside a `packed` struct, rather than
relying on a clean `dune build`.

When unsure whether a new type should unify implicitly, start strict.
Loosening later deletes now-redundant casts incrementally; tightening later is
a simultaneous breaking change across every call site.

Routing a new caller through a shared checking function can let the accepted
program set outpace what code generation supports. Confirm codegen handles
every construct the newly shared path now admits.

When a change to `type_inf.ml` alters what can be proven, add a codegen-level
regression test that consumes the new proof through an index or indexed
assignment, not only through a function call: call arguments read the resolved
type environment directly, while indexing goes through code generation's own
separate re-derivation.

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
