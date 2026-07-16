# takibi Language Specification

This file documents **the current behavior** of the takibi language: types,
syntax, and semantics as they exist today. It is a reference, not a
tutorial or a history.

For *why* the language looks this way -- design rationale, bugs found and
fixed, the chronological engineering log -- see `CLAUDE.md`. That file is
allowed to keep growing; this one is not: whenever a language feature
changes, update the relevant section here directly rather than appending a
new one.

No formal BNF grammar is included. The grammar is still evolving quickly
enough that a hand-maintained BNF would fall out of sync faster than it
would be useful; `lib/parser.mly` is the authoritative grammar. This file
describes behavior in prose instead.

File extension: `.tkb`. Compiler invocation: `takibi <file1.tkb>
[file2.tkb ...] [-o out.o] [--target <triple>] [--cpu <cpu>] [--features
<features>] [-g] [--forbid-trap] [--version]`. Multiple `.tkb` files are
concatenated (flat global namespace) before compilation -- there is no
module/import system beyond `use` (see "Known Limitations" below).

`-g` emits full DWARF debug information for source-level debugging. The
current implementation prioritizes practical GDB value inspection, so it
may preserve extra debug-only storage compared with an optimized build
without `-g`.

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
(refined integer subtype), `T @ n` (runtime integer singleton), and
`Name[n]` (indexed affine/linear runtime struct or erased view).

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
  rejected -- the base must always be spelled out.

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
- String literals: `"..."`, with `\n` `\r` `\t` `\\` `\"` escapes. Can be
  cast directly to a slice (`"..." as []u8`): the compile-time byte
  length (NUL excluded) becomes the minimum.
- Comments: `// line comment`, `/* block comment */`.

## Statements

- `let x = e` / `let x: T = e` -- immutable binding (initializer
  required, no reassignment, `&x` is a compile error).
- `let mut x = e` / `let mut x: T = e` -- mutable binding (reassignment
  allowed).
- At **global** scope: plain `let NAME: T = e;` is an immutable
  compile-time constant (reassignment and `&NAME` are compile errors, and
  it must have an initializer); `let mut NAME: T = e;` is a mutable
  global variable. `let mut x: T;` (no initializer) is allowed at global
  scope, relying on BSS zero-clearing.
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
  struct type with its own `align(M)` (see "Structs" below) overrides that
  struct's alignment for this one variable. Typical use: a stack-resident
  DMA buffer that must never share a cache line with unrelated data (a
  cache-line invalidate on an unaligned buffer can silently discard
  adjacent live stack data -- see `examples/common_stm32/sdmmc.tkb`'s
  `disk_read_bounce`, though that one is a global; `examples/align/
  align.tkb` demonstrates the local form).
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
- `return e` -- always takes an expression. A bare `return;` inside a
  `void` function is a syntax error; let the function fall through
  instead.
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
- `unsafe { expr }` -- see "unsafe" below.

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
  exactly.
- **`align(N)`** (N a power of two) aligns every variable and every
  element of a `[Name; K]` array of that struct type to N bytes, with
  tail padding automatically appended so `sizeof(struct) % N == 0`. Use
  for DMA descriptor rings, cache-line-separated data, SIMD types.

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
- To prevent mutation through a widened pointer from invalidating `T @ n`,
  singleton values cannot be addressed or placed in globals, ordinary struct
  fields, pointer targets, arrays, or slices. A direct field of an indexed
  owner is the supported persistent carrier in this slice.

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

Static parameters may use the same primitive integer sorts as indexed runtime
owners or an exhaustive enum. Enum constants are qualified, for example
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

The current `MutexGuard` and `KGuard` examples are non-indexed linear views.
Their lock pointers remain explicit runtime arguments, while lock/unlock
balance is checked in Delta without a forged null pointer, runtime result,
parameter, alloca, or debug value. They do not yet identify one particular
lock: an address/static-place sort is required before `MutexGuard[lock]` can
reject pairing a guard with the wrong explicit pointer.

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
address/place static sorts, propositions, and solver discharge are not
implemented. See `examples/common/http_conn_state.tkb` for the non-indexed
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
An unrestricted ordinary concrete struct may be copied as a payload; arrays,
indexed owner structs, and structs containing affine/linear fields are still
rejected. Construct a case with `Name::Case` or
`Name::Case(expr)`. A payload-bearing arm must bind its
payload, and a payload-less arm must not. A closed match without `_` must
cover every case; duplicate cases are rejected. A wildcard is allowed for
unrestricted or affine variants, but not for a linear variant because it
could hide a mandatory payload obligation.

A function returning a variant must explicitly return one on every
control-flow path; there is no implicit zero/default package.

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

Constructing `Acquired(owner)` packages the owner's static index without
adding runtime data. Matching `Acquired(frame)` opens the package with a
fresh rigid identity known only through `frame`'s inferred
`NetRxCpuOwned[desc]` type. Accessors can use that identity implicitly:

```
fn net_rx_len(frame: borrow NetRxCpuOwned[desc]) -> i32 {
    return frame.len;
}

fn net_rx_release(frame: sink NetRxCpuOwned[desc]) -> NetRxCanAcquire { ... }
fn net_transmit(frame: borrow NetRxCpuOwned[desc], len: i32) !{may_block} { ... }
```

The two current Ethernet backends intentionally allow one CPU-owned RX frame
at a time. Successful initialization creates the private affine
`NetRxCanAcquire` permission. `net_rx_acquire` consumes it: `None` returns a
replacement, while `Acquired` replaces it with the linear descriptor owner;
only `net_rx_release` consumes that owner and restores the permission. The
permission is affine because abandoning future acquisition is safe, but it
cannot be copied or reused after move. The owner is linear because returning
an active descriptor to DMA is mandatory. This prevents duplicate owner
minting; the added permit contributes no runtime payload to either result
variant. A private runtime initialization flag supplies the trusted base case:
on the current single-threaded boot path, only the first successful `net_init`
can mint the initial permission. Failed device discovery or link setup leaves
the flag clear and may be retried. Concurrent initialization is not guaranteed
without a future atomic/lock invariant.

`net_transmit` borrows the owner and derives the in-place reply buffer from its
private descriptor index. A caller can no longer satisfy the API with an
unrelated raw pointer. Under the current ABI this shared borrow passes the
owner's ordinary `{index, len}` aggregate read-only by value; no `desc` or
permission field is added. This does not yet make the slice returned by
`net_rx_frame` owner-bounded: retaining that unrestricted slice, releasing the
owner, and then reading it remains a known region/lifetime hole for a later
Core slice.

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
  `StaticSort` is a primitive integer or exhaustive enum, and the body must
  directly package an indexed runtime owner or indexed erased view;
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
global. It cannot be local, passed or returned by value, assigned as a whole,
or contained in an array, slice, tuple, variant, or another struct. Passing a
pointer to its stable global location is supported.

The owner field cannot be read, assigned, or addressed directly. Its only
operation is the reserved compiler builtin:

```takibi
stable_replace(guard, container.value, replacement)
```

It requires exactly three operands. `guard` is a bare variable whose type is
a linear erased view, `container.value` names a registered stable owner field,
and `replacement` has that field's linear variant type. The replacement is
moved into the slot and the previous value is returned. The returned linear
variant cannot be discarded: it must be placed in an owning binding, returned,
or matched, after which the usual all-path rules apply to every payload.
`stable_replace` borrows rather than consumes the guard.

The LLVM operation is one typed load of the old aggregate followed by one
typed store of the replacement. The guard, static indices, and existential
binders erase; there is no pointer/integer ownership encoding. The operation
is not a hardware atomic primitive. The declaring module must call it under
the runtime lock whose guard it was given.

This first invariant is intentionally limited. It statically seals the owner
field and makes every transfer across the boundary explicit and linear, but
it does not yet associate the guard with a particular lock address or prove a
private runtime flag equivalent to the variant tag. `examples/rtos_demo`
provides the positive ownership-bearing rendezvous; the focused failures are
`examples/stable_owner_without_guard_wrong` and
`examples/stable_owner_result_dropped_wrong`.

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

## Blocking and Interrupt Effects (Takibi Core Slices 4-5)

Checker effects are written after the return type:

```takibi
extern fn sem_wait(s: *i32) !{may_block};
fn mutex_lock(m: *i32) -> MutexGuard !{may_block} { ... }
fn IRQ_Handler() !{interrupt} { acknowledge_irq(); }
fn poll_callback() !{} { acknowledge_irq(); }
```

`may_block` is inferred transitively through resolved direct calls. An
explicit annotation is therefore an API contract and a seed, not a required
annotation on every caller. `interrupt` marks a root whose complete reachable
direct-call graph must not contain `may_block`; `interrupt_wait()` is
intrinsically blocking. Diagnostics include one offending call path.

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
`!{may_block}` permits blocking. `interrupt` is a declaration role and is
not legal in a function-pointer row.

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

Known limitation (shared with private globals): checks are by name/type
identity, not by resolved binding; and the declaring file itself remains
the trusted island -- privacy narrows the audit surface to that file, it
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

## Slices

`[]T` (minimum length 0) and `[T; N..]` (minimum length N) are a fat
`{ptr, usize}` value. `.len` (type `usize`) is the *runtime* length; the
type's own `N` is a compile-time-proven *lower bound* on that runtime
length, not the exact length.

**Creation**:
- `arr as []T` / `arr as [T; N..]` -- from an array variable; the
  array's static size becomes the slice's minimum.
- `s[a..<b]` on a slice or array -- subslice. When `a`/`b` are provably
  in range (constant bounds, or a proven `{lo..<hi}` range, including the
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

**Indexing**: `s[i]` needs no runtime check iff `i`'s proven range
satisfies `lo >= 0 && hi <= minimum`. Otherwise a runtime check against
the slice's actual (runtime) `.len` is generated.

**Length narrowing**: `if (s.len >= K) { ... }` upgrades the binding's
proven minimum to `K` for the branch, the same way integer narrowing
upgrades a value's range (see "Refined Integer Types"/narrowing below),
and is subject to the identical kill rule (an assignment, `&`-alias, or
rebinding of the slice inside the branch invalidates the narrowing).

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

## Owner-Derived Region Slices

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
- **Documented holes (v1)**: casting to a raw pointer (`f as *u8`) exits
  tracking (raw pointers are outside every safety story; this is how
  `net_transmit` internally reuses the buffer). Passing a tied slice to
  a callee while the owner is live is allowed and the callee's own
  retention is unchecked (all tracking is function-local). Laundering
  through a tuple or variant payload within one function is likewise
  untracked. Owner-name rebinding clears consumed status, so a stale
  slice tied to the OLD same-named owner escapes (the same name-keying
  limitation Stage 3a's field tracking accepted).

See `examples/net_rx_use_after_release_wrong` for the focused
compile-error fixture; the real positive fixtures are the network
examples themselves, whose frame access all flows through the annotated
`net_rx_frame`.

## Arrays and Pointers

- `[T; N]` decays to `*T` when used as an ordinary value (e.g. a function
  argument). Can only be *declared* at local/global scope.
- Array-size `N` may be a literal integer, the name of an earlier
  immutable global declared with a bare literal integer initializer, or
  `+`/`-`/`*`/`/` combining those (parentheses allowed), e.g.:
  ```
  let QUEUE_SIZE: i32 = 16;
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

## MMIO / Volatile

- `io T` is a volatile-qualified *value* type (same LLVM representation
  as `T`). `*io T` (`= TypePtr(TypeIo T)`) is a volatile pointer.
- `*p` where `p: *io T` is a volatile load; `*p = v` is a volatile store.
- `*p` where `p: *T` (regular pointer) is non-volatile (LLVM may
  optimize/reorder/eliminate it).
- Any direct access to a variable declared `io T` (e.g. `let flag: io
  i32;`) is volatile.
- `&io_var` automatically produces `*io T` -- no `as *io T` cast needed.
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
  (`let dr: *io u8 = 0x09000000;`) -- coerces via `inttoptr`.

**DMA / synchronization builtins** (no user-callable `extern fn`
needed): `dma_publish()`, `dma_consume()`, `device_fence()` (ARM/AArch64
lower to `DSB SY`; AMD64 to `MFENCE`; RISC-V uses direction-preserving
fences). Cache-aware: `dma_prepare_tx(ptr, len)`, `dma_prepare_rx(ptr,
len)`, `dma_finish_rx(ptr, len)` (Cortex-M7 rounds to 32-byte cache
lines and issues SCB DCCMVAC/DCIMVAC plus barriers). `signal_fence()` is
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
- `inline fn name(params) -> ret { ... }` marks a Takibi-defined function
  as an explicit inlining request. In normal optimized builds the backend
  emits LLVM's `alwaysinline` function attribute and runs the corresponding
  `always-inline` pass. Takibi does not otherwise inline ordinary `fn`
  definitions implicitly. `-g` builds currently disable the inlining pass
  to keep GDB stepping and local-variable visibility stable; use a
  non-`-g` build when checking object-code inlining behavior.
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
`i16` `i32` `i64` `u8` `u16` `u32` `u64` `usize`) or `isize`. The bare
`{lo..<hi}` form (no explicit base) is rejected -- always spell out the
base.

- **`lo` and `hi` must be bare integer literals** -- unlike an array size
  (`[T; N]`) or a `for i in lo..<hi` range, which both also accept a name
  resolving to a literal via the array-size-constant mechanism (a global
  `let NAME: T = LITERAL;`), `{lo..<hi as base}` naming a constant instead
  of restating the literal (e.g. `{0..<TOTAL_SECTORS as usize}`) is a
  syntax error, even when `TOTAL_SECTORS` itself has a literal
  initializer. Restate the literal value directly (with a comment noting
  which named constant it must track, if one exists).
- Bounds are validated against the chosen base's own representable range
  at parse time (e.g. `{0..<300 as u8}` is a compile error; `i64`/`u64`
  impose no upper-bound check, since their true range doesn't fit the
  bound-storage representation anyway).
- **Range propagation** through ordinary arithmetic preserves the
  operand's own base (not always `i32`): `{a..<b} + {c..<d} ->
  {a+c..<b+d-1}`; `{a..<b} + k -> {a+k..<b+k}` (k a literal, symmetric);
  `{a..<b} - {c..<d} -> {a-d+1..<b-c}`; `{a..<b} * k -> {a*k..<(b-1)*k+1}`
  for a positive literal *or* a Const_env-resolvable named constant `k`;
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
  -typed function argument. Narrowing is invalidated ("killed") for the
  rest of the branch if the branch (a) assigns to the narrowed variable,
  (b) takes its address (`&v`), or (c) rebinds the name (a `let`
  redeclaration or a `for`/`for-in` counter of the same name) -- the
  kill check is flow-insensitive within the branch (a write anywhere
  kills the whole branch body, not just after the write).
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

## For Loops

`for i in lo..<hi { ... }` / `for i: T in lo..<hi { ... }` (`T` any of
the nine primitive integer bases, same set `{lo..<hi as base}` accepts).

- The counter's base follows the bounds' own type when they already
  agree (e.g. `for i in 0..<s.len` gives `i: usize`, matching `s.len`'s
  type) -- there is no hardcoded `i32` default.
- When *both* bounds are recognized compile-time constants (a literal,
  or a name resolving to one via the array-size-constant mechanism), the
  counter additionally carries the proven range `{lo..<hi}`.
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
Currently gates exactly three things:

- Slice construction from a raw pointer, `unsafe { p[lo..<hi] }` -- the
  length assertion at a driver boundary.
- A slice/array-base subslice whose bounds fail the interval/same-base
  proof (`unsafe { s[a..<b] }` when `s` is already a slice) -- skips the
  runtime check entirely, for the rare case that is correlated in a way
  plain interval reasoning cannot see (see HISTORY.md's P4c section for
  the two confirmed real-world cases and why a more general relational
  domain wasn't built for them).
- Casting a non-literal integer to a pointer whose pointee is an
  `affine opaque struct` or `linear opaque struct` type (GitHub issue
  #15 follow-up) -- see "Affine Values" above and HISTORY.md's issue #15
  entry. Deliberately scoped to kinded targets, not pointer casts in
  general: a cast built entirely from compile-time integer literals or a
  real object's address (`&x`) needs no `unsafe`, which is what keeps
  trusted opaque-token constructors legal, but any OTHER pointer cast (including
  a non-literal integer cast to an ordinary, non-affine pointer, e.g. a
  runtime-discovered MMIO base address offset and cast to `*io T`) stays
  legal without `unsafe` too -- narrowed to affine targets specifically
  because a broader version was measured against this codebase's real
  MMIO drivers and found to demand `unsafe` on essentially every
  hardware register access, which would have made `unsafe` too common to
  carry any audit signal.

`unsafe` is **not** currently extended to general pointer
arithmetic/dereference, or an exhaustive enum's runtime variant check
(the latter is deliberately left checked: skipping it risks LLVM
`unreachable`-based undefined behavior, not merely a redundant check).

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
platform lifecycle, DMA barriers, etc.), see `CLAUDE.md`'s own "Known
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
