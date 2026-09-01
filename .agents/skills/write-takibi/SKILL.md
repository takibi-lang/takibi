---
name: write-takibi
description: Write, change, or review maintained Takibi .tkb code in kernel or linux_user, including refinement bounds, checked indexing, unsafe or raw-pointer choices, fallible return types, must_use variants, and forbid-trap compliance. Use before substantial .tkb implementation work. Do not use for OCaml compiler-only changes or historical examples.
---

# Write maintained Takibi code

Read `SPEC.md` for current syntax and semantics. Implement only the concrete
requirement; do not build speculative infrastructure or an interim workaround
that a required larger design will immediately replace.

## No production traps

New `.tkb` code starts with refinement types and `--forbid-trap`. Remaining
bounds checks mean the types or local narrowing are not yet sufficient.

- Use refined parameters and bounds such as `{0..<MAX as usize}` and literal
  or `const`-bounded loops where the range is known.
- Use explicit `if` narrowing immediately before an access when runtime state
  carries an invariant the type system cannot otherwise see.
- Do not replace checked indexing with raw pointers or `unsafe` merely to evade
  a bounds check. Reserve raw pointers for genuine hardware, block-device,
  overlay-cast, or unknown-length boundary requirements.
- Bounds may use literals or earlier `const` names with bare integer literal
  initializers. Ordinary global `let` values are not type-level constants.

A genuinely new peripheral, first-of-its-kind DMA/cache interaction, or new
board's earliest bring-up may need an unrefined working milestone before
hardening. Treat that as an explicit exception: ask when unclear, verify the
hardware behavior first, preserve the baseline commit, then harden the whole
milestone without raw-pointer substitutions.

## Fallible operations

New operations with multiple outcomes return a closed `variant`, not an i32,
bool, or magic-value sentinel.

- Use an `Ok`/`Err` shape for ordinary success or failure.
- Give each meaningfully distinct status its own case.
- Use a value-carrying success case when the operation returns data.
- Use a `Found(value)`/`NotFound` shape for lookup results.
- Mark the variant `must_use` when ignoring the entire result must be a compile
  error, and match or transfer every outcome explicitly.
- A raw integer imposed by a wire or channel boundary may be decoded with a
  primitive-literal `match`; do not invent a parallel enum solely for syntax.

Retrofitting an existing sentinel API is case-specific, but when a concrete
cleanup is already underway, convert all genuinely convertible cases in scope
unless a real boundary requires coordinated redesign.

## Diagnostics and verification

Treat compiler-detected invalid or dangerously ambiguous code as an error, not
a warning-based migration. Run the relevant build with `--forbid-trap`, use
`add-takibi-test` when adding coverage, and run `make allbuild` before the first
commit of a compiler-affecting change.
