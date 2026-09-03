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

## Proving a range instead of relating two ends

`buf[from..<to]` where `from` and `to` come from separate scans does not
compile: bounds are proved against the slice's compile-time minimum length,
and no relation between two independently computed ends is available. Early
return guards narrow an immutable `let` against a constant; they do not
establish `from <= to`.

Walk the backing array's own static size and treat the parsed range as a
filter over that walk:

```takibi
for position: usize in 0..<STAGING_MAX {
    if (position >= from && position < to) {
        let value: u8 = staging[position];
    }
}
```

Every index is then bounded by the array itself. The relation that cannot be
proved is the one to stop needing. Guard a single dynamic index with an
immediate `if (i < view.len) { ... } else { ... }`, and bind a slice length to
an immutable `let` before comparing, because narrowing is immutable-only.

Use `static_assert` to delete a runtime failure path whose condition is
knowable at compile time, rather than carrying an outcome through a
`must_use variant` that no caller can ever observe. It is checked once per
monomorphized instantiation, so a generic body is checked for each concrete
type that is actually instantiated.

## Accessors over an affine result

A `must_use variant` is affine: consuming it to ask whether an operation
succeeded leaves nothing to ask why it failed. Two single-answer accessors
therefore force every reporting caller to choose one question, which
reintroduces the defect the variant existed to remove. Return every answer one
caller might need from a single call, and keep single-answer accessors only
for sites that genuinely need one. Sites that branch per outcome match the
variant directly.

## Scope an `unsafe` block to the unproven statements

Wrap only a run of statements that are entirely unproven operations
back-to-back, such as constructing one or two checked views and immediately
consuming them. Do not wrap a whole function or loop body because it contains
several unproven sites scattered among safe code; that pulls unrelated,
already-proven operations into the audited region and makes the audit density
disproportionate to the real trust decisions. When a binding must outlive the
block, hoist the independent computation earlier rather than widening the
span.

## Before deleting a clear, and before adding a field

A zeroing step can be redundant for correctness and load-bearing for
disclosure. Ask separately whether any consumer depends on the value, and
whether the storage can be observed by a different owner afterwards. Any
resource that is returned and handed out again -- pages, slots, buffers,
descriptors -- raises the second question. When it applies, move the scrub to
the release path rather than deleting it: that pays only when the resource
actually leaves, and puts the cost on the component that knows the data was
sensitive.

When allocator bookkeeping seems to need a new field, first compute which axis
it scales on -- per object, per page, or per pool -- and look for space already
reserved and unused. A per-object word multiplies; a per-pool word usually does
not; a header with reserved slack may cost nothing at all. Check also whether
one word can do two jobs.

## Diagnostics and verification

Treat compiler-detected invalid or dangerously ambiguous code as an error, not
a warning-based migration. Run the relevant build with `--forbid-trap`, use
`add-takibi-test` when adding coverage, and run `make allbuild` before the first
commit of a compiler-affecting change.
