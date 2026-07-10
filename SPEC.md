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
(refined integer subtype).

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
- **`fn(T...) -> R`** is a function pointer type. LLVM 19 has a single
  opaque pointer kind, so all function pointers are the same `ptr` at the
  LLVM level; takibi's type checker is what enforces signature
  compatibility.
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
- Assignment: `x = e`, `*p = v`, `arr[i] = v`, `s.field = v`. Compound
  assignments `+=` `-=` `|=` `&=` `^=` `<<=` `>>=` desugar to `x = x op
  rhs` and are supported on all five assignable forms above (`*p`,
  `*(expr)`, `arr[i]`, `s.field`, and a plain variable).
- `match expr { arms }` -- see "Enums" below.

## Expressions and Operators

- Arithmetic: `+` `-` `*` `/` `%`. Comparison: `<` `>` `<=` `>=` `==`
  `!=`. Logical: `||`, `&&` (via `if`/`while` condition context).
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

## Affine Opaque Structs (Ownership Handles)

```
affine opaque struct Token;

fn make() -> *Token { ... }
fn inspect(t: borrow *Token) -> usize { ... }   // non-consuming
fn release(t: *Token) { ... }                    // consuming

fn good() {
    let t: *Token = make();
    inspect(t);      // OK: borrow does not consume
    inspect(t);       // OK: still not consumed, may be borrowed any number of times
    release(t);        // consumes t
    // release(t);     // would be a compile error: "affine value 't' was already consumed"
    // inspect(t);     // likewise, after release
}
```

`affine opaque struct Name;` marks pointers to that type (`*Name`) as
affine handles: this is the type-level tool for statically rejecting
use-after-release and double-release bugs on driver-owned resources (the
motivating case is a network RX descriptor: `net_rx_acquire() ->
*NetRxCpuOwned`, borrowed any number of times through `net_rx_len`/
`net_rx_frame`, then consumed exactly once by `net_rx_release` -- see
`examples/common_qemu/virtio_mmio.tkb` / `examples/common_stm32/eth.tkb`).

- A function parameter of plain affine-pointer type (`t: *Name`, no
  `borrow`) **consumes** the argument: after such a call, using the same
  local variable/parameter again anywhere in the function (another call,
  a `return`, another consuming use) is a compile error ("affine value
  'NAME' was already consumed"). A `return` of the affine value itself
  consumes it, exactly like passing it to a consuming parameter, when
  the function's own return type is affine.
- **`borrow *Name`** -- valid **only** as a function parameter type, and
  only for a pointer to an affine opaque type. Calling through a
  `borrow *Name` parameter does **not** consume the argument, so it may
  be borrowed an unlimited number of times before (or without ever)
  being consumed. Using `borrow` on any other parameter type is a
  compile error ("borrow is only valid on a pointer to an affine opaque
  struct parameter" / "...only valid in function parameter types").
- **Affine, not linear**: a handle may be silently **dropped** (never
  consumed) with no error -- this facility only catches *too many*
  consumptions, never *too few*. There is no destructor/`defer`
  mechanism.
- **Loop restriction**: consuming an affine value that was declared
  *outside* a loop (`while`/`for`/`for-in`) from *inside* that loop's
  body is conservatively rejected at compile time ("cannot consume an
  affine value declared outside a loop inside that loop"), since a real
  loop could otherwise consume the same handle on more than one
  iteration. A handle both declared and consumed inside the same loop
  iteration is fine.
- **`if`/`else` and `match`**: consuming a handle in only one branch is
  allowed; after the branch, the value is conservatively treated as
  "possibly consumed" (the moved-sets of every branch/arm are unioned),
  so a later use after only-one-branch-consumed code is still rejected
  even on the path that didn't consume it.
- **Deliberately restricted, not a general ownership/borrow-checker
  system**: this tracking is local to a single function body (no
  cross-function or struct-field-level tracking), applies only to
  pointers to a type explicitly declared `affine opaque struct`, and an
  explicit pointer cast (`t as *OtherType`, `t as usize`) remains an
  unchecked escape hatch that silently drops out of affine tracking.

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

- `fn(T...) -> R` is a first-class function pointer type (see "Types"
  above).
- `extern fn name(params) -> ret;` declares an externally-defined
  (assembly-implemented) function, emitting an LLVM `declare`. `extern
  fn` is **not** overloadable -- its unmangled symbol name is an external
  ABI contract.
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
  signed/unsigned integer width including `isize`/`usize`.

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
Currently gates exactly two things:

- Slice construction from a raw pointer, `unsafe { p[lo..<hi] }` -- the
  length assertion at a driver boundary.
- A slice/array-base subslice whose bounds fail the interval/same-base
  proof (`unsafe { s[a..<b] }` when `s` is already a slice) -- skips the
  runtime check entirely, for the rare case that is correlated in a way
  plain interval reasoning cannot see (see CLAUDE.md's P4c section for
  the two confirmed real-world cases and why a more general relational
  domain wasn't built for them).

`unsafe` is **not** currently extended to integer-literal-to-pointer
coercions, general pointer arithmetic/dereference, or an exhaustive
enum's runtime variant check (the last of those is deliberately left
checked: skipping it risks LLVM `unreachable`-based undefined behavior,
not merely a redundant check).

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

See `CLAUDE.md`'s "Known Limitations / Deferred Design Decisions" for
the full, continuously-updated list including hardware/driver-specific
items. The ones most likely to matter when writing new `.tkb` code:

- **No module/import system.** Which shared `.tkb` files get
  concatenated into a given build is decided entirely by hand-maintained
  Makefile variable lists; nothing in the source declares "this file
  needs that file."
- **`sizeof`/`offsetof` cannot appear in an array-size position**
  (`[T; sizeof(Foo)]`) -- array sizes resolve in the parser, before
  struct layout exists.
- **No general constant-expression arithmetic** between two named
  globals (`let X: i32 = A + B;`) -- see "Global Constant Folding" above
  for exactly what *is* supported.
- **No heap allocation.** Everything is static (BSS/data) or stack
  -allocated.
- Relational/correlated-bounds reasoning (two variables whose sum or
  relationship is invariant, but which the type system tracks as
  independent ranges) is not supported -- see CLAUDE.md's P4c section.
  `unsafe` is the current escape hatch for the rare case this actually
  blocks a proof.
