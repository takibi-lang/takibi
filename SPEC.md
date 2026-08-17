# takibi Language Specification

This file documents **the current behavior** of the takibi language: types,
syntax, and semantics as they exist today. It is a reference, not a
tutorial or a history.

For *why* the language looks this way -- design rationale, bugs found and
fixed, the chronological engineering log -- see `HISTORY.md`. That file is
allowed to keep growing; this one is not: whenever a language feature
changes, update the relevant section here directly rather than appending a
new one.

No formal BNF grammar is included. The grammar is still evolving quickly
enough that a hand-maintained BNF would fall out of sync faster than it
would be useful; `lib/parser.mly` is the authoritative grammar. This file
describes behavior in prose instead.

File extension: `.tkb`. Compiler invocation: `takibi <file1.tkb>
[file2.tkb ...] [-o out.o] [--target <triple>] [--cpu <cpu>] [--features
<features>] [-g] [--forbid-trap] [--forbid-unsafe] [--version]`. Multiple `.tkb` files are
concatenated (flat global namespace) before compilation -- there is no
module/import system beyond `use` (see "Known Limitations" below).

`-g` emits full DWARF debug information for source-level debugging. The
current implementation prioritizes practical GDB value inspection, so it
may preserve extra debug-only storage compared with an optimized build
without `-g`.

The implementation still has a Hindley-Milner-style inference core for
ordinary values, but the language is no longer a pure HM type system:
refinement intervals, effects, affine/linear ownership, static indices,
file privacy, and authority-region checks add Takibi-specific static
semantics on top.

Every top-level definition -- `fn`, global `let`, `struct`, `opaque
struct`, and `enum` -- shares this ONE flat namespace, deliberately.
Unlike C (which has a separate TAG namespace for `struct`/`union`/`enum`,
reached only via the keyword, e.g. `struct Foo`, distinct from the
"ordinary identifier" namespace functions/variables/typedefs share) or
Rust (which has a separate TYPE namespace for struct/enum/trait from the
VALUE namespace for fn/static/let), takibi's model is closer to Zig's:
one identifier, one meaning, no keyword needed to disambiguate which
namespace a bare name refers to. Two top-level definitions sharing a
name is a compile error regardless of which KIND each one is, which one
is defined first, or which of the two (or more) files each comes from
-- `struct Foo {...}` colliding with `fn Foo() {}`, `enum Foo {...}`,
`opaque struct Foo;`, or `let Foo` are all rejected the same way a
`struct`/`struct` or `let`/`let` collision is. The one exception:
`fn`/`fn` sharing a name is fine when the parameter types genuinely
differ (a valid overload, see "Function Pointers, extern fn, and
Overloading" below) -- only an identical name+signature pair, or a
function colliding with a non-function kind, is rejected.

## Design Principle

In embedded targets, an unhandled runtime trap (`brk`/Synchronous Abort on
AArch64) is not an acceptable failure mode. takibi's type system exists to
turn as many potential traps as possible into compile-time errors instead:

- `i32` (or any bare, unrefined integer type) means "range unknown" (MMIO,
  external/wire input, etc.) -- indexing or casting with it gets a runtime
  check. This is correct, not a compiler weakness.
- `{lo..<hi as base}` means "range and representation are known" -- if the
  compiler can prove the access is in range, no check is generated at all.
- `--forbid-trap` (see below) turns "no proof exists" into a compile
  error, for code that is meant to ship.

## Types

`bool`, `i8`, `i16`, `i32`, `i64`, `u8`, `u16`, `u32`, `u64`, `isize`,
`usize`, `void`, `*T`, `io T`, `*io T`, `[T; N]`, `[]T` / `[T; N..]`
(slice), `fn(T...) -> R`, `Name` (struct or enum), `{lo..<hi as base}`
(refined integer subtype), `T @ n` (runtime integer or pointer singleton), and
`Name[n]` (indexed affine/linear runtime struct or erased view).

`addr` is a reserved checker-only static sort, not a runtime type. It may
appear as a static parameter sort (`lock: addr`) but not as a variable, field,
parameter value, or top-level declaration name.

- **`isize` / `usize`** are pointer-sized signed/unsigned integers. Their
  LLVM width follows the target's actual pointer size via LLVM
  DataLayout: 64 bits on AArch64/RISC-V64, 32 bits on Cortex-M/STM32
  (falls back to 64 bits when no target machine is configured, e.g. in
  unit tests). `usize` represents addresses, lengths, and non-negative
  sizes; `isize` represents relative pointer offsets and pointer
  differences. There is no implicit coercion between them or into/out of
  fixed-width integer types -- use `as`.
- **`*T`** is a regular, non-volatile pointer. **`io T`** is a
  volatile-qualified value type (same LLVM representation as `T`). **`*io
  T`** (`= *(io T)`, i.e. `TypePtr(TypeIo T)`) is a volatile MMIO pointer.
  See "MMIO / Volatile" below.
- **`[T; N]`** is a fixed-size array. It decays to `*T` when used as an
  ordinary expression (e.g. passed to a function), and can only be
  *declared* at local or global scope, never as a function parameter type
  directly.
- **`[]T` / `[T; N..]`** is a slice: a fat value (`{ptr, usize}` pair)
  carrying a compile-time-known *minimum* length. `[]T` means "minimum 0,
  length unknown at compile time"; `[T; N..]` means "at least N elements,
  guaranteed". See "Slices" below.
- **`fn(T...) -> R`** is a function pointer with unknown call effects.
  **`fn !{}(T...) -> R`** is explicitly non-blocking and
  **`fn !{may_block}(T...) -> R`** may block. LLVM 19 has a single opaque
  pointer kind, so signatures and effect contracts are checker-only; every
  form is the same runtime `ptr`.
- **`{lo..<hi as base}`** is a refined integer subtype: a value of type
  `base` statically known to lie in `[lo, hi)`. See "Refined Integer
  Types" below. The bare form `{lo..<hi}` (no explicit `as base`) is
  rejected -- the base must always be spelled out. Refined ranges follow
  interval containment: `{a..<b as T}` is a subtype of `{c..<d as T}`
  when `[a,b)` is contained by `[c,d)`.

## Literals

- Integer literals: decimal and hex (`0x...`). Internally stored as
  `Int64.t` (a full 64-bit bit pattern, not OCaml's 63-bit native `int`),
  so a bare `0xFFFFFFFFFFFFFFFF` is representable and means exactly that
  bit pattern -- which signed/unsigned interpretation applies depends on
  the type the literal ends up unified with, not on the literal itself.
  An integer literal used directly in a context with a known expected
  type (a `let` annotation, a `return`, a function argument, an
  assignment, a struct/array literal field) is generated directly at that
  type's width; otherwise it defaults to `i32` if it fits in
  `0..0x7FFFFFFF`, `i64` otherwise.
- Character literals: `'a'`, `'\n'`, `'\r'`, `'\t'`, `'\0'`, `'\\'` --
  desugared to an integer literal (`Char.code c`).
  Array/slice indices and subslice bounds use `usize` exclusively; bare
  literals infer as `usize` in these positions. Raw-pointer indices and
  raw-pointer slice bounds use `isize` exclusively (signed pointer
  displacement); bare literals infer as `isize` there.
- String literals: `"..."`, with `\n` `\r` `\t` `\0` `\\` `\"` escapes. Can be
  cast directly to a slice (`"..." as []u8`): the compile-time byte
  length (NUL excluded) becomes the minimum.
- Comments: `// line comment`, `/* block comment */`.

## Statements

- `let x = e` / `let x: T = e` -- immutable binding (initializer
  required, no reassignment, `&x` is a compile error).
- `let mut x = e` / `let mut x: T = e` -- mutable binding (reassignment
  allowed).
- At **global** scope: `const NAME: IntType = INTEGER_LITERAL;` declares
  a named compile-time integer constant, where `IntType` must be one of
  the primitive integer types (`i8`/`u8`/.../`isize`/`usize`). It is the
  only user declaration form recorded for type-level integer positions
  such as array sizes, refined integer bounds, and compile-time-proven
  `for` bounds. No pointers, `io`, arrays, structs, `sizeof`/`offsetof`
  values, forward references, or constant folding are supported here; use
  a global `let` for those runtime constants.
- At **global** scope: plain `let NAME: T = e;` is an immutable runtime
  global (reassignment and `&NAME` are compile errors, and it must have
  an initializer); `let mut NAME: T = e;` is a mutable global variable.
  `let mut x: T;` (no initializer) is allowed at global scope, relying on
  BSS zero-clearing.
- `let mut x: T;` (no initializer) is *also* allowed at **local** scope,
  for any `T` including scalars, arrays, and structs -- unlike the global
  case, the initial content is undefined (whatever was already on the
  stack), not zero-cleared. Useful for a scratch buffer/struct about to be
  fully overwritten by the next few statements (e.g. a sector-sized `[u8;
  512]` about to be filled by a block-device read, or a struct about to be
  populated field-by-field) where a throwaway initializer would just be
  immediately discarded work.
- `let mut x: T align(N);` -- N-byte-aligned global or (GitHub issue #27)
  **local** variable (N must be a power of two; not enforced by the
  compiler beyond an LLVM assertion at codegen time). Optional initializer
  (`let mut x: T align(N) = e;`). Local alignment requires `mut`: an
  immutable local is an SSA value with no memory location for LLVM's
  alignment attribute to attach to, unlike a global (always memory-backed
  regardless of mutability). An explicit `align(N)` on a variable of a
  type may use either an integer literal or an earlier compile-time integer
  `const`. The compiler-supplied `DMA_CACHE_LINE` constant is also available:
  32 on the STM32F7 profile and 64 on AArch64. It is reserved and cannot be
  redefined by source code. An explicit `align(N)` on a variable of a struct
  type with its own `align(M)` (see "Structs" below) overrides that
  struct's alignment for this one variable. Typical use: a stack-resident
  DMA buffer that must never share a cache line with unrelated data (a
  cache-line invalidate on an unaligned buffer can silently discard
  adjacent live stack data -- see `examples/common_stm32/sdmmc.tkb`'s
  `disk_read` contract and `examples/align/align.tkb` for the local form).
- **`*align(N) T`** -- a pointer PROVABLY a multiple of N bytes (GitHub
  issue #102), the pointer analogue of a refined integer's
  `{lo..<hi as base}`. `align(N)` sits between the pointer sigil and the
  pointee type (Zig-style), distinct from the `let ... align(N)` variable
  syntax just above, which this type's proof sources build on:
  ```
  fn touch(p: *align(32) u8) { ... }

  let mut buf: [u8; 128] align(32);
  touch(buf);                        // OK: buf's own name is *align(32) u8
  touch(&some_align32_scalar);       // OK: &x on an align(N) variable
  touch(0x1000 as *align(32) u8);    // OK: literal address, 0x1000 % 32 == 0
  touch(buf + i * 32);               // OK: offset provably a multiple of 32
                                      //     (i's own value does not matter)
  touch(some_plain_ptr);             // compile error: unproven
  touch(unsafe { some_plain_ptr as *align(32) u8 });  // OK: marked unsafe
  ```
  - **Proof sources**: `&x` or an array's own bare name, when `x`/the array
    was declared `align(N)` (or a stricter multiple of N); a literal
    address cast (`LITERAL as *align(N) T`, checked against N directly);
    pointer arithmetic `aligned_ptr + offset` (or `-`) when `offset` is
    provably a multiple of N -- a compile-time literal or named constant
    (`Const_env`-resolvable, e.g. `idx * BUF_SIZE` the same way a for-loop
    bound or `Mul`'s own range propagation already resolves named
    constants), or a sum/difference of two such provable multiples;
    `unsafe { ... as *align(N) T }` for everything else. Deliberately NOT
    a general symbolic/congruence solver -- an offset built from anything
    else (a bare non-constant variable, a function call, multiplying two
    non-constant operands) simply does not prove alignment, and
    `aligned_ptr + unproven_offset` silently DECAYS to a plain `*T`
    (not an error) rather than requiring `unsafe`, the same way refined
    integer arithmetic elsewhere in this language loses a tight range
    without erroring when it can't keep one.
  - **Subtyping**: `*align(N) T` is usable anywhere a plain `*T` is
    expected (always-safe widening); usable where `*align(K) T` is
    expected when `K` divides `N`; a plain `*T` (or an insufficiently
    aligned `*align(K) T`) used where `*align(N) T` is required is a
    compile error pointing at the proof sources above and `unsafe` as the
    escape hatch.
  - **Element-stride proof** (Stage 2): `aligned_array + i` for ANY
    integer `i` (not just a provable multiple of N) stays `*align(N) T`
    when the pointee is a struct declared with its own `align(M)` where
    `M` is a multiple of N -- struct `align(M)` tail-pads `sizeof` to `M`
    (see "Structs" above), so GEP's per-element stride is itself always a
    multiple of N regardless of the index. This is what proves
    `eth_rx_descs + i` in `examples/common_stm32/eth.tkb`'s real DMA
    descriptor ring (`EthDmaDesc` is `align(32)`), distinct from the
    literal/named-constant offset proof above (which reasons about a byte
    OFFSET, not an element TYPE's own size).
  - **Scope still open**: a struct FIELD read through an `align(N)`
    struct is not automatically proven (only the struct's own instances/
    array elements are); general symbolic congruence beyond literal/
    named-constant multipliers and this element-stride rule remains out
    of scope. See `examples/align_ptr_proof/align_ptr_proof.tkb` for a
    worked example and HISTORY.md's issue #102 entries for the full
    design history, including Stage 2's retrofit of
    `examples/common_stm32/sdmmc.tkb`'s `disk_read` (no longer needs its
    own bounce buffer) and every real caller reaching it through
    `examples/common/fat12.tkb`.
- **Undetermined types are a compile error, not a silent `i32` default.**
  If nothing pins a bare `let`/`let mut`'s type (no annotation, and no
  later use that determines it), the compiler rejects it rather than
  defaulting to `i32`. Add an explicit `: T` annotation.
- `while (cond) { ... }`.
- `for i in lo..<hi { ... }` / `for i: T in lo..<hi { ... }` -- see "For
  Loops" below.
- `for x in slice_expr { ... }` -- element iteration over a slice; see
  "Slices" below.
- `return e` -- returns a value from a non-void function.
- `return;` (GitHub issue #153-adjacent fix) -- bare early return, legal
  only inside a function with no declared return type (void). A bare
  `return;` inside a value-returning function is a compile error ("bare
  `return;` requires a void return type... use `return e;`"). Ordinary
  linear/affine consumption rules still apply at a bare `return;` exactly
  as at any other return: every linear value live at that point must
  already be consumed on that path.
- `break` / `continue` -- exit/continue the innermost `while`/`for(-in)`
  loop. Compile error outside a loop. For `for`, `continue` increments
  the counter first.
- `if (cond) { ... }`, `if (cond) { ... } else { ... }`, `if (cond) { ...
  } else if (cond) { ... } else { ... }`. `if`/`else` is a **statement
  only** -- there is no if-expression/ternary form (`let x = if (c) {a}
  else {b};` is a syntax error). Assign a `let mut` from each branch
  instead: `let mut x: T = default; if (c) { x = a; }`.
- **`cond` (in `if`/`while`, and both operands of `&&`/`||`) must be
  `bool`** -- no C-style implicit int-truthy coercion. `while (1) { ... }`
  and `if (0) { ... }` are compile errors ("condition must be bool -- a
  bare integer literal has no boolean value"), matching Rust/Zig rather
  than C; write `while (true) { ... }` / `if (x != 0) { ... }` instead. A
  concretely-typed non-bool value (e.g. `if (x)` where `x: i32`) is
  likewise rejected ("cannot unify i32 with bool"). The same rule applies
  anywhere else a bare integer literal flows into a `bool`-typed target
  (`let x: bool = 1;`, `return 1;` from a `-> bool` function, passing a
  literal for a `bool` parameter) -- all rejected the same way.
- Assignment: `x = e`, `*p = v`, `arr[i] = v`, `s.field = v`. Compound
  assignments `+=` `-=` `|=` `&=` `^=` `<<=` `>>=` desugar to `x = x op
  rhs` and are supported on all five assignable forms above (`*p`,
  `*(expr)`, `arr[i]`, `s.field`, and a plain variable).
- `match expr { arms }` -- see "Enums" below.

## Expressions and Operators

- Arithmetic: `+` `-` `*` `/` `%`. Comparison: `<` `>` `<=` `>=` `==`
  `!=`. Logical: `||`, `&&` -- both operands and the result are `bool`
  (see the `cond` rule under "Statements" above).
  Bitwise: `~` (unary NOT), `>>` (right shift -- arithmetic/sign-extending
  for signed types, logical/zero-extending for unsigned), `<<`, `&`, `|`,
  `^`. Both operands of a bitwise op must be the same integer type.
- Unary minus (`-expr`) desugars to `BinOp(Sub, IntLit 0, expr)` in the
  parser; no separate AST node.
- `expr as T` -- explicit cast: integer widths (including `isize`/
  `usize`), `*T -> usize`, `usize -> *T`, `*T -> *U`, refined-type
  coercions (see below). A cast to a *bare* (non-refined-syntax) target
  infers the tightest refined type on its own whenever the source
  expression's range is already known and fits `T`'s representable range
  -- e.g. `ihl as usize` behaves exactly like `ihl as {20..<21 as usize}`
  when `ihl` is already `{20..<21 as u16}`, with no explicit range to
  restate. A source range that does NOT fit `T` (a genuine narrowing/
  truncating cast) falls back to a plain unrefined `T`, discarding the
  range with no error, same as an UNPROVEN source always has. This
  inference is local only -- it never crosses a function boundary, so
  function parameter/return types and global `let` declarations still
  require an explicit `{lo..<hi as base}` annotation when a refined type
  is wanted there.
  Pointer-to-fixed-width-integer casts (`*T as i32`) are a compile error;
  only `*T as usize` and `*T as *U` are allowed (`(ptr as usize) as i32`
  makes the truncation explicit).
- `sizeof(T)` -- compile-time size of `T` in bytes, type `usize` (a
  fixed type, not a polymorphic literal -- compare/assign against another
  integer type needs an explicit `as` cast). Reflects `packed`/`align(N)`
  layout correctly (reads the same LLVM DataLayout used for struct
  codegen). Cannot be used in an array-size position (`[T; sizeof(Foo)]`)
  -- array sizes resolve in the parser, before struct layout exists.
- `offsetof(StructName, field)` -- compile-time byte offset of `field`
  within `StructName`'s actual layout, type `usize`. Same DataLayout
  -based resolution as `sizeof`; same "not usable in an array-size
  position" restriction.
- Function call, `*expr` (dereference), `&ident` (address-of; taking the
  address of an immutable *local* variable is a compile error, but
  `&global_var` is always allowed since globals are always mutable
  storage). `&` only accepts a bare variable or a struct field (`&s`,
  `&s.field`) -- `&arr[i]` (address of an array/slice *element*) is a
  compile error ("& requires a variable or struct field"); index into a
  pointer already obtained from the array/variable instead (e.g. `let p:
  *T = arr; ... p[i] ...`, since an array decays to `*T` when used as an
  ordinary expression).
- `min(a, b)` / `max(a, b)` -- compiler builtins (reserved names; defining
  a user `fn`/`extern fn` with either name is a compile error). Clamp a
  value's provable range: `min(x, LITERAL)` proves an upper bound of
  `LITERAL` regardless of `x`'s own range; `max(x, LITERAL)` proves a
  lower bound, similarly. When both arguments have a known bound, the
  tighter combined range is proven; an unconstrained operand falls back
  to a wide (but not unsound) sentinel range.
- `checked_add_usize(a, b)` / `checked_mul_usize(a, b)` -- reserved
  compiler builtins for native-width unsigned arithmetic. Both operands
  must be `usize`, and the program must declare the standard result shape
  `must_use variant CheckedUsize { Value(usize); Overflow; }` (the
  reusable declaration is in `examples/common/checked_usize.tkb`). The
  operation returns `Value(result)` when representable and `Overflow`
  otherwise; it never wraps silently and never emits a trap. Matching the
  result is exhaustiveness-checked like any other closed variant.
  Declaring `CheckedUsize` as `must_use` (see "Closed Variants and
  Existential Owners" below for the general `must_use` mechanism) means
  an entirely ignored result is already a compile error today, the same
  all-path consumption check every other `must_use variant` gets -- not
  separate design work.
- `unsafe { expr }` -- see "unsafe" below. Also accepts a statement list,
  `unsafe { stmt* }` (GitHub issue #315) -- see "unsafe { stmt* }" below.

### Operator Precedence

Low to high: `||` < `|` < `^` < comparison < `&` < `as` < `+`/`-` < `>>`
`<<` < `*` `/` `%` < unary (`~` `-` `*` `&`).

Notably different from C: `&` (bitwise AND) binds **tighter** than
comparison, so `n & mask == 0` means `(n & mask) == 0` (this avoids a
well-known C footgun). `^` and `|` are looser than comparison, matching
C. `%` shares precedence with `*`/`/`.

## Structs

```
struct Name { field: type; ... }             // plain struct
struct packed Name { field: type; ... }      // no inter-field padding
struct Name align(N) { field: type; ... }    // every instance/array element aligned to N
struct packed Name align(N) { ... }          // both
struct packed be Name { field: u16; ... }    // packed + auto-promote u16/u32 fields to u16be/u32be
struct packed be Name align(N) { ... }       // packed + be + align, all three
opaque struct Name;                          // incomplete type, pointer-only
affine opaque struct Name;                   // opaque + ownership-handle semantics, see below
affine struct Name[n: usize] { field: T; }   // indexed runtime owner
linear struct Name[n: usize] { field: T; }   // indexed runtime obligation
```

- `let mut s: Name;` -- struct variable (local or global; a struct
  variable is always mutable storage regardless of the `let`/`let mut`
  keyword used to declare it, matching how array variables work).
- `s.field` -- field read (works uniformly whether `s: Name` or `s:
  *Name`, Zig-style).
- `s.field = v` -- field write (direct dot-assignment to a bare variable
  name; not valid as the left side of a larger expression). `arr[i].field
  = v` also works (bounds-checked element GEP, then field GEP);
  `ptr[i].field = v` on a raw pointer skips the array bounds check. The
  reverse nesting is **not** supported: `s.field[i] = v`, assigning into
  an indexed array/slice *field* reached through a struct (value or
  pointer), is a syntax error -- only whole-field assignment (`s.field =
  whole_array`) or reading the field to pass/index elsewhere (`let p: *u8
  = s.field; p[i] = v;`) work.
- `&s` -- address of a struct variable, type `*Name`.
- **A field's declared `type` may itself be a refined `{lo..<hi as
  base}`** (GitHub issue #100), e.g. `struct Name { idx: {0..<8 as
  usize}; }`. A read (`s.field`, including through `s: *Name`, an array
  element `arr[i].field`, or repeated reads of the same field) carries
  that proven range forward exactly like a refined local or parameter,
  usable directly as an array index or passed to an exact-match refined
  parameter with no runtime check. A write (`s.field = v`, a struct
  literal's positional field value, or an assignment through a pointer)
  is checked the same way as any other refined-typed target: an
  already-proven value or a compile-time constant that fits `{lo..<hi}`
  is accepted with no runtime check; an unproven runtime value is
  rejected at compile time (narrow it first, e.g. `if (v >= lo && v <
  hi) { s.field = v; }`); a compile-time constant that does NOT fit is a
  compile error, not silently truncated.
- **`opaque struct Name;`** has no constructible value, fields, or size
  -- usable only behind a pointer. Intended for driver-owned state
  handles the application never inspects directly. Two distinct opaque
  types never unify with each other, even though both are represented
  identically (a bare pointer) at the LLVM level -- opaque handles are
  nominally typed, not structurally.
- **`packed`** removes inter-field padding: use for protocol headers and
  MMIO register maps where layout must match hardware/wire format
  exactly. **`packed be`** additionally auto-promotes eligible fields to
  `u16be`/`u32be` (see "Endian-Aware Integer Types" below) -- pure sugar,
  not a distinct mechanism.
- **`align(N)`** (N a power of two) aligns every variable and every
  element of a `[Name; K]` array of that struct type to N bytes, with
  tail padding automatically appended so `sizeof(struct) % N == 0`. Use
  for DMA descriptor rings, cache-line-separated data, SIMD types.
- **A struct field of pointer type is rejected unless that pointer is
  already structurally incapable of forgery** (GitHub issue #240): `*T`,
  `*align(N) T`, or `*io T` is a compile error there unless `T` is an
  affine or linear opaque struct -- the one pointee kind that already
  unconditionally rejects arithmetic, indexing, dereference, and cast-
  away regardless of where the pointer value lives, so storing it in a
  field hides no more than storing it in a local already would. `*io T`
  used to be exempt, pending issue #316's MMIO scoping decision; #316
  extended this rule to `*io T` too (same reasoning: `*io T` supports
  the identical arithmetic/indexing as ordinary `*T`, so a `*io T` field
  can hide the same ownership hazard via a paired, unenforced length
  field). An ordinary raw-pointer field (`buf: *i32` alongside a
  separate, unenforced length field) is exactly the hazard this rejects
  -- use a slice (`[]T`, which bundles and enforces the length itself)
  or an owned array field instead. For individually named hardware
  registers previously grouped into one struct purely for cross-file
  type sharing, use separate module-level `*io`-qualified globals
  instead (`examples/common_qemu/gic_regs.tkb`'s migration is the
  reference example). A single, large, OFFSET-CONSISTENT register block
  is unaffected either way: that is a `*io Struct` POINTER VARIABLE
  (`let regs: *io BigRegBlock = ...;`, see "MMIO / Volatile" below for
  its own already-checked field-offset access), not a struct field, and
  this rule only governs pointer types stored INSIDE another struct's
  fields.

## Indexed Runtime Owners

The implemented Slice 1 subset supports first-class runtime owners whose
types retain erased static integer identities:

```takibi
private linear struct SlotLease[n: usize] {
    private idx: {0..<4 as usize} @ n;
}

fn slot_lease(idx: {0..<4 as usize} @ n) -> SlotLease[n] {
    let mut lease: SlotLease[n] = { idx };
    return lease;
}

fn slot_read(lease: borrow SlotLease[n]) -> i32 {
    return slots[lease.idx].value;
}

fn slot_unlease(lease: sink SlotLease[n]) {}
```

- A static parameter is declared in brackets on an `affine struct` or
  `linear struct`. Slice 1 supports primitive integer sorts only and requires
  at least one static parameter.
- `T @ n` is a runtime integer `T` with the compile-time equality "this
  value is `n`". It has exactly the same LLVM representation as `T` and
  preserves any refinement range already carried by `T`; for example,
  `{0..<4 as usize} @ n` proves both identity and array bounds.
- When `T` is a pointer, `T @ place` instead relates that pointer to a static
  value of sort `addr`. It has the same pointer representation as `T`; the
  address identity is checker-only. Pointer singletons are used by the
  indexed lock guards described below.
- `Name[n]` has the declared struct fields at runtime. Its static arguments
  do not add fields or ABI words. Unbound static names in function signatures
  are implicitly universally quantified and instantiated freshly per call.
- Integer literals have their literal static identity. Reusing one immutable
  runtime variable preserves one hidden rigid identity; two independent
  unknown runtime expressions receive distinct identities. Slice 1 does not
  equate computed expressions by arithmetic reasoning.
- Field projection substitutes actual static arguments for the declaration's
  formals. Thus `lease.idx` above retains both `{0..<4 as usize}` and the same
  `n`, so indexing emits no bounds trap under `--forbid-trap`.
- `borrow Name[n]` is non-consuming and `sink Name[n]` is the designated
  terminal consumer. In Slice 1 both are runtime aggregate parameters passed
  by value; the mode changes ownership checking, not ABI representation.
- Moving a value transfers its affine/linear obligation. A borrowed owner
  cannot be returned or passed to a consuming parameter as a second owner.
  An owned call result must be bound, returned, or passed directly to an
  owning consumer; it cannot be discarded or borrowed as an untracked
  temporary. Indexed owners must be initialized, and assigning over a live
  one is rejected for both affine and linear kinds.
- `borrow` and `sink` may wrap only the complete parameter type, not a tuple
  component or another nested type. Owner fields are writable only through a
  mutable local or parameter, and singleton-typed fields can receive only the
  same static identity.
- `private` on the owner and private fields enforce smart construction and
  accessor APIs across source files. Casts cannot mint or launder indexed
  owners.
- Constructing an owner creates a new ownership obligation. Slice 1 does not
  require a pre-existing permission to do so, so a private constructor is part
  of the trusted implementation of an external-resource invariant. `linear`
  checks every value that was minted; by itself it does not prove that the
  declaring module never mints two `SlotLease[n]` values for the same `n`.
  A later erased-view/permission slice supplies that stronger constructor
  precondition.
- Until storage/place tracking is generalized, indexed owners may occur only
  as local values, parameters, returns, and components of value tuples. They
  cannot be addressed, cast, placed behind pointers, or stored in globals,
  fields, arrays, or slices.
- To prevent mutation through a widened pointer from invalidating an integer
  `T @ n`, singleton values cannot be addressed or placed in globals,
  ordinary struct fields, pointer targets, arrays, or slices. A direct field
  of an indexed owner is the supported persistent carrier in this slice. The
  outer pointer singleton spelled `*T @ place` is a pointer value, not a
  singleton stored behind that pointer.

Static address/enum sorts, explicit universal or existential syntax,
`where`/propositions, erased `view` values, mutable borrowing, and SMT/prover
integration are not part of Slice 1.

## Affine Values (Optional Ownership)

```
affine opaque struct Token;

fn make() -> *Token { ... }
fn inspect(t: borrow *Token) -> usize { ... }   // non-consuming
fn release(t: sink *Token) { ... }               // consuming, and the designated terminal consumer

fn good() {
    let t: *Token = make();
    inspect(t);      // OK: borrow does not consume
    inspect(t);       // OK: still not consumed, may be borrowed any number of times
    release(t);        // consumes t
    // release(t);     // would be a compile error: "affine value 't' was already consumed"
    // inspect(t);     // likewise, after release
}

fn may_drop() {
    let t: *Token = make(); // OK: affine permits weakening
}
```

`affine` has its standard structural meaning: **contraction is forbidden,
weakening is allowed**. A value may be moved at most once, but it may be
dropped without a terminal call. Use `linear`, not `affine`, when every
path must release, close, answer, or forward a resource.

The kind applies uniformly to opaque handles, indexed runtime-owner structs,
erased views, tuples, and variants. A tuple or variant takes the strongest
kind of any component/payload (`linear > affine > unrestricted`).

An opaque struct still has no fields or size. Real per-instance state cannot
live in `*Token`; a driver using that representation must keep it elsewhere.
Resources whose runtime identity matters use an indexed runtime owner such as
`SlotLease[n]`, `NetRxCpuOwned[desc]`, or `FatFile[file]`, whose private
runtime fields travel with the ownership permission.

`affine opaque struct Name;` marks pointers to that type (`*Name`) as
affine handles. It statically rejects use after move and double move while
allowing deliberate abandonment.

- A function parameter of plain affine-pointer type (`t: *Name`, no
  `borrow`/`sink`) **consumes** the argument: after such a call, using the
  same local variable/parameter again anywhere in the function (another
  call, a `return`, another consuming use) is a compile error ("affine
  value 'NAME' was already consumed"). A `return` of the affine value
  itself consumes it, exactly like passing it to a consuming parameter,
  when the function's own return type is affine.
- **`borrow T`** -- valid **only** as a function parameter type, where `T`
  is an affine/linear opaque pointer, indexed owner, or erased view. Calling through a
  `borrow *Name` parameter does **not** consume the argument, so it may
  be borrowed an unlimited number of times before (or without ever)
  being consumed. The `*Name` spelling shown here is the opaque-handle case.
- **`borrow mut T`** -- valid only for an affine/linear indexed runtime-owner
  parameter. It grants scoped exclusive mutation without consuming ownership.
  A call argument must be a bare mutable local/parameter; use
  `Case(mut owner)` for a variant payload. The same place cannot also occur in
  another argument of that call, and a shared-borrow parameter cannot be
  forwarded as mutable. The scope ends when the direct call returns.
- **`sink T`** -- has the same parameter-only/kinded-type restriction.
  Unlike `borrow`, it consumes at the call site. For affine values it is
  an explicit API marker for terminal intent; for linear values it also
  exempts the callee from forwarding the received obligation.
- **Weakening**: affine locals and plain affine parameters may leave scope
  unused. An uninitialized affine local is legal. Assigning over a live
  affine value drops it; assigning to a binding whose prior value was moved
  reinitializes that binding. None of these permissions allow a moved value
  to be read or moved again.
- **Bit opacity**: an ownership-bearing value cannot be cast to an integer,
  pointer, or any other type, including inside `unsafe`. A cast would
  detach its permission from resource tracking. Fallible ownership uses a
  closed variant instead of a null sentinel.
- **Loop restriction**: consuming an affine/linear value that was declared
  *outside* a loop (`while`/`for`/`for-in`) from *inside* that loop's
  body is conservatively rejected at compile time ("cannot consume an
  affine/linear value declared outside a loop inside that loop"), since a real
  loop could otherwise consume the same handle on more than one
  iteration. A handle both declared and consumed inside the same loop
  iteration is fine. A `let mut` handle reassigned to a fresh value on
  every iteration (e.g. `examples/common/sync.tkb`'s `cond_wait`
  drop-and-reacquire pattern, `g = cond_wait(seq, g, m);` inside a
  `while`) is also fine: reassignment clears the variable's consumed
  status, so the loop-restriction check never sees it as "consumed
  inside the loop" in the first place.
- **`if`/`else` and `match`**: moving an affine handle in only one branch
  is allowed because the other branch may weaken it. After the branch, the
  value is conservatively treated as "possibly consumed", so a later use is
  rejected even on the runtime path that did not move it.
  A branch/arm that always `return`s on every one of its own paths is
  excluded from this union: it can never reach the code after the
  enclosing `if`/`match`, so what it consumed does not carry forward.
  This is what lets `if (cond) { release(t); return -1; } return
  release(t);` compile with no `else` needed -- the two `release(t)`
  calls are on mutually exclusive paths, and the checker can now see
  that syntactically (`Return`, an `If` where both branches return, a
  `Match` where every arm returns, and `Block` are recognized as
  terminating; anything else, including loops, conservatively is not,
  falling back to the plain union above).
- **Deliberately restricted, not a general place/borrow checker**: current
  flow tracking is function-local. Indexed owners and variants therefore
  remain direct locals, parameters, and results rather than values stored
  in globals, arrays, or arbitrary nested places.
- **Struct-field tracking (OWNERSHIP_KERNEL.md Stage 3a, GitHub issue
  #89 Hurdle 3)**: `h.t` -- one level of field projection through a bare
  local/parameter `h` -- is tracked exactly like a bare variable would
  be, when `h`'s field `t` has an affine pointer type. This closes a real
  hole: before Stage 3a, storing an affine handle in a struct field was
  legal but completely untracked (double-consuming the same field
  compiled with no error). Any deeper or less direct access
  (`f().t`, `arr[i].t`, `h.a.b`) still falls outside tracking -- these
  have no stable syntactic identity in the current place analysis.
  Two different local variables of the same struct type are always
  distinct paths (keyed by name, not a resolved address). LINEAR fields
  stay banned outright (see "Linear Opaque Structs" below) -- extending
  linear's all-paths guarantee through fields is a larger future step.

## Linear Opaque Structs (Obligations)

```
linear opaque struct PendingEvent;
```

The stronger sibling of `affine` (OWNERSHIP_KERNEL.md Stage 1, GitHub
issue #117): a linear value is an obligation that must be consumed
**exactly once on every control-flow path**. Use linear when dropping the
value must be impossible. Current runtime-owner examples include
`NetRxCpuOwned[desc]` and `FatFile`; `PendingTcpEvent`, `MutexGuard`, and
`KGuard` use the erased linear-view representation described below.

Consumption events are the same three as affine (pass as a plain
non-`borrow` argument, pass to `sink`, return it), and `borrow`/`sink`
parameter modes work identically. Everything else is stricter:

- **All-paths consumption**: at every scope end, branch merges use
  intersection, not union -- `if (c) { discharge(t); }` with no `else`
  discharge is a compile error ("consumed on some paths but not on every
  path"). Consuming differently per branch/arm is fine; every branch/arm
  must consume.
- **Early exits**: a pending (not definitely consumed) linear value at a
  `return`, `break`, or `continue` is a compile error. (The
  break/continue rule is deliberately conservative: it also rejects a
  pending obligation declared outside the loop -- restructure, or avoid
  break, if it fires.)
- **No cast-away**: as for affine, casting a linear value to anything
  (`t as usize`, `t as *Other`) is a compile error with no `unsafe`
  escape. Minting an opaque handle
  (integer -> `*L`) follows affine's existing rules (literals fine,
  computed values need `unsafe`) and may be restricted to a private
  declaring file.
- **No storage**: a linear value cannot be stored into a struct field,
  array/slice element, global, or through a pointer, and `&t` is
  rejected -- all of these would escape the function-local tracking
  (later place/storage work may lift selected cases).
- **No silent overwrite**: assigning over a linear variable whose
  obligation is undischarged is a compile error; the self-transform
  idiom `t = transform(t);` stays legal because the right-hand side
  consumes the old obligation first. A linear `let` must be initialized
  at its declaration. Once discharged, a mutable binding may be
  reinitialized with a fresh linear value.
- **Plain linear parameters** promise consumption on every path of the
  callee (the signature is a binary contract: `borrow` = never consumes,
  plain/`sink` = always consumes; "conditionally consumes" is
  deliberately inexpressible).

Matching a linear variant consumes the outer package and creates a fresh
obligation for the selected payload. That payload must be discharged in its
arm. See `examples/linear_obligation` (positive) and
`examples/linear_never_consumed`, `linear_branch_missed`,
`linear_cast_discard`, `linear_overwrite`, and
`variant_linear_payload_missed` (compile-error companions).

## Erased Affine/Linear Views (Takibi Core Slices 2, 6, and finite-state dispatch)

An erased view is a compile-time permission or obligation with no runtime
payload:

```
private linear view PendingEvent;

fn accept_event() -> PendingEvent {
    return view PendingEvent;
}

fn inspect_event(p: borrow PendingEvent) {}  // non-consuming
fn finish_event(p: sink PendingEvent) {}     // terminal consumer

fn dispatch() {
    let pending: PendingEvent = accept_event();
    inspect_event(pending);
    finish_event(pending);
}
```

Slice 2 introduced non-indexed `affine view Name;` and `linear view Name;`.
`view Name` explicitly mints a value. If the declaration is `private`, only
expressions in the declaring file may mint it; other files may name, receive,
borrow, forward, and sink it. A non-private view can be minted wherever it is
visible. Minting is a trusted assertion: the compiler checks the subsequent
affine/linear flow, not whether an external event really occurred.

Slice 6 adds integer-indexed views and universal view change:

```takibi
private linear view SlotWrite[slot: usize, state: u8];

fn begin(index: {0..<2 as usize} @ slot) -> SlotWrite[slot, 0] {
    return view SlotWrite[slot, 0];
}

fn write(permission: sink SlotWrite[slot, 0],
         index: {0..<2 as usize} @ slot,
         value: u8) -> SlotWrite[slot, 1] {
    slots[index] = value;
    return view SlotWrite[slot, 1];
}
```

Static parameters may use a primitive integer sort, an exhaustive enum, or
the checker-only `addr` sort. Enum constants are qualified, for example
`TcpConn[conn, TcpState::Listen]`; a non-exhaustive enum cannot be a finite
static sort. Enum static terms are nominal, so cases from two enum types do
not unify merely because their runtime discriminants are equal. Static names
in a function signature are implicitly
universally quantified and instantiated freshly at each call. The example's
one `slot` therefore ties the erased permission to the runtime singleton
index without a separate proof argument. Arity, literal range, static sort,
identity, and state are checked; `SlotWrite[0, 0]` cannot authorize an access
through index 1 or enter a transition requiring state 1. `view Name[args]`
is the indexed mint expression. A declaration with static parameters cannot
be named or minted without all of its arguments.

Views use the same resource-flow rules as other kinded values. A plain
parameter takes ownership, `borrow` does not consume, `sink` is a terminal
consumer, and returning a view moves it to the caller. A `linear view` must be
consumed exactly once on every path, including early exits. A function whose
result is a view must explicitly return on every path. A producing call cannot
be used as a discarded expression. An `affine view` may be weakened but may
not be used after it has been moved.

The representation rule is strict:

- a view has no fields, size, alignment, address, null value, or integer/pointer
  cast;
- it cannot appear in a global, struct field, array, slice, tuple, pointer, or
  function-pointer type, nor be stored indirectly;
- direct local bindings, direct function parameters, and direct function
  results are the supported positions;
- LLVM omits view parameters and their call operands, lowers a view result to
  `void`, and allocates no local or debug storage for a view.

Thus `fn f(p: sink PendingEvent, n: i32) -> PendingEvent` has runtime ABI
`void f(i32)`. Source evaluation order and runtime side effects of calls are
preserved even when their view inputs/results erase.

`MutexGuard` and `KGuard` are address-indexed linear views. Their lock pointers
remain explicit runtime arguments, while lock/unlock balance and pointer
identity are checked in Delta/Phi without a forged null pointer, runtime
guard result, guard parameter, alloca, or debug value:

```takibi
private linear view MutexGuard[lock: addr];

fn mutex_lock(m: *i32 @ lock) -> MutexGuard[lock] !{may_block} {
    sem_wait(m);
    return view MutexGuard[lock];
}

fn mutex_unlock(g: sink MutexGuard[lock], m: *i32 @ lock) {
    sem_post(m);
}
```

For pointer types, `T @ lock` is an erased address identity rather than an
integer-value equality. At a call site the first address slice recognizes
these stable syntactic forms:

- repeated `&name` and `&name.field...` expressions in one function share a
  rigid identity;
- repeated use of one immutable pointer binding shares that binding's hidden
  identity;
- different syntactic paths are different identities. The checker does not
  resolve aliases, dereferences, indices, or pointer arithmetic back to an
  original place;
- assigning a base binding invalidates identities for its field projections.
  Taking the address of a pointer binding does the same because a callee may
  rebind it through the resulting pointer-to-pointer;
- unsupported pointer expressions receive a fresh identity, so failure to
  prove equality is conservative rather than an alias claim.

The singleton annotation and `addr` term erase. Both lock and unlock retain
one ordinary runtime pointer, and the guard contributes no ABI operand or
result. `examples/mutex_guard_identity_wrong` demonstrates rejection of a
guard acquired from one mutex and passed with another.

An indexed view may be the direct body of an outermost variant-payload
`exists`. A closed variant can therefore retain a runtime state tag while
each case carries an erased, state-specific permission:

```takibi
enum TcpState: u8 { Listen; SynRcvd; }
linear view TcpConn[conn: usize, state: TcpState];

variant TcpConnDispatch {
    Listen(exists conn: usize. TcpConn[conn, TcpState::Listen]);
    SynRcvd(exists conn: usize. TcpConn[conn, TcpState::SynRcvd]);
}
```

Matching consumes the dispatch package and opens a fresh connection identity
with the case's exact static state. Every arm must preserve, transition, or
sink that linear view. The variant's tag remains at runtime; the existential
binder, view payload, connection identity, and enum static state all erase.
The HTTP server's private `tcp_conn_dispatch` is the exhaustive bridge from
its runtime `ConnState` byte into this package. `examples/tcp_conn_view` is
the focused executable state-dispatch fixture;
`tcp_conn_state_wrong` and `tcp_conn_dispatch_missed_wrong` fix the state and
all-path obligation failures.

Explicit `forall`, direct/general existential types outside variant payloads,
propositions, and solver discharge are not implemented. See
`examples/common/http_conn_state.tkb` for the non-indexed
`PendingTcpEvent` use and `examples/indexed_view` for integer-indexed view
change.

## Closed Variants and Existential Owners (Takibi Core Slice 3)

`variant` declares a closed tagged sum. Unlike a numeric `enum`, it may
carry a payload and its value is represented by a runtime tag plus runtime
payload storage:

```
variant FatOpenResult {
    Error(i32);
    Opened(exists file: usize. FatFile[file]);
}

fn consume(result: FatOpenResult) -> i32 {
    match result {
        FatOpenResult::Error(err) => { return err; }
        FatOpenResult::Opened(file) => {
            fat_close(file);
            return 0;
        }
    }
}
```

A case has either no payload or exactly one directly supported payload.
An unrestricted ordinary concrete struct may be copied as a payload. A tuple
may be used as that one payload, including a linear tuple of indexed owners;
this is the aggregate-owner-transfer form used by the VM scheduler. Arrays,
direct nested variants, and structs containing affine/linear fields are still
rejected. Construct a case with `Name::Case` or
`Name::Case(expr)`. A payload-bearing arm must bind its
payload, and a payload-less arm must not. A closed match without `_` must
cover every case; duplicate cases are rejected. A wildcard is allowed for
unrestricted or affine variants, but not for a linear variant because it
could hide a mandatory payload obligation.

A function returning a variant must explicitly return one on every
control-flow path; there is no implicit zero/default package.

Prefix a declaration with `must_use` when dropping the whole outcome must be
a compile error:

```
must_use variant FatIoResult {
    Ok;
    Err(i32);
}
```

Every produced value of a `must_use variant` must be matched, returned, or
moved into another directly tracked binding or parameter on every control-flow
path. A discarded call result, an unmatched local at scope exit, handling on
only one branch, overwriting a pending result, and reusing an already handled
result are compile errors. A function parameter of this type carries the same
all-path obligation. This policy is checker-only and does not change the
variant's runtime representation or claim that the status owns a linear
runtime resource; payload kind and ownership continue to follow the ordinary
rules below. Matching (including a wildcard arm where otherwise permitted)
counts as handling the outer result.

The variant's kind is the strongest kind among its payloads. Matching a
kinded variant consumes the package. The selected payload then becomes a new
arm-local value with the same affine/linear rules as if it had been returned
directly. In particular, every arm that opens a linear payload must consume
it on every path. A payload binder is immutable by default; write
`Case(mut payload)` when it must be passed to `borrow mut`.

An existential payload hides a static identity while retaining its runtime
owner:

```
private linear struct NetRxCpuOwned[desc: usize] {
    private index: {0..<8 as usize} @ desc;
    private len: i32;
}

private affine view NetRxCanAcquire;

variant NetInitResult {
    Failed;
    Ready(NetRxCanAcquire);
}

variant NetRxAcquire {
    None(NetRxCanAcquire);
    Acquired(exists desc: usize. NetRxCpuOwned[desc]);
}

fn net_rx_acquire(ready: sink NetRxCanAcquire) -> NetRxAcquire;
```

Several identities may be hidden by nested outer binders when one payload
transfers a tuple of owners:

```takibi
variant SchedulerVmState {
    Empty;
    Running(exists core: usize. exists a: usize. exists b: usize.
            (CpuLease[core], VmLease[a], VmLease[b]));
}
```

All `exists` binders erase. Matching opens every binder as a distinct rigid
identity, then binds the tuple as one linear value. Destructuring consumes the
tuple and creates one obligation per linear component; every component must be
consumed on every path. Existentials remain restricted to variant payloads.

Constructing `Acquired(owner)` packages the owner's static index without
adding runtime data. Matching `Acquired(frame)` opens the package with a
fresh rigid identity known only through `frame`'s inferred
`NetRxCpuOwned[desc]` type. Accessors can use that identity implicitly:

```
fn net_rx_len(frame: borrow NetRxCpuOwned[desc]) -> i32 {
    return frame.len;
}

fn net_rx_release(frame: sink NetRxCpuOwned[desc]) -> NetRxCanAcquire { ... }

private linear struct NetTxInFlight[desc: usize] {
    private index: {0..<8 as usize} @ desc;
    // Backends may retain additional completion state, such as a TX slot.
    private tx_index: isize;
}

fn net_transmit(frame: sink NetRxCpuOwned[desc], len: i32)
    -> NetTxInFlight[desc] { ... }
fn net_tx_complete(in_flight: sink NetTxInFlight[desc])
    -> NetRxCanAcquire !{may_block} { ... }
```

The two current Ethernet backends intentionally allow one CPU-owned RX frame
at a time. Successful initialization creates the private affine
`NetRxCanAcquire` permission. `net_rx_acquire` consumes it: `None` returns a
replacement, while `Acquired` replaces it with the linear descriptor owner;
only `net_rx_release`, or TX completion after consuming that owner, restores
the permission. The
permission is affine because abandoning future acquisition is safe, but it
cannot be copied or reused after move. The owner is linear because returning
an active descriptor to DMA is mandatory. This prevents duplicate owner
minting; the added permit contributes no runtime payload to either result
variant. A private runtime initialization flag supplies the trusted base case:
on the current single-threaded boot path, only the first successful `net_init`
can mint the initial permission. Failed device discovery or link setup leaves
the flag clear and may be retried. Concurrent initialization is not guaranteed
without a future atomic/lock invariant.

`net_transmit` consumes the RX owner and returns immediately with a distinct
`NetTxInFlight[desc]` owner. QEMU transmits the in-place reply and therefore
keeps the RX descriptor until completion. STM32 copies the reply to a
dedicated TX buffer and re-posts the RX descriptor before starting TX, which
lets RX DMA absorb new traffic while TX is in flight. In both backends a
caller can no longer satisfy the API with an unrelated raw pointer or release
the consumed owner. `net_tx_complete` consumes the in-flight owner, waits for
the retained TX descriptor, re-posts the RX descriptor on QEMU, and restores
the acquisition permission. Under the current ABI the static `desc` erases.
STM32 retains its selected TX descriptor index, while QEMU's fixed descriptor
zero needs only the RX index. The current examples complete directly after
starting TX, but there is a real interval after `net_transmit` returns in
which only the in-flight owner exists.

The slice returned by `net_rx_frame` is separately tied to `desc` by its
region-annotated return type. Consuming the RX owner, whether for release or
TX start, invalidates later use of that slice in the caller.

Two independently opened packages receive distinct identities. They cannot
be passed to a function requiring the same static index merely because their
runtime values happen to be equal. This is the B1/Core property that an
index hidden at an API boundary can later constrain refinement and ownership
operations without threading a loose runtime index through call sites.

### Runtime representation

The current Slice 3 ABI is explicit but provisional:

- the first field is an `i32` case tag, numbered in declaration order;
- each runtime-bearing case contributes one typed aggregate field, also in
  declaration order;
- payload-less cases, erased-view payloads, and existential erased-view
  payloads contribute no field;
- an `exists` binder is erased, but its indexed owner's ordinary runtime
  fields remain;
- normal target alignment and padding apply, and `sizeof(VariantName)`
  observes this layout.

For example, `NetRxAcquire` retains the tag plus
`NetRxCpuOwned`'s `{index, len}` runtime aggregate; `desc`, the singleton
equality, range proof, and linear obligation have no separate runtime field.
A variant whose only payload is an erased view lowers to the tag alone, so
`NetInitResult` is tag-only and `NetRxAcquire::None` adds no payload field.
Full source-level tagged-union DWARF metadata and a compact union ABI are
deferred; code must not treat this first implementation as a stable C ABI.

### Slice 3 limits

This slice intentionally implements only the shape needed by the current
examples:

- variants are concrete named types, not generic `Option[T]`/`Result[T,E]`;
- each case has at most one payload; unrestricted ordinary concrete structs
  are supported by value, while arrays, indexed owner structs, and structs
  containing affine/linear fields are not;
- `exists n: StaticSort. T[n]` is legal only as the outermost case payload.
  `StaticSort` is `addr`, a primitive integer, or an exhaustive enum, and the
  body must directly package an indexed runtime owner or indexed erased view;
- there is no explicit `forall`; static names in function signatures remain
  implicit universals;
- plain variants may additionally be fields of ordinary structs and may be
  copied through those fields. A linear variant has only the private stable
  owner-slot exception described below; variants cannot otherwise be nested
  in arrays/slices, tuples, pointers, other variants, or direct globals;
- variants cannot be addressed or cast, and payload schemas cannot contain
  `borrow`/`sink`;
- existential opening occurs only through `match`.

These restrictions keep ownership tracking honest while general place
tracking, quantifiers, and solver/prover integration remain future Core
slices. Slice 4 adds the narrow mutable-owner borrow described below. The
copy-channel increment lifts only the plain struct-payload and ordinary-field
storage restrictions; the stable owner-slot increment adds the one sealed
linear-variant exception described below. Real positive uses are
`NetRxAcquire` in the QEMU and
STM32 Ethernet drivers, `FatOpenResult` in FAT12, and `TcpConnDispatch` in
`examples/tcp_conn_view`. `http_server_sdcard_rtos` additionally uses a
private `SdRequestChan` whose slot copies the plain
`Init | ReadChunk(SdReadChunkRequest) | FileSize(*u8)` variant under its mutex.
This replaces the former multi-channel pointer-to-`usize` request encoding;
the response remains the existing `i32` rendezvous channel. Focused failures live in
`examples/variant_linear_payload_missed`,
`variant_existential_identity_wrong`, and
`variant_nonexhaustive_wrong`, plus the two `tcp_conn_*_wrong` fixtures; each
source explains the rejected rule in English.

## Stable Owner Slots and `stable_replace`

A stable owner slot is the implemented narrow exception to the general ban on
linear values in durable storage. It is declared as a private ordinary-struct
field whose direct type is a linear variant:

```takibi
linear struct OwnerMessage[id: usize] {
    private id: usize @ id;
    private value: i32;
}

variant OwnerSlotValue {
    Empty;
    Full(exists id: usize. OwnerMessage[id]);
}

struct OwnerChan {
    private mutex: i32;
    private full: i32;
    private value: OwnerSlotValue;
}

private let mut owner_chan: OwnerChan;
```

The first variant case must have no payload. Stable containers are
zero-initialized globals without an explicit initializer, so declaration-order
tag zero is the empty state. The container itself must be a `private let mut`
global, OR a fixed-size array of one (`private let mut slots: [OwnerChan; N];`
-- GitHub issue #158): each array element is then its own independently
stable_replace-able slot, addressed by a runtime index (`&slots[i].mutex`,
`slots[i].value`), with the same-container check below verified structurally
(both operands must index the SAME variable, e.g. `i`, not merely the same
array). A stable owner container -- bare or arrayed -- cannot be local,
passed or returned by value, assigned as a whole, or contained in a slice,
tuple, variant, or another struct (including as a struct field of array
type). Passing a pointer to its stable global location is supported.

The owner field cannot be read, assigned, or addressed directly. Its only
operation is the reserved compiler builtin:

```takibi
stable_replace(guard, &container.mutex, container.value, replacement)
```

It requires exactly four operands. `guard` is a bare variable whose type is a
linear erased view carrying exactly one `addr` index. The second operand must
be the address of an ordinary field, and its static place identity must equal
that guard index. The mutex field and registered stable owner field must have
the same syntactic container base; aliases and unrelated containers are
conservatively rejected. For an arrayed container this base identity check is
purely structural: `slots[i].mutex` and `slots[i].value` are the same
container exactly when both spell the same index expression (itself a bare
variable, or a field/index chain rooted in one, e.g. `slots[i].mutex` and
`slots[i].value` match but `slots[i].mutex` and `slots[j].value` do not) --
this proves the two occurrences observe the same call-site value, not that
any particular runtime index is involved, and it is re-checked (not cached
past a reassignment) if the index variable is written between the guard's
own construction and the `stable_replace` call. `replacement` has the owner
field's linear variant
type. It is moved into the slot and the previous value is returned. The
returned linear variant cannot be discarded: it must be placed in an owning
binding, returned, or matched, after which the usual all-path rules apply to
every payload. `stable_replace` borrows rather than consumes the guard.

The LLVM operation is one typed load of the old aggregate followed by one
typed store of the replacement. The guard, static indices, and existential
binders erase; there is no pointer/integer ownership encoding. The explicit
mutex address contributes no ownership representation. The operation is not
a hardware atomic primitive.

This invariant remains intentionally limited. It statically seals the owner
field, makes every transfer explicit and linear, and associates the exchange
with the same-container lock address carried by the guard. It does not prove
that the guard-producing function actually acquired a runtime lock or that a
private runtime flag is equivalent to the variant tag. Those remain trusted
module obligations. `examples/rtos_demo` provides the positive
ownership-bearing rendezvous; the focused failures are
`examples/stable_owner_without_guard_wrong` and
`examples/stable_owner_result_dropped_wrong`, plus
`examples/stable_owner_wrong_lock_wrong` for cross-lock exchange. The arrayed
form's own positive/negative coverage (GitHub issue #158) lives inline in
`test/test_takibi.ml` rather than as separate `examples/` fixtures (a full
codegen-through-LLVM-IR-verification positive case, plus mismatched-index,
stale-index-after-reassignment, local-array, and struct-nested-array
negatives) -- `examples/el0_shell/el0_shell.tkb`'s own per-page
copy-on-write fd/page table is the first real consumer.

## Scoped Mutable Owner Borrows (Takibi Core Slice 4)

`borrow mut` exposes the caller's indexed runtime-owner place for one direct
call. It is distinct from ownership transfer and from an erased view:

```takibi
private linear struct FatFile[file: usize] {
    private dir_index: {0..<16 as usize} @ file;
    private cursor: u32;
    private size: u32;
}

fn fat_read(fp: borrow mut FatFile[file], buf: *u8, n: u32) -> i32 {
    fp.cursor = fp.cursor + n;
    return 0;
}

fn read_then_close(name: *u8, buf: *u8) {
    match fat_open(name, FA_READ) {
        FatOpenResult::Opened(mut fp) => {
            fat_read(fp, buf, 64);
            fat_close(fp);
        }
        FatOpenResult::Error(err) => {}
    }
}
```

At runtime an indexed owner is its ordinary aggregate with all static indices
erased. A shared `borrow` currently passes that aggregate read-only by value;
`borrow mut` instead lowers to a pointer to the caller's owner storage, so
field writes are visible after return. It adds no runtime token, index, or
borrow object. `FatFile[file]` uses this representation for its directory
index, cluster/cursor, size, and write mode, allowing simultaneous open files
without `ff_*` singleton globals.

This is intentionally not a general borrow checker: projections and
temporaries cannot be mutably borrowed, borrows cannot escape a direct call,
and indexed owners still cannot live in arbitrary storage.

## Blocking, Unsafe, Interrupt, and Exception Effects

Checker effects are written after the return type:

```takibi
extern fn sem_wait(s: *i32) !{may_block};
fn mutex_lock(m: *i32 @ lock) -> MutexGuard[lock] !{may_block} { ... }
fn raw_bytes(p: *u8) -> []u8 !{unsafe} { return unsafe { p[0..<16] }; }
fn IRQ_Handler() !{interrupt} { acknowledge_irq(); }
fn Sync_Handler() !{exception} { dispatch_sync_exception(); }
fn poll_callback() !{} { acknowledge_irq(); }
```

`may_block` is inferred transitively through resolved direct calls. An
explicit annotation is therefore an API contract and a seed, not a required
annotation on every caller. `interrupt` marks a root whose complete reachable
direct-call graph must not contain `may_block`; `interrupt_wait()` is
intrinsically blocking. Diagnostics include one offending call path.

`unsafe` records unchecked memory reasoning. Every function that directly
contains an `unsafe { ... }` expression must declare `!{unsafe}` -- a local,
self-declaration-only requirement at the definition site, not a required
annotation on every caller. Reachability through resolved direct calls is
still inferred for `fn !{unsafe}(...)` callback-contract compatibility (a
function reaching unsafe cannot satisfy a callback slot whose own row omits
it) and for the function's own reported effect list, but an ordinary
explicit effect row on a *caller* (`!{may_block}`, or a bare `!{}`) no
longer rejects a call path that reaches unsafe code -- unlike `may_block`/
`interrupt`/`exception`, which are real control-flow/concurrency hazards a
caller's own reasoning must compose with, `unsafe` here means only "one
bounded, local proof was done by hand," and mandating it propagate through
every explicitly-contracted caller does not scale in code that touches
MMIO/syscalls/interrupts constantly (see HISTORY.md's 2026-08-15 entry
reversing this). `--forbid-unsafe` remains the opt-in, whole-program
"reject if unsafe is reachable anywhere" mode for a subtree that wants
that stronger guarantee.

`noreturn` is currently a trusted extern-only contract. A call to such an
extern terminates control-flow analysis, and LLVM receives the corresponding
function attribute. Takibi functions and function-pointer rows cannot claim
it yet; this narrow surface models the reviewed assembly fail-stop without
pretending arbitrary Takibi loops are proven not to return.

`exception` marks a synchronous-exception handler root. Like `interrupt`, it
is a declaration role rather than a callable function-pointer effect, and an
extern function cannot claim it because there is no Takibi body to check.
Its complete reachable call graph must be non-blocking and must not contain an
effect-unknown indirect call. It also must not call, directly or transitively,
itself or any other `exception` root. This gives handlers a statically checked
non-reentrant contract; ordinary helper recursion remains legal when it does
not lead back to an exception root.

The RPi3 COW example makes handler installation explicit with a linear
`ExceptionRegistration[core]` supplied once by the privileged boot-entry ABI.
`exception_handler_install` consumes it and returns the installed-handler
lifetime owner. Both structs have private fields in the VM module, so ordinary
Takibi application files can receive and move the capabilities but cannot mint
one. This is a source-level capability protocol over the statically linked
exception symbol; it adds no dynamic handler table.

Its stable COW resource cell is CPU-indexed at the access boundary.  The
erased `CowSlotGuard[core, lock]` carries both the CPU identity delivered by
the exception-entry ABI and the stable cell's address identity.  Every take
and put operation requires the same `core` singleton; `stable_replace` still
uses the guard's one `addr` index to authorize the concrete slot exchange.
This keeps the current one-cell/core-0 implementation honest without putting
linear owner variants in an array or pretending a multicore cell allocator is
already needed.

Taking a stable cell returns its direct linear variant state together with a
CPU-indexed linear vacancy owner.  Returning the successor state requires
consuming that vacancy; abandoning any handler path is therefore a compile
error.  Takibi permits the required transient direct tuple of
the form `(Variant, LinearOwner)` in function parameters, locals, and return
values.  This does not permit variants behind pointers or inside arrays,
slices, structs, function pointers, or nested tuples.  The tuple's joined
linear kind makes both components ordinary all-path obligations.

The COW handler returns `ExceptionResume[elr]`, a linear one-word owner whose
singleton payload is constructed only from its incoming saved ELR. Assembly
compares that word with the frame's saved `ELR_EL2` before `eret`. An
unhandled fault instead calls the trusted `!{noreturn}` assembly fail-stop, so
it cannot manufacture a resume outcome or reach a normal Takibi return.

Slice 5 adds explicit call-effect contracts to first-class function types:

```takibi
let mut uart_rx_handler: fn !{}() -> void;

fn uart_set_rx_handler(handler: fn !{}() -> void) !{} {
    uart_rx_handler = handler;
}

fn USART1_IRQHandler() !{interrupt} {
    uart_rx_handler();
}
```

The row follows `fn` in a function-pointer type so it cannot be confused
with the enclosing function declaration's postfix row. No row means
**unknown**, not non-blocking. `!{}` is a checked non-blocking contract;
`!{may_block}` permits blocking and `!{unsafe}` permits unchecked memory
reasoning. `interrupt` and `exception` are declaration
roles and are not legal in a function-pointer row.

A callback's actual effects must be a subset of the destination contract. A
non-blocking callback may therefore enter a `may_block` slot, but the reverse
is rejected. An unannotated Takibi function cannot enter a `fn !{}(...)`
slot until its declaration states `!{}`; that assertion is checked against
its complete body/call graph. An extern without `may_block` remains a trusted
non-blocking contract.

Indirect calls use their function-pointer row during transitive effect
analysis. An unannotated function pointer remains effect-unknown and is
rejected below `!{interrupt}` or `!{}`. Effect rows cannot be invented with a
cast, and are invariant behind writable pointers so an alias cannot replace a
non-blocking callback with a blocking one. Effects still erase completely:
they add no LLVM parameter, field, instruction, or metadata.

## File-Granular Privacy (`private`)

The file is takibi's module and trust boundary (GitHub issue #108,
OWNERSHIP_KERNEL.md Stage 2): a narrow, human-reviewed file can force
everything outside it to go through its functions. `private` appears in
three places, all checked at compile time against the referencing
expression's own source file, with zero runtime/layout footprint:

```
private let mut conn_state: ConnState = ConnState::Listen;   // global
private linear opaque struct PendingTcpEvent;                // opaque type
private linear view EventPending;                            // erased view
struct Chan { private mutex: i32; ... }                      // struct field
```

- **Global**: every reference (read, write, index, slice, address-of) to
  a `private let` global must come from its declaring file.
- **Opaque type** (any kind: plain/affine/linear): value CONSTRUCTION --
  any cast whose target type mentions the name (`0 as usize as *T`,
  `&x as *T`) -- must come from the declaring file. NAMING the type stays
  legal everywhere (annotations, parameters, passing values through), so
  other files can hold and relay handles; they just cannot forge them.
  The declaring file's functions are the only source.
- **View**: `view Name` / `view Name[args]` minting must occur in the
  declaration's file. Naming and moving the erased permission across files
  stays legal, like opaque handles; only the explicit production site is
  private.
- **Struct field**: reading (`s.f`, `&s.f`), writing, and `offsetof` on a
  `private` field must come from the struct's declaring file; so must
  constructing the struct via a struct literal when it has ANY private
  field (a positional literal writes every field). Non-private fields of
  the same struct stay freely accessible. This is what turns the accessor
  idiom (a getter taking `borrow KGuard`) and smart constructors
  (`chan_init` establishing Chan's rendezvous invariant) from convention
  into guarantee.

Two related hardening rules apply (OWNERSHIP_KERNEL.md Stage 2 Part C,
as superseded by Slice 3):

- **Pointer arithmetic/indexing on a pointer to any opaque struct is a
  type error** (`t + 1`, `t[i]`): an opaque type has no size, and for
  affine/linear handles the arithmetic result would be a second tracked
  value conjured without consuming the first.
- **Casting any affine/linear value away is rejected**, including inside
  `unsafe`. Closed variants are the supported Option/Result-shaped
  encoding; null-sentinel ownership is no longer sanctioned.

Known limitation: these checks (opaque handle/view minting, struct field
privacy) are by name/type identity, not by resolved binding, so a local
parameter/let of the same name in a DIFFERENT file could in principle be
misidentified the same way private globals' own check once was (GitHub
issue #214, 2026-08-15, fixed for private globals specifically -- see
HISTORY.md -- a local binding of any kind now shadows a same-named
private global from another file instead of triggering a false-positive
privacy violation; the opaque-handle/view/struct-field checks above were
not part of that fix and may still have the same false-positive gap in
principle, unconfirmed). The declaring file itself remains the trusted
island regardless -- privacy narrows the audit surface to that file, it
does not verify the file's own bodies.

## Tuples

```
(T1, T2, ...)         // tuple type, 2+ components
(e1, e2, ...)         // tuple literal
let (a, b) = e;       // destructuring -- the ONLY elimination
```

Function-local product values (OWNERSHIP_KERNEL.md 5.9, GitHub issue
#120): legal as return types, parameter types, and local `let`
annotations; a bare (untyped) `let (a, b) = e;` also works when `e`'s
type is already concrete (e.g. from a function call whose return type is
annotated). Rejected everywhere storage would be involved: struct fields,
array/slice elements, globals, behind a pointer (either direction), and
casts (to or from a tuple). At least 2 components (`(x)` stays plain
parenthesized grouping, not a 1-tuple). Nesting is allowed at the
type/value level (`(i32, (i32, i32))`), but destructuring itself is not
recursive -- unpack one level per `let`, then destructure the inner tuple
with a second `let`.

**Kind = join of component kinds**: a tuple containing an `affine` or
`linear` component is itself that kind, and inherits every relevant rule
(for `linear`: all-paths consumption, no cast, no storage, no overwrite
while live) at the granularity of the tuple variable -- not per
component. This is what makes returning `(data, obligation)` together
safe: the pair travels as one value through a function boundary and must
be destructured and its tracked component discharged, exactly as if it
had been returned alone.

**Why destructuring only, no `.0`/`.1` projection**: projecting a single
component out of a kinded tuple is partial access -- the same
place-tracking question OWNERSHIP_KERNEL.md's Stage 3 (struct
fields/array slots holding affine/linear values) is scoped to answer.
Restricting v1 to whole-tuple destructuring keeps kind tracking
variable-granular and function-local, with no new machinery.

This was deliberately chosen over Go-style "multiple return values" that
never exist as a value (only at a call boundary): the whole point of
pairing data with an obligation is to observe how the pair is actually
used in real code, which requires the pair to be a value manipulable
inside function bodies, not one that scatters into separate locals at
every call site.

See examples/tuple_pair (positive: try-style `(bool, i32)`, a
`(data, obligation)` pair, and nesting) and examples/
tuple_linear_leak_wrong, tuple_field_wrong, tuple_cast_wrong
(compile-error companions).

## Enums

```
enum Name: u16 { V1 = n1; V2 = n2; ... }        // exhaustive
enum Name: u16 { V1 = n1; ...; _; }             // non-exhaustive (trailing `_;`)
```

- **Exhaustive** (no trailing `_;`): the type guarantees the value is one
  of the named variants. `int as Enum` inserts a runtime switch + trap on
  an unrecognized value (unless the source's static range is already
  provably a subset of the variants, in which case no check is emitted).
  `match` requires either all variants covered or a `_` wildcard arm; an
  uncovered case with no `_` compiles to LLVM `unreachable`, not a
  runtime trap -- so on an exhaustive enum, the *cast*'s check is the only
  thing standing between an invalid value and real undefined behavior.
- **Non-exhaustive** (trailing `_;`): models an open set (e.g. an
  IANA-registered protocol field). `int as Enum` never traps -- any
  integer is a valid value. `match` requires a `_` arm (listing every
  currently-known variant is not sufficient, since the compiler enforces
  that assumption cannot be made). Round-trip is guaranteed:
  `(raw as Enum) as u16 == raw` for any `raw: u16`, including values
  that only match the `_` arm.
- `Name::Variant` -- enum variant literal, valid as a compile-time
  constant global initializer.
- `EnumVariant as underlying_type` -- cast to the enum's declared
  underlying integer type.

## Match on Primitive Types (GitHub issue #151)

```
fn classify(v: i32) -> i32 {
    match v {
        0 => { return 100; }
        1 => { return 101; }
        -1 => { return 102; }
        _ => { return 999; }
    }
}
```

`match` also accepts a discriminant of a primitive integer type
(`i8`/`i16`/`i32`/`i64`/`u8`/`u16`/`u32`/`u64`/`isize`/`usize`) or a
`{lo..<hi as base}` refinement of one, with each arm naming a literal
value (`N => { ... }` or `-N => { ... }`) instead of an enum/variant case.
Lowers to the same LLVM `switch` instruction an enum/variant match already
uses -- the literal arms become `switch` cases and, when present, the `_`
arm becomes the default target.

An arm may name several literals separated by `|`, sharing one body
(GitHub issue #156 -- OCaml's/Rust's own pattern-alternation syntax,
picked over a comma-separated or brace-set alternative specifically to
avoid this project's own conventions elsewhere: `,` already reads as a
plain list/tuple separator, and `{...}` immediately after `=>` would be
visually confusable with the arm's own body block):

```
fn el0_dispatch(syscall_num: usize) -> i32 {
    match syscall_num {
        64 | 68 => { return 1; }             // write, pwrite64
        99 | 134 | 135 | 167 | 293 => { return 0; } // accept-and-succeed group
        _ => { return -1; }
    }
}
```

Positive and negative literals may mix freely within one arm's list
(`10 | -1 => { ... }`). Lowers to one `switch` `add_case` per literal, all
targeting the same arm block -- the body itself is still emitted once per
arm, not once per literal.

- **A `_` wildcard arm is always mandatory here**, unlike an
  exhaustive enum/variant match: an integer's value space can never be
  exhaustively listed the way a closed set of named cases can, so there
  is no "every case covered, no wildcard needed" path. This holds even
  when the discriminant is a `{lo..<hi as base}` refinement with a small,
  fully enumerable proven range -- the refinement narrows what values can
  actually reach the match, not what the match's own case-completeness
  rule requires.
- **Duplicate literals** (the same value named twice, whether by two
  separate arms or twice within one OR-pattern arm's own `|`-separated
  list) are a compile error.
- **A literal is checked against the discriminant's own base type's
  width** (its full `i8`/.../`usize` range, the same bound
  `for i: base in lo..<hi`'s explicit annotation already enforces), not
  against a `{lo..<hi as base}` discriminant's narrower proven range --
  `200 => { ... }` type-checks against a `{0..<4 as u8}` discriminant
  (200 fits `u8`) even though 200 is outside `{0..<4}`; the mandatory `_`
  arm is what covers values outside the proven range, not a per-arm
  literal-range restriction. A negative literal against an unsigned base
  type is out of range and rejected (no wraparound-bit-pattern
  reinterpretation).
- Mixing a literal arm and an `enum`/`variant` case arm in the same
  `match` is a compile error: the discriminant's type picks one arm
  grammar, not both.
- **No pattern beyond a `|`-separated set of literals is supported yet**
  -- no ranges (`0..<10 => { ... }`), and no string/byte-slice patterns
  (this project has no first-class string type; what a string *pattern*
  should even mean is an open question, not yet designed).

## Slices

`[]T` (minimum length 0) and `[T; N..]` (minimum length N) are a fat
`{ptr, usize}` value. `.len` (type `usize`) is the *runtime* length; the
type's own `N` is a compile-time-proven *lower bound* on that runtime
length, not the exact length.

**Creation**:
- `arr as []T` / `arr as [T; N..]` -- from an array variable; the
  array's static size becomes the slice's minimum.
- `s[a..<b]` on a slice or array -- subslice. When `a`/`b` are provably
  in range (constant bounds, including checked `+`/`-`/`*`/`/` expressions
  over literals and `const` names, or a proven `{lo..<hi}` range, including the
  "same-base" pattern `s[v..<v+k]` for the same variable `v` reused on
  both sides), no runtime check is generated and the result's minimum is
  the proven exact length. Otherwise a runtime check against the base's
  actual length is generated (recorded as a `--forbid-trap` site).
- `unsafe { p[a..<b] }` on a raw pointer -- UNCHECKED slice construction:
  the length assertion has no compiler evidence behind it, so `unsafe`
  is mandatory. This is the standard way a driver turns a raw MMIO/DMA
  buffer pointer into a slice at a driver boundary, after which every
  further access through the slice is bounds-governed normally. Rejected
  on `*io T` (slice access is non-volatile).
- `"literal" as []u8` -- compile-time byte length (NUL excluded) becomes
  the minimum.
- `s as *T` -- explicit bridge back to the raw-pointer world (the `ptr`
  half only). Casting a slice to anything else is a compile error.
  **When `T` is `u8`, or is exactly the slice's own element type, this
  is unconditionally free** (a byte pointer's size is 1, and casting to
  the slice's own element type is a plain pointer-extraction decay, not
  a reinterpretation, so no proof is needed either way -- this also
  means it works for a target-dependent element type like `usize`, which
  `sizeof` itself cannot resolve at compile time). **Casting to any
  OTHER type `U`** (GitHub issue #218 follow-up, "slice-to-struct-
  pointer" variant) requires the slice's proven minimum length to cover
  `sizeof(U)` -- provable only when `U`'s size is itself target-
  independent (the same fixed-width-primitive/array/packed-struct rules
  `sizeof(...)` uses, via `const_type_size`) and the slice's own minimum
  is a real nonzero lower bound (not a dynamic `[]T` with no proven
  floor). If either is missing, `unsafe { s as *U }` is required; the
  error message distinguishes "proven length too small," "length not
  provable at all," and "size itself not provable here" since each
  calls for a different fix (tighten the type / add a runtime length
  check / this specific cast just can't be proven target-independently).

**Stack lifetime**: a slice derived from a local array is tied to the current
stack frame. It may be used locally and passed through a verified `borrow`
slice parameter, but cannot be returned, stored in a global or aggregate,
written through a pointer, or
passed to a potentially retaining plain slice parameter. Subslice, alias, and
slice-to-pointer cast preserve this tie. Global-array and string-literal
storage are not stack-tied. General stack-derived raw-pointer lifetime
tracking is not yet part of this rule.

**Indexing**: `s[i]` needs no runtime check iff `i`'s proven range
satisfies `lo >= 0 && hi <= minimum`. Otherwise a runtime check against
the slice's actual (runtime) `.len` is generated.

**Length narrowing**: `if (s.len >= K) { ... }` upgrades the binding's
proven minimum to `K` for the branch, the same way integer narrowing
upgrades a value's range (see "Refined Integer Types"/narrowing below),
and is subject to the identical kill rule (an assignment, `&`-alias, or
rebinding of the slice inside the branch invalidates the narrowing). `K`
may be a literal, a compile-time `const`, or a target-independent
`sizeof(...)`/`offsetof(...)` value. The fallthrough after an early-return
guard such as `if (s.len < sizeof(Header)) { return; }` carries the same
minimum-length proof. Equality in either order also provides the lower-bound
half of its fact, so `if (s.len == 2) { s[1] }` is trap-free.

**Runtime endpoint evidence**: a guard comparing a `usize` endpoint with
the same slice's runtime length proves a following subslice without adding
a second bounds check. Thus `if (end <= s.len) { s[0..<end] }` and
`if (start <= s.len) { s[start..<s.len] }` are trap-free. The mirrored
comparisons and the fallthrough after an early-return guard are equivalent.
The evidence is tied to the exact endpoint and slice bindings and is killed
if either is reassigned or aliased; it cannot justify a subslice of another
slice. Equality with `.len` is valid for an endpoint, but does not make the
same value a valid single-element index. A constant suffix
`s[K..<s.len]` is likewise trap-free when the slice's proven minimum length
is at least `K`; the minimum-length guarantee proves that `K <= s.len` for
every runtime length of the slice.

**`for x in slice_expr { ... }`** -- safe-by-construction element
iteration: the compiler generates the counter, length compare, and
bounds-safe load itself, so there is no index expression to prove safe
in the first place. The slice expression is evaluated once, at loop
entry.

**Builtins**: `slice_copy(dst, src) -> usize` copies
`min(dst.len, src.len)` elements forward and returns the count (a
length mismatch shows up only in the return value, never as a trap);
`slice_eq(a, b) -> bool` is `false` on a length mismatch, `true` iff
every element matches. Both names are reserved (defining a `fn`/`extern
fn` with either name is a compile error).

**Subtyping**: a slice with a larger proven minimum is a subtype of one
with a smaller minimum (passable wherever the smaller minimum is
required). An immutable `let` binding's annotation never *weakens* an
already-proven minimum (the initializer's stronger proof survives); a
`let mut` binding always uses its declared (possibly weaker) type, since
reassignment can genuinely bring a shorter slice later.

## Authority-Derived Region Returns

### Owner-derived slices

```
fn net_rx_frame(frame: borrow NetRxCpuOwned[desc]) -> [u8; 1514..] @ desc { ... }
```

A slice RETURN type may carry `@ name` (GitHub issue #106, TAKIBI_CORE.md
post-Slice-6 order item 1), where `name` is a static index appearing in
some `borrow`/`borrow mut` indexed-owner parameter of the same function
(a compile error otherwise, and an integer `@ 3` is rejected too). The
annotation ties the returned slice to that owner: **once the owner is
consumed (released/moved), any later use of the slice -- or of anything
derived from it -- is a compile error** ("slice 'f' is derived from
linear value 'o' and cannot be used after 'o' is consumed"). This is what
makes `net_rx_frame`'s buffer unusable after `net_rx_release` hands it
back to DMA.

- **Caller-side restriction only.** The callee body has no new proof
  obligation -- it may return a slice of a global (as both real backends
  do). An annotation on an unrelated slice only makes callers more
  conservative, never unsound. The annotation is therefore part of the
  declaring driver file's reviewed API contract, consistent with the
  trusted-file doctrine.
- **Checker-only.** Stripped before HM typing; no LLVM/ABI/DWARF
  footprint. Only the `->` return form can carry it (the legacy
  no-arrow return grammar cannot). Everywhere OTHER than a whole slice
  return type, `@` on a slice keeps its existing rejection.
- **Taint propagation** (function-local): binding the call result
  (`let f = net_rx_frame(o);`), an immutable alias (`let g = f;`), and a
  subslice (`let s = f[a..<b];`, including under `unsafe`) all carry the
  tie. Reassigning a `mut` binding to an unrelated value clears it. The
  check itself is lazy: a tied name is rejected at USE time once the
  owner is possibly consumed (branch merges are conservative unions,
  like affine double-use).
- **Escapes rejected**: returning a tied slice from the enclosing
  function, or storing one into a global, struct field, array element,
  or through a pointer, is a compile error -- the tie is function-local
  and those would outlive it.
- **Authority rebinding rejected**: while an in-scope local still carries a
  tie, the owner/guard binding named by that tie cannot be assigned a fresh
  value or reused by a `let`, tuple destructure, loop binder, `for in`
  binder, or variant payload binder. Otherwise the name-keyed tracker could
  mistake the fresh authority for the consumed authority and revive the old
  derived value. Reassigning a mutable derived binding to an unrelated value
  clears the tie; leaving its scope also ends the restriction.
- **Aggregate storage rejected**: an authority-derived slice or pointer
  cannot be placed in a tuple, variant payload, or struct literal, including
  through nested aggregate literals. The current taint domain tracks direct
  local bindings, not tuple components or variant cases; rejecting the store
  is sounder than silently losing the tie during destructuring or matching.
  Component-shaped aggregate region tracking remains demand-led.
- **Representation changes retain authority**: casts do not discard a
  lifetime tie, including slice-to-pointer, pointer reinterpretation, and
  pointer-to-integer conversion followed by a later cast back. Arithmetic
  and bitwise transformations of a tied address value propagate the same
  tie. A raw pointer may still discard bounds or alignment information; this
  rule preserves only the authority lifetime, so `unsafe` does not become a
  lifetime escape hatch.
- **Indirect local storage rejected**: taking the address of an
  authority-derived local is rejected. A pointer-to-local would otherwise
  hide the tied value behind storage that the direct-local taint domain cannot
  follow. Dereferencing, indexing, or reading a field from a live tied value
  produces ordinary copied data when the result is scalar. A pointer or slice
  result remains tied because it is another address alias.
- **Callee retention boundary**: an authority-derived pointer or slice may be
  passed to a named Takibi function only when the corresponding parameter is
  declared `borrow *T`, `borrow align(N) *T`, or `borrow [T; N..]`. A plain
  pointer or slice parameter is potentially retaining and rejects such an
  argument. This `borrow` means non-owning and non-retaining for the duration
  of the call; it does not make the pointee immutable.
- **Borrow body verification**: a `borrow` pointer/slice parameter seeds a
  fresh function-local region tie in the callee. Returning it, storing it
  durably, placing it in an aggregate, or forwarding it to a potentially
  retaining parameter is rejected. Pointer/slice aliases loaded through
  dereference, index, or field access retain the tie, while scalar copies do
  not. Copying an aggregate that contains a pointer or slice from borrowed
  storage is conservatively rejected because component-shaped region tracking
  is not implemented. Compiler builtins are a trusted synchronous/non-retaining
  set; `min`/`max` additionally propagate any address taint to their result.
- **Indexed-owner handoff exception**: inside a function with a matching
  `sink IndexedOwner[id, ...] -> LinearIndexedOwner[id, ...]` signature,
  values derived from that sink may be stored durably or passed onward. The
  returned linear owner represents the outstanding retention obligation, as
  in `net_transmit`. This is a narrow reviewed signature contract, not general
  heap inference or proof that a particular stored address is cleared on
  completion.
- **Trusted declarations and ABI**: an `extern fn` body is unavailable, so a
  `borrow` pointer/slice parameter there is a trusted declaration. Borrow
  modes and region ties erase; raw pointers and slices retain their ordinary
  LLVM calling convention.

See `examples/net_rx_use_after_release_wrong` for the focused
compile-error fixture; the real positive fixtures are the network
examples themselves, whose frame access all flows through the annotated
`net_rx_frame`.

### Guard-derived pointers

```
fn shared_access(g: borrow KGuard[lock]) -> *Shared @ lock { ... }
```

A pointer RETURN type may use the same checker-only `@ name` relation
(GitHub issue #128), with `name` supplied by a `borrow`/`borrow mut` indexed
owner or view parameter. The returned pointer and its local aliases become
unusable once that authority is possibly consumed. In particular, consuming
`g` with `kunlock` before `data.field`, `*data`, or an alias use is a compile
error. Returning the tied pointer or storing it durably has the same escape
rejection as a tied slice.

Only return position gives `*T @ name` this region meaning. In parameter
position it retains the static address-identity meaning described under
"Static address/place identities": the pointer is still an ordinary runtime
argument related to the erased `name`. A region-annotated pointer return is
stripped before HM typing and LLVM lowering, so the accessor returns exactly
one plain pointer and its guard parameter remains erased.

This is a caller-side lifetime contract, not a proved lock invariant. The
declaring module is responsible for making the accessor return data actually
protected by that lock. The current checker proves only that callers obtained
the pointer through the annotated accessor and cannot use it after consuming
the particular guard. Representation changes preserve this lifetime tie, and
the authority-rebinding and aggregate-storage barriers apply identically to
guard-derived pointers. Passing one across a direct named call is governed by
the same verified `borrow` callee boundary as an owner-derived slice.

`examples/rtos_demo` is the real positive use: its private `Shared` value is
reachable only through `shared_access(g)`. The focused
`examples/guard_pointer_after_unlock_wrong` fixture consumes the guard and
then attempts a field read through the old pointer.

## Arrays and Pointers

- `[T; N]` decays to `*T` when used as an ordinary value (e.g. a function
  argument). Can only be *declared* at local/global scope.
- Array-size `N` may be a literal integer, the name of an earlier
  `const` declared with a bare literal integer initializer, or
  `+`/`-`/`*`/`/` combining those (parentheses allowed), e.g.:
  ```
  const QUEUE_SIZE: usize = 16;
  let mut ring: [T; QUEUE_SIZE];
  let mut pair: [T; QUEUE_SIZE * 2];
  ```
  Resolved entirely in the parser; no forward references. This arithmetic
  folding applies only to the `[T; N]` grammar position -- an ordinary
  global `let`'s own initializer cannot fold arithmetic between two
  named constants (`let X: i32 = A + B;` is a compile error; a plain `as`
  cast chain or a same-value reference to one earlier global *is*
  supported as an initializer, see "Global Constant Folding" below).
- An uninitialized global array/variable (`let mut heap: [u8; 256];`) is
  emitted as LLVM `undef`, relying on `startup.S`'s BSS zero-clear for a
  well-defined runtime value.
- `p[i]`, `p[i] = v`, and `unsafe { p[lo..<hi] }` on a raw pointer `*T`
  are low-level signed-displacement operations, distinct from array/slice
  indexing: they require `isize` (or a refined integer whose own base is
  `isize`), carry no array-length guarantee, and get no runtime bounds
  check at all (raw pointers are the unsafe escape hatch; the compiler
  does not track allocation provenance, so `ptr1 - ptr2` is only
  meaningful when both derive from the same allocation).
- **`*T` where `T` is itself pointer-shaped is always a compile error**
  (`**T`, `*align(N) *T`, `*io *T`, and so on through any struct/array/
  field nesting, GitHub issue #239) -- no `unsafe` escape, unconditional.
  Nested indirection introduces ownership/lifetime/provenance questions
  the language does not otherwise need to solve, and a repo-wide survey
  found zero genuine uses. Enforced at both the type-annotation level
  (`lib/types.ml`'s `of_ast_in_scope`, the sole `Ast.type_expr -> ty`
  conversion point) and at the four `ty`-level "minting" sites where a
  `**T` can arise purely through inference with no `Ast.TypePtr` AST node
  to catch it: a bare array-of-pointers variable decaying to a pointer,
  address-of on a pointer-typed local or pointer-typed struct field, and
  an array-of-pointers struct field decaying on read (`let mut p: *u8 =
  ...; let pp = &p;` used to compile to a working `**u8` binding before
  this closed). `io` is a qualifier, not a pointer layer, so it is
  stripped before checking -- `*io T` stays legal as long as `T` itself
  is not pointer-shaped.

### Global Constant Folding

An immutable global's initializer can be a bare literal/struct literal
(always supported), an `as`-cast chain (`let X: i32 = 0x80000000 as
i32;`), a unary-minus literal, or a reference to an *earlier* immutable
global with its own constant initializer (`let Y: [u8;4] = X;` --
supported uniformly for scalars, arrays, and structs). General
constant-expression arithmetic between two named constants
(`let X: i32 = A + B;`) is deliberately **not** supported. Referencing a
`let mut` global, or a global declared later in the (concatenated)
source, is a compile error.

## Non-Raw Reference Types: `&T` / `&mut T` (GitHub issues #314/#319)

`&T` (shared) and `&mut T` (exclusive) are references to a plain named
struct value -- structurally distinct from `*T` (a separate `Ast.type_expr`/
`Types.ty` constructor, not a qualifier on `TypePtr`), so a raw-pointer
`unsafe` mandate that might land in the future (see "Known Limitations")
never has to special-case them. They exist to give ordinary
pass-by-reference parameters (`pool: *GrowablePool`, passed purely to avoid
copying and dereferenced only through ordinary field access) a type that is
provably non-arithmetic and non-forged, without disturbing `*T`'s own,
already-pervasive, arithmetic-capable role in drivers and wire-format code.

```takibi
struct Pool { count: usize; }

fn bump(p: &mut Pool) { p.count = p.count + 1; }   // may write fields
fn peek(p: &Pool) -> usize { return p.count; }      // read-only

fn f() {
    let mut pool: Pool = {0};
    bump(&pool);           // &pool synthesizes &mut Pool here (parameter-directed)
    let n = peek(&pool);   // &pool synthesizes &Pool here -- same call-site spelling
}
```

- **Minting is unchanged `&expr`.** There is no separate mint syntax:
  `&expr` (`AddrOf`) keeps its existing grammar and restrictions exactly
  (only a bare variable or struct field -- `&s`, `&s.field`, never
  `&arr[i]`; a local must be mutable to be addressed, globals are always
  addressable; linear/indexed-owner/erased-view/variant/singleton targets
  are rejected). Only the *type* `&expr` produces changes, resolved from
  context: a function argument or `let` annotation of type `&T`/`&mut T`
  directs `&expr` to mint that type; with no such directing context (an
  unannotated `let`, a not-yet-migrated `*T` parameter, any other use)
  `&expr` still synthesizes plain `*T` exactly as it always has. This is
  why migrating one function's parameter from `*T` to `&T`/`&mut T`
  requires no changes at any of that type's existing `&expr` call sites.
- **Field access.** `r.field` (read) works through either `&T` or
  `&mut T`. `r.field = v` (write), and `*r = v` through a `&`/`&mut`-typed
  place, is a compile error for `&T` -- only `&mut T` may write. This is a
  real, new correctness guarantee `*T` never had (no const/mut pointer
  distinction exists for `*T`).
- **No arithmetic, no indexing, no other casts -- bit-opaque, no `unsafe`
  escape.** `r + 1`, `r[i]`, and any cast into `&T`/`&mut T` other than
  the two forms below are compile errors, unconditionally (forgery
  -proofness is the entire point of this type, so there is no `unsafe`
  override, mirroring affine/linear's own "no cast-away" rule).
- **Widening/narrowing casts, asymmetric.** `&T`/`&mut T` widen to `*T`
  (and further, e.g. `as usize`) with **no** `unsafe` -- an address that
  really did come from `&x` needs no further justification, the same
  principle already established for affine-handle casts built from a real
  object's address. The reverse -- asserting a raw `*T` is actually a
  live, correctly-typed, non-aliased value and building a `&T`/`&mut T`
  from it -- is legal ONLY from the exact same pointee type, and always
  needs `unsafe`:
  ```takibi
  fn take(p: &Pool) -> usize { return p.count; }
  fn f(raw: *Pool) -> usize !{unsafe} {
      return take(unsafe { raw as &Pool });   // asserts raw is live
  }
  ```
  An already-`&`/`&mut`-typed source may also cast to `&T`/`&mut T` of the
  same referent with no `unsafe` (an explicit reborrow); `&mut T` widens to
  `&T` this way (and via ordinary argument passing), never the reverse.
  No other source type may cast to `&T`/`&mut T` at all, not even under
  `unsafe` -- fabricating a reference from an arbitrary integer or an
  unrelated pointer type would defeat the entire point of this type.
- **Legal positions, v1: function parameters and local `let` bindings
  only.** Not a struct field, global, return type, or array/slice element.
  No escape/lifetime analysis is implemented for `&T`/`&mut T` (deliberately
  -- see #132 for the project's general region-polymorphism work, which
  this does not depend on and is not blocked by), so it simply is not
  legal anywhere an escape could happen.
- **No aliasing/exclusivity proof.** `&mut T` guarantees "only this
  parameter may write field/deref targets," by construction of who can
  call it with what -- it does not prove no other alias of the same place
  exists concurrently. That stronger guarantee (a general borrow checker)
  is out of scope; see #132.
- **Codegen: identical to `*T`.** Same bare pointer representation, same
  calling convention, zero runtime cost -- the distinction is entirely in
  the OCaml-side type checker.

Migrated so far: `kernel/lib/growable_pool.tkb` (`pool: *GrowablePool`),
`kernel/lib/freelist.tkb` (`FreelistCore`/`Freelist`), `kernel/lib/
slotmap.tkb` (`SlotMap`), `kernel/lib/refcount_slotmap.tkb`
(`RefcountSlotMap`) -- every parameter of these four small "resource pool"
libraries is now `&mut`. Caller sites needed no changes except where an
existing intermediate `let core: *FreelistCore(N) = &x.core;`-shaped local
(a pre-existing, unrelated workaround for a separate generic-inference
limitation: a generic call's static parameters cannot be inferred from a
nested-field address, only from a plain local/global or its address) also
had its own annotation updated to `&mut` -- `kernel/mm/page.tkb` needed
this, every other caller (`kernel/kernel/process.tkb`, `kernel/kernel/
fd_table.tkb`, `kernel/net/tcp.tkb`, `kernel/arch/arm64/mm/asid.tkb`)
already called through a plain `&global` and needed no change at all.
Further files migrate incrementally, one narrow issue at a time, per this
project's usual practice.

## MMIO / Volatile

- `io T` is a volatile-qualified *value* type (same LLVM representation
  as `T`). `*io T` (`= TypePtr(TypeIo T)`) is a volatile pointer.
- `*p` where `p: *io T` is a volatile load; `*p = v` is a volatile store.
- `*p` where `p: *T` (regular pointer) is non-volatile (LLVM may
  optimize/reorder/eliminate it).
- Any direct access to a variable declared `io T` (e.g. `let flag: io
  i32;`) is volatile.
- `&io_var` automatically produces `*io T` -- no `as *io T` cast needed,
  and no `unsafe` either: taking the address of a real, already-existing
  `io`-qualified variable is not the unprovable "this integer denotes a
  valid register" assertion the `unsafe { ... }` gate below is about.
- `io` is stripped on dereference: `*p` where `p: *io i32` has result
  type `i32` (not `io i32`); volatility is confined to the load
  instruction itself.
- A global variable shared with an interrupt handler (a flag polled in a
  spin loop) must be declared `io` -- otherwise LLVM may hoist the load
  out of the loop and produce an infinite `cbz`-style spin, since a plain
  (non-`io`) global load has no ordering guarantee against a concurrent
  ISR write.
- `p.field` where `p: *io Struct` is a volatile field load.
- An integer literal can be assigned directly to an MMIO pointer type
  (`let dr: *io u8 = unsafe { 0x09000000 };`) -- coerces via `inttoptr`.
  As of GitHub issue #316, this requires `unsafe` like any other `*io`
  construction (see "unsafe { ... }" below) -- there is no bare-literal
  exemption for `*io` the way there is for affine/linear handle casts.

**DMA / synchronization builtins** (no user-callable `extern fn`
needed): `dma_publish()`, `dma_consume()`, `device_fence()` (ARM/AArch64
lower to `DSB SY`; AMD64 to `MFENCE`; RISC-V uses direction-preserving
fences). Cache-aware: `dma_prepare_tx(ptr, len)`, `dma_prepare_rx(ptr,
len)`, `dma_finish_rx(ptr, len)` (Cortex-M7 rounds to 32-byte cache
lines and issues SCB DCCMVAC/DCIMVAC plus barriers). On cache-maintained
targets, `dma_prepare_rx` and `dma_finish_rx` require a pointer proven as
`*align(DMA_CACHE_LINE) T`; AArch64 therefore rejects a merely
`*align(32) T` RX buffer while STM32F7 accepts it. `dma_prepare_tx` remains
valid for a plain `*T`, because cleaning rounded endpoint lines does not
discard adjacent dirty data. Targets without either a cache-maintenance
contract or coherent DMA reject these builtins during type checking.
`signal_fence()` is
a compiler-only ISR/normal-context memory boundary (side-effecting empty
inline asm with a memory clobber, no hardware barrier instruction).
`interrupt_wait()` / `interrupt_notify()` are a race-free event-wait pair
on ARM/AArch64 (`wfe`/`sev`); unsupported targets reject these builtins
at codegen time rather than silently lowering to a racy `wfi`.

## Function Pointers, extern fn, and Overloading

- `fn(T...) -> R`, `fn !{}(T...) -> R`, and
  `fn !{may_block}(T...) -> R` are first-class function pointer types (see
  "Blocking and Interrupt Effects" above).
- `extern fn name(params) -> ret;` declares an externally-defined
  (assembly-implemented) function, emitting an LLVM `declare`. `extern
  fn` is **not** overloadable -- its unmangled symbol name is an external
  ABI contract.
- `extern symbol name;` declares a symbol defined elsewhere (hand-written
  assembly or the linker script) with no Takibi type at all -- there is
  nothing to read or write through it, only an address. Referencing the
  bare name evaluates to that address as a `usize` (GitHub issue #225).
- `embed_file("path")` (GitHub issue #230) reads a real file at compile
  time and becomes a `[u8; N]` array constant, `N` the file's actual byte
  size -- no `.incbin`-in-a-hand-written-`.S`-file plus `extern symbol
  start`/`end` pair plus runtime `end - start` subtraction needed to get
  the same data into `.tkb`. `path` resolves the same way `use "...";`
  resolves its own paths (relative to the directory `takibi` is invoked
  from). Restricted to exactly one position: the direct initializer of a
  top-level `let`/`let mut` (`let mut` for a writable/`.data`-like array,
  plain `let` for read-only/`.rodata`-like, matching how these two forms
  already differ for any other global) -- any other position (a local
  `let`, a function argument, nested inside another expression) is a
  compile error. An explicit array-size annotation on the global is still
  allowed and gets verified against the real file size like any other
  typed initializer (a mismatch is an ordinary type error); the
  restriction is about position, not annotation presence.
- `vector_table { N => target; ... }` declares the target architecture's
  hardware exception vector table (GitHub issue #227): each entry names an
  architectural vector slot `N` and the `fn` or `extern symbol` branched to
  for it. Every slot the target architecture defines must be listed exactly
  once (a compile error otherwise names the missing slot); a program may
  declare at most one `vector_table`. AArch64 is the only target with a
  contract today -- it defines exactly 16 slots, an architecture fact (the
  ARM Architecture Reference Manual's `VBAR_ELn` requires a 2KB-aligned
  table of 128-byte-spaced entries), not an LLVM one, so another target
  gets its own contract (or none, which makes `vector_table` a compile
  error) rather than inheriting AArch64's. A target used by more than one
  slot receives its slot number in `x0` immediately before the branch, so a
  shared handler (e.g. a fail-stop path reached from many unhandled slots)
  can identify which one fired; a target used by exactly one slot does not
  -- no register is touched before that target's own entry code runs,
  which matters for a slot whose handler resumes the interrupted context
  rather than parking forever (see HISTORY.md's issue #227 items 2 and 3
  for the real register-clobber bug this asymmetry exists to prevent).
- `exception_entry name { frame: FrameStruct; dispatch: fn_name; before:
  fn_name; }` (GitHub issue #227 item 1, prototype slice -- syntax not yet
  final) generates a complete save-frame / optional `before` call /
  `dispatch` call / restore-frame / `eret` sequence for one vector's entry
  point, in place of hand-written assembly. `frame` must name a `struct
  packed` whose fields are EXACTLY AArch64's exception-frame registers,
  one of each, no more, no less: `x0`..`x30`, `sp_el0`, `elr_el1`,
  `spsr_el1`, `tpidr_el0` (all `usize`), `q0`..`q31` (`[u8; 16]` each --
  this language has no 128-bit primitive type, and storing 16 raw bytes
  needs none), `fpsr`, `fpcr` (`usize`). The generated stack allocation is
  rounded up to preserve AArch64's 16-byte SP alignment. Field declaration
  order is free -- offsets are
  computed from whatever order the struct itself declares. `dispatch` is
  called with the frame's own stack address (as `usize`) after the save
  (and `before`, if given) and must return a `usize`, the frame address to
  resume from (unchanged from the hand-written convention it replaces).
  `before` is optional; both `dispatch` and `before` are checked against
  their real signature (`fn(usize) -> usize` / `fn()`), not just existence.
  `exception_entry` only covers the uniform save -> dispatch -> restore ->
  `eret` shape.
- `exception_restore name { frame: FrameStruct; }` (same issue, same
  prototype-syntax caveat) generates just the restore-frame/`eret` half,
  for a standalone resume entry point reached via an ordinary call with
  the frame's own address already in the platform's first-argument
  register (AArch64: `x0`) -- not via a preceding save in the same
  sequence. `frame` is validated exactly like `exception_entry`'s. The
  generated symbol still needs an ordinary `extern fn name(frame_sp:
  usize) !{noreturn};` declaration alongside it for other `.tkb` code to
  call it normally -- this declaration only supplies the generated raw-asm
  BODY, the same relationship an `extern fn` normally has with a
  hand-written assembly body.
- `inline fn name(params) -> ret { ... }` marks a Takibi-defined function
  as an explicit inlining request. In normal optimized builds the backend
  emits LLVM's `alwaysinline` function attribute and runs the corresponding
  `always-inline` pass. Takibi does not otherwise inline ordinary `fn`
  definitions implicitly. `-g` builds currently disable the inlining pass
  to keep GDB stepping and local-variable visibility stable; use a
  non-`-g` build when checking object-code inlining behavior.
- `noinline fn name(params) -> ret { ... }` is `inline`'s opposite: it
  emits LLVM's `noinline` function attribute, an explicit, permanent
  guarantee that this function keeps its own call site and its own stack
  frame regardless of build flags or future optimization-level changes.
  Since ordinary `fn` definitions are already never inlined implicitly
  (see above), `noinline` has no effect on generated code *today* -- its
  purpose is to make that guarantee durable and self-documenting at the
  one call site that actually depends on it (typically a GDB breakpoint
  target: a small, single-call-site function the inliner would otherwise
  be free to fold away under a future, more aggressive default, silently
  breaking `return`'s ability to pop a distinct frame there). Prefer it
  over relying on incidental non-inlining whenever a function's identity
  as a real, addressable call frame is part of its contract, not just an
  implementation detail.
- **Function overloading**: multiple `fn` definitions sharing a name are
  collected into an overload set and compiled under mangled linkage names
  (`_TK_<name>__<type-codes>`); DWARF still records the original,
  unmangled source name for debuggers. Overload resolution uses **exact
  parameter types only** -- no implicit conversion or ranking, so an
  unconstrained integer literal argument to an overloaded call is a
  compile error (annotate it, or use `as T`). Taking a bare function
  pointer to an overloaded name is rejected today (no
  expected-type-based selector yet).
- `uart_print`/`uart_println` (in `examples/common/print.tkb`) are the
  standard example of this: overloaded for `bool` and every
  signed/unsigned integer width including `isize`/`usize`. Narrow types
  share 32-bit conversion cores and wide types share 64-bit cores;
  signed minimum values are converted through unsigned subtraction to
  avoid overflow. The old non-overloaded helper names (`uart_print_int`,
  `uart_print_uint`, and their `println` variants) have been removed --
  use the overloaded entry points instead.

## Refined Integer Types

`{lo..<hi as base}` is a value of type `base` statically known to lie in
`[lo, hi)`. `base` may be any of the nine primitive integer types (`i8`
`i16` `i32` `i64` `u8` `u16` `u32` `u64` `usize`), `isize`, or `u16be`/
`u32be` (see "Endian-Aware Integer Types" below). The bare `{lo..<hi}` form
(no explicit base) is rejected -- always spell out the base.

- **`lo` and `hi` must be integer literals or earlier `const` names** --
  ordinary global `let` names are deliberately not accepted here, even
  when their initializer is a literal. For example:
  ```
  const MAX_CONNS: usize = 4;
  fn f(idx: {0..<MAX_CONNS as usize}) { ... }
  ```
- Bounds are validated against the chosen base's own representable range
  at parse time (e.g. `{0..<300 as u8}` is a compile error; `i64`/`u64`
  impose no upper-bound check, since their true range doesn't fit the
  bound-storage representation anyway).
- **Range propagation** through ordinary arithmetic preserves the
  operand's own base (not always `i32`): `{a..<b} + {c..<d} ->
  {a+c..<b+d-1}`; `{a..<b} + k -> {a+k..<b+k}` (`k` may be checked
  `+`/`-`/`*`/`/` arithmetic over literals and `const` names, symmetric);
  `{a..<b} - {c..<d} -> {a-d+1..<b-c}`; `{a..<b} * k -> {a*k..<(b-1)*k+1}`
  for a positive compile-time `k` of the same checked-arithmetic form;
  `x & k -> {0..<k+1}` for a non-negative literal mask `k`, regardless of
  `x`'s own sign or range; `n % m -> {0..<m}` for a positive literal `m`,
  **only** when `n`'s own lower bound is already known non-negative
  (otherwise stays unrefined -- LLVM's `srem` can return a negative
  remainder for a negative dividend, so this guard is a soundness
  requirement, not just precision).
- **`min(a, b)` / `max(a, b)`** (see "Expressions" above) provide
  compile-time-provable clamping against a literal, independent of the
  other operand's own range.
- **If-condition narrowing**: `if (v >= lo && v < hi)` (and the
  commutative/equality forms `lo <= v`, `v == k`) narrows `v`'s proven
  range to `{lo..<hi}` inside the branch (intersected with any
  already-proven range `v` carried in from outside). This applies to
  bare unrefined values too -- it's how an "unknown range" `i32` from
  MMIO/external input becomes usable as an array index or a `{lo..<hi}`
  -typed function argument. A bound may be an addition/subtraction
  expression over integer literals and previously declared `const` names,
  so the source can retain its natural form, e.g.
  `if (offset < IMAGE_LEN - BLOCK_SIZE + 1)`, without replacing the
  derived limit by a magic-number literal. Narrowing is invalidated
  ("killed") for the rest of the branch if the branch (a) assigns to the narrowed variable,
  (b) takes its address (`&v`), or (c) rebinds the name (a `let`
  redeclaration or a `for`/`for-in` counter of the same name) -- the
  kill check is flow-insensitive within the branch (a write anywhere
  kills the whole branch body, not just after the write).
  An explicitly typed `for i: T in lo..<hi` likewise folds `+`, `-`, and
  `*` over literals and `const` names into the counter's refined range.
  This lets a loop use the same symbolic product as its backing array size
  without duplicating that product as a numeric literal.
  A **hi-only condition** (`if (v < hi)`, no explicit lower bound) also
  narrows when a sound lower bound is available without the condition:
  `v` of an unsigned base (`u8`/`u16`/`u32`/`u64`/`usize`) implicitly
  gets `lo = 0` (GitHub issue #99 -- an unsigned value is trivially
  non-negative, so a redundant explicit `v >= 0` conjunct is no longer
  required), and a `v` that already carries a proven range from outside
  the branch keeps its own existing lower bound as the intersection
  floor. A signed base (`i8`/`i16`/`i32`/`i64`/`isize`) with no incoming
  range and no explicit lower bound in the condition is NOT narrowed by
  a hi-only condition -- it could still be negative, so both sides must
  be written out by hand (`examples/refined/refined.tkb` and
  `examples/narrow/narrow.tkb` demonstrate this signed case
  deliberately, including a negative input that the two-sided check
  correctly rejects).
- **Early-return-guard narrowing**: `if (cond) { return ...; }` (or any
  branch that always returns, unconditionally, with no `else`) narrows
  the FALLTHROUGH code after the whole `if` -- not the branch body
  itself -- via `cond`'s own logical negation (De Morgan for `&&`/`||`,
  flipped comparisons for `<`/`>=`/`==`/`!=`). `!=` never narrows to a
  contiguous range (excluding one point from an unbounded range isn't
  representable as a single `{lo..<hi}`), whether written directly in a
  guard or produced by negating `==` -- so a guard written with `==`
  (negating to `!=`) does NOT narrow the fallthrough, e.g. `if (v == 0)
  { return; }` leaves `v` unnarrowed afterward, while the same guard
  written as `if (v < 1) { return; }` does (negates to the narrowable
  `v >= 1`). A guard written with `!=` DOES narrow the fallthrough,
  since its negation is `==` (to the single point `{k..<k+1}`) --
  `kernel/arch/arm64/mm/asid.tkb`'s `asid_transferred_release` hit
  exactly this asymmetry (GitHub issue #296, 2026-08-15): its guard's
  `asid == 0` disjunct negates to the unnarrowable `asid != 0`, rewritten
  to the equivalent, narrowable `asid < 1` form instead of left unproven.
  Applies to any binding --
  immutable, mutable, or an ordinary function parameter -- EXCEPT one
  that some statement anywhere else in the same enclosing statement list
  (not just the branch itself) later writes to; that exclusion is what
  keeps this sound for a variable reassigned after the guard (`if
  (initialized != 0) { return Failed; } initialized = 1;` correctly
  keeps `initialized` unnarrowed, since it's reassigned right after).
  GitHub issue #295 introduced this narrowing for immutable bindings
  only; issue #296 (2026-08-15) extended it to mutable bindings and
  parameters via that same-enclosing-list write check (see HISTORY.md
  for both).
- **Same-base subslice rule**: `s[v + j ..< v + k]` for the *same*
  variable `v` and constant (or non-negative-lower-bounded) offsets `j`,
  `k` has a provable length `k - j` and a provable `lo <= hi`,
  regardless of `v`'s own range -- ordinary independent-interval
  reasoning cannot see this correlation, since it treats the two
  occurrences of `v` as unrelated.
- **Casting into a refined type** (`expr as {lo..<hi as base}`): if the
  source's own proven range already implies the target range (same or
  narrower bounds, any source base), this is a **free coercion** -- no
  runtime check, even across a base change (e.g. bridging a proven
  `{0..<8 as u8}` into `{0..<8 as usize}` for indexing). Otherwise a
  runtime range check is inserted (recorded as a `--forbid-trap` site).
  This cast is the deliberate bridge from unproven/differently-based
  integers into a refined type -- see "Array/Slice Indexing" below for
  why it's routinely needed at index sites.
- **Bare-cast range inference** (`expr as base`, no explicit `{lo..<hi}`):
  behaves exactly like the explicit form above when the source's own
  proven range already fits `base`'s representable range -- the compiler
  infers `{lo..<hi as base}` on its own instead of requiring it to be
  restated by hand. This is local only (never crosses a function
  boundary): a parameter, return type, or global `let` declaration always
  needs an explicit `{lo..<hi as base}` annotation to be refined. A
  source range that does NOT fit `base` falls back to a plain unrefined
  `base`, exactly as an unproven source always has -- this inference
  never adds a runtime check and never removes one that was actually
  needed.
- **Proofs survive a weaker annotation, only for immutable bindings**:
  `let x: i32 = v;` where `v: {2..<5 as i32}` keeps `x`'s proven
  `{2..<5}` range (the annotation matches `v`'s own base exactly, and `x`
  can never change) -- so a later `arr[x]` can still elide its bounds
  check. `let mut x: i32 = v;` discards the proof and uses the bare
  declared type, since reassignment can genuinely bring an unproven
  value later.
- **`while (cond) { ... }` narrows from its own condition the same way
  `if` does (GitHub issue #313), but ONLY for a binding the loop body
  never reassigns anywhere.** `while (v >= 0 && v < 4) { foo(v); ... }`
  narrows `v` inside the body when `v` is never written there, reusing
  the exact same `narrow_from_cond` machinery and kill-set rule `if`'s
  own then-branch already relies on. A binding the body DOES reassign
  stays unnarrowed for the whole body, not just after the write -- e.g.
  `while (fd < PROCESS_FD_MAX) { arr[fd] = ...; fd = fd + 1; }` still
  gives `fd` no proven upper bound, since `fd` is reassigned inside the
  loop. Found migrating `kernel/kernel/fd_table.tkb` off raw-pointer
  array-decay indexing (2026-08-15): converting the `while` to `for fd in
  first..<PROCESS_FD_MAX` did not help either, since `first` is a runtime
  value, not a compile-time constant (see "For Loops" below, though issue
  #312 later taught a `for` loop to reuse an already-refined runtime
  bound too) -- the fix for THIS reassigning-counter shape remains an
  explicit `if (fd < PROCESS_FD_MAX) { ... }` wrapping the body, the same
  idiom already used for signed lower bounds and mutable-binding
  narrowing elsewhere in this document. Prefer a `for` loop with constant
  (or, since #312, already-refined-runtime) bounds when the upper bound
  is known; fall back to an explicit wrapping-`if` for a `while`/`for`
  body that reassigns its own bound-tracking variable.

## Endian-Aware Integer Types

`u16be`/`u32be` (GitHub issue #186) are 16-/32-bit values stored in
big-endian (wire) byte order -- for a protocol header field where a raw
native load on a little-endian target would silently byte-swap the value
with no compiler-visible signal.

`struct packed be Name { field: u16; ... }` is pure parser sugar: every
eligible multi-byte integer field (`u16`/`u32`, bare or refined-over-them)
is auto-promoted to its `*be` type at parse time, so a whole header can be
declared endian-aware at once instead of field by field. `u8` and any
other field kind are left exactly as written (see
`promote_be_field_type` in `lib/parser.mly`). The type checker never sees
a difference between a `packed be` struct and the identical struct with
every field spelled `u16be`/`u32be` by hand.

- **Does not unify with its host-order counterpart.** Reading a `u16be`/
  `u32be` field, casting it, or combining it with another value is checked
  distinctly from ordinary host-order integers -- crossing between wire and
  host order always needs an explicit `as` cast, the same discipline
  `{lo..<hi as base}` already requires to cross representations. A field's
  own declared type may itself be refined, `{lo..<hi as u16be}`/
  `{lo..<hi as u32be}`, with the same field-read/write semantics as any
  other refined struct field (see "Structs" above).
- **The only legal cast is `u16be <-> u16` or `u32be <-> u32`** (in either
  direction, and for either side already refined; `u16be` and `u32be` never
  cast to/from each other or any other integer type): `x as u16`/
  `x as u16be` perform a real byte-swap (`llvm.bswap.i16`/`.i32` for the
  32-bit pair) at the point of the cast. A refined source's range survives
  the cast unchanged (`{20..<1501 as u16be} as u16` -> `{20..<1501 as
  u16}`, no runtime check), the same range-preservation bare casts already
  get for ordinary bases.
- **Operator matrix**: `==`, `!=`, `&`, `|`, `^`, and unary `~` are allowed
  directly on `u16be`/`u32be` operands (result stays the same wire-order
  type); every other operator (`+ - * / %`, `<< >>`, and `< > <= >=`) is a
  compile error requiring an `as u16`/`as u32` conversion first. Comparing
  or masking two byte-swapped bit patterns as raw integers does not
  preserve numeric ordering on a little-endian target, so ordering
  comparisons in particular are never allowed on wire-order values
  directly. `==`/`!=`/bitwise ops ARE sound directly on the raw bytes
  because byte-swapping is a fixed bit-position permutation: `swap(a) OP
  swap(b) == swap(a OP b)` for any bitwise (position-independent) `OP`, so
  a conventionally-written literal operand (e.g. `0x0806` for an
  Ethertype, which already matches its own big-endian wire encoding
  byte-for-byte) is swapped at compile time to match the field's raw
  stored representation, and the comparison/mask result is correct once
  cast back `as u16`/`as u32` -- even for a mask that crosses a byte
  boundary (e.g. extracting IPv4's 13-bit fragment-offset subfield out of
  its combined 16-bit flags+offset field). The `x & k -> {0..<k+1}`
  range-proving optimization ordinary integers get (see "Refined
  Integer Types" above) is deliberately NOT applied to `u16be`/`u32be`: it
  would prove a bound on the raw bit pattern, which does not translate to a
  bound on the logical (post-swap) value language users actually reason
  about, since byte-swapping is not monotonic.
- See `linux_user/wire_endian/wire_endian.tkb` for a complete worked
  example (a packed struct with a plain and a refined `u16be` field plus a
  `u32be` field, overlaid on a raw wire buffer via a pointer cast,
  exercising the cast, equality, and bitwise-masking behavior above end to
  end for both widths).

## For Loops

`for i in lo..<hi { ... }` / `for i: T in lo..<hi { ... }` (`T` any of
the nine primitive integer bases, same set `{lo..<hi as base}` accepts).

- The counter's base follows the bounds' own type when they already
  agree (e.g. `for i in 0..<s.len` gives `i: usize`, matching `s.len`'s
  type) -- there is no hardcoded `i32` default.
- When *both* bounds are recognized compile-time constants (a literal,
  or a name resolving to an earlier `const`), the
  counter additionally carries the proven range `{lo..<hi}`.
- GitHub issue #312: when `hi` is not a compile-time constant but its own
  type is already a proven `{lo'..<hi' as base}` (e.g. a runtime
  parameter `limit: {0..<N as usize}`), the counter still carries the
  proven upper bound `hi'`, with the lower bound taken from `lo`'s own
  constant value when available, or `lo`'s own proven lower bound
  otherwise. `for i: usize in 0..<limit { arr[i] }` needs no `unsafe`
  wrapping as a result. Falls back to the unrefined base (no bullet
  above applies) only when neither side contributes a usable bound.
- `for i: T in ...` pins the counter's base explicitly. Required
  whenever nothing else in the loop determines a concrete type for `i`
  (e.g. the body only does `arr[i]`, which alone does not pin a type) --
  the compiler reports a clear "cannot determine a concrete type for
  for-loop counter" error asking for the annotation, rather than
  defaulting to `i32`. When both bounds are also compile-time constants,
  they are validated to fit the annotated base's representable range.
- The counter does not escape the loop body.

## Array/Slice Indexing Is usize-only; Pointer Indexing Is isize-only

`Index`, `AssignIndex`, and both bounds of an array/slice `SliceOf`
require the index/bound expression's type to be `usize` (or a
`{lo..<hi as usize}` refined value) -- not merely "some integer type". An
unresolved bare literal or for-loop counter used this way is pinned to
`usize` automatically. A refined value of a different base must cross
the boundary via `as usize`; a bare `ihl as usize` infers the tightest
`{lo..<hi as usize}` on its own from `ihl`'s already-proven range (see
"Bare-cast range inference" above), so it keeps the proof without
needing the range restated as `ihl as {0..<21 as usize}`.

Raw-pointer indexing (`p[i]`, `p[i] = v`, and `unsafe { p[lo..<hi] }`)
is intentionally separate and requires `isize` instead, matching signed
pointer-displacement semantics (mirrors Rust's own
`usize`-for-container-indexing / `isize`-for-pointer-offset split). It
carries no array-length guarantee and gets no runtime bounds check at
all, regardless of type.

## unsafe { ... }

`unsafe { expr }` gates constructs that assert something the compiler
cannot itself prove, and produces **no trap** -- it is a checkless
assertion the compiler is told to trust, distinct from a runtime check
(a check the compiler still doubts, which *does* generate a trap).
Currently gates exactly five things:

- Slice construction from a raw pointer, `unsafe { p[lo..<hi] }` -- the
  length assertion at a driver boundary.
- A slice/array-base subslice OR single-element index (load or store)
  whose bounds fail the interval/same-base proof (`unsafe { s[a..<b] }`
  or `unsafe { s[i] }`/`unsafe { s[i] = v }`, `s` a slice or a fixed
  array) -- skips the runtime check entirely, for the rare case that is
  correlated in a way plain interval reasoning cannot see (see
  HISTORY.md's P4c section for the two confirmed real-world subslice
  cases and why a more general relational domain wasn't built for them;
  the single-element-index form was added later, GitHub issue #249
  follow-up, as a narrow symmetric extension of the same escape hatch --
  `load_from_array`/`load_from_slice`/`store_to_array`/`store_to_slice`
  in `lib/llvm_gen.ml` each check `unsafe_depth` the same way
  `sub_of_slice` already did).
- Casting a non-literal integer to a pointer whose pointee is an
  `affine opaque struct` or `linear opaque struct` type (GitHub issue
  #15 follow-up) -- see "Affine Values" above and HISTORY.md's issue #15
  entry. Deliberately scoped to kinded targets, not pointer casts in
  general: a cast built entirely from compile-time integer literals or a
  real object's address (`&x`) needs no `unsafe`, which is what keeps
  trusted opaque-token constructors legal. Any OTHER non-literal-integer-
  to-pointer cast (an ordinary, non-affine, non-`io` target -- see GitHub
  issue #218) compiles with an audit warning. Each warned site must
  eventually become either a checked slice/array operation or an explicit
  `unsafe` boundary; the latter consumes the warning and is recognized by
  the unnecessary-unsafe lint as a real audit boundary. It remains
  warning-only while the slice migrations are completed. `*io T` targets are excluded from this warning population
  entirely -- see the next bullet, which gates them as a hard error instead.
- Constructing a `*io T` pointer from anything other than an
  already-`*io`-typed value (GitHub issue #316): both an explicit
  `x as *io T` cast and the direct-literal sugar (`let dr: *io u8 =
  0x09000000;`, "MMIO / Volatile" below) require `unsafe`. Unlike the
  affine/linear case just above, there is **no literal exemption** here
  -- a hardcoded MMIO address is exactly as unprovable to the compiler as
  a runtime-discovered one (a PCI BAR scan, a future dtb/ACPI table
  walk); the difference is human reviewability at the call site, which is
  what marking it `unsafe` is *for*, not a reason to exempt it from
  marking. Ordinary pointer arithmetic on an ALREADY `*io`-typed value
  (`io_ptr + 4`) stays unsafe-free, matching this language's general
  stance that `unsafe` does not extend to plain pointer arithmetic --
  only the moment a `*io` pointer is first minted from a non-`*io` source
  is gated. This is a narrower, deliberately separate decision from the
  #218 audit warning: `*io` requires an explicit boundary even for a
  literal address.
- Casting a slice (`[]T` or `[T; N..]`) to `*U` where `U` is neither `u8`
  nor the slice's own element type `T` (GitHub issue #218 follow-up,
  slice/struct-overlay variant) -- see "Slices" below. `*u8` and
  same-element-type targets stay unconditionally free (pointer
  extraction, not a reinterpretation); any other target needs the
  slice's proven minimum length to cover `sizeof(U)`, computed via the
  same target-independent rules `sizeof(...)` itself uses, or `unsafe`.

`unsafe` is **not** currently extended to general pointer
arithmetic/dereference, or an exhaustive enum's runtime variant check
(the latter is deliberately left checked: skipping it risks LLVM
`unreachable`-based undefined behavior, not merely a redundant check).

### unsafe { stmt* } -- block form

GitHub issue #315: `unsafe { ... }` also accepts a statement list, not
only a single expression, gating the exact same three constructs listed
above for every statement inside it (same `unsafe_depth` mechanism, just
widened around a `stmt list` instead of one `expr`). It does **not**
leak past its own closing brace -- a statement textually after the block
still needs its own `unsafe` -- and, like the plain `{ }` block, a `let`
declared inside does not escape it.

Reserve this for a short, already-justified run of statements that share
one trust rationale and have no unrelated logic between them -- in
practice, "construct one or two checked views from an unproven bound,
then immediately consume them" (e.g. `kernel/fs/ext2/ext2.tkb`'s
repeated `unsafe { let source = ...; let target = ...; slice_copy(target,
source); }` shape). Wrapping a whole function body or a loop body that
also touches unrelated, already-proven data is a misuse: it pulls safe
code into the audited region and dilutes `unsafe`'s value as a
grep-able, reviewable signal (see GitHub issue #315's own discussion --
an early draft of this feature wrapped an entire loop body and was
reverted for exactly this reason). The per-expression form remains the
default for an isolated unproven operation; reach for the block form
only when several sit back-to-back with nothing else between them.

This is independent of `!{unsafe}` (the function-level declaration,
above): a function using only the block form still needs its own
`!{unsafe}`, and the block form is not a way to make `!{unsafe}` alone
sufficient for a whole function body.

### Unnecessary-unsafe warning

The compiler tracks, per statement inside `unsafe { stmt* }` (recursively,
at every nesting depth) and per `unsafe { expr }`, whether anything
inside it actually elided a runtime check or asserted an otherwise-
illegal construct. If nothing did, it prints a non-fatal warning (`File
"...", line N, character C: warning: ...`) suggesting the statement be
moved outside the scope -- the same "audit density should match real
trust decisions" concern the block form's own scoping guidance above is
about, now checked mechanically instead of only by review. Always on
(not gated by a flag): cheap, reuses data the codegen already computes,
and a real build should have zero such warnings.

Two independent sources feed this determination. `llvm_gen.ml` tracks the
categories it itself decides at codegen time (single-element index
elision, subslice-with-unprovable-bounds elision, raw-pointer slice
construction). `type_inf.ml` separately tracks the pure type-checker-level
gates that have no codegen footprint to hook into (the affine/linear/
aligned/`*io` pointer-cast categories) -- each `check_*_needs_unsafe`
function records its own "genuinely consumed unsafe" determination the
moment it decides `unsafe_depth > 0` satisfies its requirement, so any
future such gate gets correct lint coverage automatically, with no
codegen-side change needed (GitHub issue #328). A statement or expression
is only reported as unnecessary when **neither** source found a
justification for it.

## --forbid-trap

`takibi ... --forbid-trap` rejects compilation if **any** runtime trap
check remains anywhere in the generated code (array bounds checks,
checked refined casts, exhaustive-enum casts), listing every unproven
site with its source location. Without the flag, the same code compiles
fine and gets a runtime check (`llvm.trap` on violation) -- the intended
permissive mode for early driver bring-up, where a trap firing is a
*signal that type information is missing*, not a shameful bug.

The judgment is deliberately type-level, not post-optimizer: an
optimizer pass happening to fold a check away at some LLVM version does
not count as proof, so the guarantee stays deterministic across LLVM
versions. `--forbid-trap` does **not** guarantee general memory safety
-- raw-pointer operations (`p[i]`, pointer arithmetic, `*p`) have no
bounds checks to begin with and are therefore invisible to it; that is
what the slice type and refined integer types exist to move code away
from.

## Known Limitations (Language-Level)

This is the canonical, current-behavior list of language-level known
limitations (function overloading, the flat top-level namespace,
`isize`, and scoped refinement-type inference are documented in their
own dedicated sections above instead of repeated here). For
hardware/driver-specific known limitations (interrupt builtins,
platform lifecycle, DMA barriers, etc.), see `AGENTS.md`'s own "Known
Limitations / Deferred Design Decisions" section. For the design
investigations behind any of these, see `HISTORY.md`.

- **No real module system, but source-level file dependencies exist.**
  `use "path/to/file.tkb";` (a top-level item, GitHub issue #55) lets a
  `.tkb` file declare which other files it needs; the compiler resolves
  the transitive closure from the command-line entry file(s) itself, so
  a missing dependency is caught the first time the referencing file is
  compiled, not only when some unrelated Makefile target's hand-curated
  file list happens to expose the gap (Makefile variable lists still list
  every file for staleness tracking, and files with no single path valid
  across every build target still can't `use` each other). What this is
  NOT: real separate compilation -- every file in the resolved closure is
  still concatenated into one flat AST and type-checked/codegen'd as a
  single whole-program unit; `use` only changes how the file list is
  computed, not the compilation model itself. See HISTORY.md's issue #55
  entries for the full design.
- **`sizeof`/`offsetof` cannot appear in an array-size position**
  (`[T; sizeof(Foo)]`) -- array sizes resolve in the parser, before
  struct layout exists. See HISTORY.md's "sizeof(T) Spans 4 Files" entry
  for why (parser-time vs. codegen-time resolution mismatch) and what
  combining them would require.
- **No general constant-expression arithmetic** between two named
  globals (`let X: i32 = A + B;`) -- see "Global Constant Folding" above
  for exactly what *is* supported.
- **No heap allocation.** Everything is static (BSS/data) or stack
  -allocated.
- Relational/correlated-bounds reasoning (two variables whose sum or
  relationship is invariant, but which the type system tracks as
  independent ranges) is not supported -- see HISTORY.md's P4c section.
  `unsafe` is the current escape hatch for the rare case this actually
  blocks a proof.
- **`match` on a primitive integer type supports only literal and
  `|`-separated OR-pattern literal patterns** (see "Match on Primitive
  Types," GitHub issue #151/#156) -- no range patterns (`0..<10 =>
  {...}`) and no string/byte-slice patterns (this project has no
  first-class string type, and what a string *pattern* should even mean
  -- exact equality? prefix? a runtime length check? -- is unresolved).
  Deferred until a concrete case needs one rather than designed
  speculatively now.
- **Indexing another Index expression's result directly is not
  supported** -- `a[i][j]` or `a[i].field` (as opposed to `a[i]` alone,
  or `s.field[i]` -- see just below) is a clear compile error ("not yet
  supported"), not silently accepted. `place_undecayed_type`
  (`lib/type_inf.ml`) would need an address-preserving codegen variant
  of `Index` that does not exist yet -- today's `Index` codegen always
  loads the final element value, discarding its address. GitHub issue
  #217 (2026-08-15, see HISTORY.md) closed the two gaps this bullet used
  to describe -- `Index`'s base was previously restricted to a bare
  identifier at the grammar level (`s.field[i]` was a hard `Syntax
  error`), and even the `let local = s.field; local[i]` workaround lost
  the field's checked array-ness (raw, unchecked `isize` pointer
  arithmetic instead of a real bounds check). `s.field[i]` now compiles
  directly with a real checked bounds check, for a FieldGet chain of any
  depth (`a.b.c[i]`); only Index-as-a-base remains unsupported.
