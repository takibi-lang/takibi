# takibi

A self-made language compiler written in OCaml 5.4.0. Generates native machine code via an LLVM 19 backend.
The ultimate goal is to implement a TCP/IP stack and run an HTTP server on Raspberry Pi 3 / RISC-V / STM32 bare-metal environments.

## Design Principle: Detect Errors at Compile Time

**In embedded products, zero runtime exceptions and panics is a hard requirement.**
If a runtime trap occurs in a bare-metal environment running timers, UART, and a TCP/IP stack,
the system will silently break or run amok. Nothing is communicated to the user.

- **Detect errors at compile time.** The ultimate goal is to make any access that the type system cannot prove into a compile error.
- **`llvm.trap` is a transitional safety net.** The current array bounds check (`icmp uge` → `llvm.trap`) aids debugging during development, but on AArch64 it translates to `brk #0` (Synchronous Abort) — a runtime error that must never occur in production code.
- **The range type `{lo..<hi}` is the solution.** If `hi <= N` and `lo >= 0` can be proven at compile time, no `llvm.trap` code is generated at all (Step 3.4).
- **When to use `int` vs `{lo..<hi}` is the programmer's responsibility**:
  - `int` = unknown range (MMIO, external input, etc.) → bounds check required
  - `{lo..<hi}` = value whose range the programmer knows → check can be omitted
  - Using an unchecked value read from MMIO directly as an array index is a bug hotbed; a bounds check appearing on `int` is **correct behavior**

**"Code with remaining bounds checks = code whose type annotations are still insufficient."**
The finished form of code is when index ranges are pinned at the type level using `for i in 0..<n` or `{lo..<hi}` annotations.

## Language Specification (Current)

- File extension: `.tkb`
- Types: `int`, `char`, `void`, `*T` (regular pointer, non-volatile), `io T` (volatile-qualified value type), `*io T` (volatile MMIO pointer = `TypePtr(TypeIo T)`), `[T; N]` (array type; decays to pointer in function arguments), `fn(T...) -> R` (function pointer type), `Name` (named struct type)
- Statements:
  - `let x = e` / `let x: T = e` — immutable variable declaration (initial value required, no reassignment)
  - `let mut x = e` / `let mut x: T = e` — mutable variable declaration (reassignment allowed)
  - `let x: T;` — uninitialized global variable declaration (global scope only)
  - `while`, `return`, assignment (`x = e`), pointer-deref assignment (`*p = v`)
  - `if (cond) { ... }` — `else` is optional
  - `if (cond) { ... } else { ... }` — regular if/else
  - `if (cond) { ... } else if (cond) { ... } else { ... }` — else-if chain
  - Taking the address of an immutable variable (`&x`) is a compile error (global variables are always treated as mutable, so `&global_var` is allowed)
- Expressions:
  - Integer literals (decimal and hex `0x...`)
  - Character literals (`'a'`, `'\n'`, `'\r'`, `'\t'`, `'\0'`, `'\\'`) — desugared to `IntLit (Char.code c)`
  - String literals (`"..."` — supports `\n` `\r` `\t` `\\` `\"` escapes)
  - Comments (`// line comment`, `/* block comment */`)
  - Arithmetic (`+` `-` `*` `/` `%`), comparison (`<` `>` `<=` `>=` `==` `!=`)
  - Pointer arithmetic: `ptr + int` / `ptr - int` → same pointer type (emitted as GEP). `int + ptr` also works. Codegen uses `build_neg + GEP`
  - Unary minus (`-expr`) — desugared to `BinOp(Sub, IntLit 0, expr)` in the parser
  - Logical OR (`||`)
  - Bitwise ops (`>>` logical right shift, `<<` left shift, `&` bitwise AND, `|` bitwise OR, `^` bitwise XOR) — both operands `int`, result `int`
  - Function call, `*expr` (dereference), `&ident` (address-of)
  - `expr as T` — explicit type cast (int ↔ char, `*T` → int, `*T` → `*U`). Lower precedence than arithmetic, so `a + b as char` = `(a + b) as char`
- `struct Name { field: type; ... }` — struct type definition (top-level only; fields are primitive types, pointer types, or other struct types)
- `let mut s: Name;` — struct variable declaration (local/global, always treated as mutable)
- `s.field` — field read (works for both `s: Name` and `s: *Name`, Zig-style)
- `s.field = v` — field write (direct dot assignment to a variable name only; not allowed as the left side of an expression)
- `&s` — take the address of a struct variable (returns `*Name`, used for pass-by-pointer)
- `extern fn name(params) -> ret;` — external assembly function declaration (emits an LLVM `declare`)
- MMIO / volatile: `io T` is a volatile-qualified value type. `*io T` (= `TypePtr(TypeIo T)`) is a volatile MMIO pointer
  - `*io T` pointer: `*p` is a volatile load, `*p = v` is a volatile store
  - `*T` (regular pointer) load/store is non-volatile (LLVM may optimize)
  - Direct accesses to an `io T` variable (e.g. `let flag: io int;`) are all volatile
  - `&io_var` automatically returns `*io T` (no `as *io int` cast needed)
  - Flags shared with interrupt handlers: read as `let flag: io int; while (flag == 0) {}`

## Build Commands

```bash
make build          # build the compiler (takibi) only (= dune build)
make test           # run unit tests
make qemutest       # run QEMU integration tests (build all examples and verify automatically)
make check          # run make test + make qemutest together
make qemu-echo      # manually run the echo server on QEMU virt (AArch64) (Ctrl-A X to quit)
make clean          # remove generated artifacts
```

## Directory Layout

```
lib/
  ast.ml          — AST definitions (includes TypePtr, TypeArray, TypeFn, Deref, AddrOf, AssignDeref, Cast)
  lexer.mll       — ocamllex (includes hex literals, & token, as keyword, ^ token, -> token, void keyword)
  parser.mly      — Menhir (includes pointer types, array types, function pointer types, prefix * / & / unary -, as cast)
  types.ml        — internal type (ty) + HM type inference output types + StringMap
  type_inf.ml     — Hindley-Milner type inference (immutable StringMap based)
  typechecker.ml  — external wrapper (called from main.ml)
  llvm_gen.ml     — LLVM IR generation and object file output
bin/
  main.ml         — CLI (`takibi <file.tkb> [-o out.o] [--target <triple>]`)
examples/
  common/
    startup.S     — _start → main, BSS zero-clear, AArch64 semihosting exit (shared by all examples)
    link.ld       — linker script (load address 0x40000000) (shared by all examples)
  hello/  start/  echo/  print_int/  print_hex/  print_ptr/
  mem/  array/  fizzbuzz/  fibonacci/  bubblesort/  ringbuf/
  callstack/  crc8/  djb2/  bump/  timer/  rtc/
  irq/  scheduler/  preempt/  semaphore/  condvar/  struct/  msgqueue/
  (each directory: see the leading comment in <name>.tkb for a description)
scripts/
  run_qemutest.sh — QEMU integration test script (FIFO sync and timing verification included)
test/
  test_takibi.ml  — Alcotest unit tests for parser / type_inf
```

## Important Design Notes

### LLVM 19 Opaque Pointers
LLVM 19 has only one pointer type (`pointer_type context`). The element type must be passed explicitly to `build_load`.
For this reason, `gen_expr` returns `(Ast.type_expr * llvalue)` rather than just `llvalue`.

### Type Inference Environment is an Immutable Map
`tyenv` is `(ty * bool) Types.StringMap.t` (`Map.Make(String)` based; bool = is_mutable).
`Hashtbl` is not used. The signature of `infer_stmt`:
```ocaml
val infer_stmt : tyenv -> fenv -> ty -> ty StringMap.t -> Ast.stmt
               -> tyenv * ty StringMap.t
```
The second element of the return value, `raw_locals`, is the Let-binding type map for codegen (contains both mutable and immutable bindings).

### Files to Update When Adding a binop
When adding a new constructor to `Ast.binop`:
- **Reusing an existing token (3 files)**: `lib/ast.ml`, `lib/type_inf.ml`, `lib/llvm_gen.ml`
- **Adding a new symbol (5 files)**: the 3 files above plus `lib/lexer.mll` (token definition) and `lib/parser.mly` (precedence and grammar rules)

OCaml's exhaustive match check will report any omissions as compile errors.

### Bitwise Operator Precedence (differs from C in some cases)
`&` (Band) has **higher** precedence than comparison operators (lower in C).
This means `n & mask == 0` is interpreted as `(n & mask) == 0` (avoiding a well-known C pitfall).
`^` (Bxor) is **lower** than comparison (same as C). `a ^ b == c` becomes `a ^ (b == c)`.
`|` (Bor) is **lower** than `^` (same as C). `a | b ^ c` becomes `a | (b ^ c)`.
`>>` (Shr) and `<<` (Shl) are higher than `&` and lower than `+/-`. `n >> 4 & 0xf` becomes `(n >> 4) & 0xf`.
`%` (Mod) has the same precedence as `*` and `/` (multiplicative group).

Precedence (low → high): `||` < `|` < `^` < comparison < `&` < `as` < `+/-` < `>>` `<<` < `*` `/` `%` < unary

### Soundness Condition for % Range Propagation

Range propagation for `n % m` (where m is a positive integer literal) returns `{0..<m}` **only when the left operand is guaranteed non-negative at the type level**.

- `n: {lo..<_}` with `lo >= 0` → `TRefinedInt(0, m)` / `TypeRefined(0, m)` (safe)
- `n: int` (possibly negative) → `TInt` / `TypeInt` (conservative fallback)

**Rationale**: LLVM's `srem` returns a negative remainder when the dividend is negative (`(-5) % 8 = -5`, not 3).
Unconditionally returning `{0..<m}` for `n: int` would cause `arr[(-5) % 8]` to be judged "safe",
producing an unsound buffer under-read with the bounds check omitted.

**Sync rule**: Both `lib/type_inf.ml` (`Mod` case) and `lib/llvm_gen.ml` (`Mod` case) have a `lo >= 0` guard.
Relaxing only one side causes them to disagree; always change them together.

### Unary Minus is Desugared in the Parser
`-expr` is converted to `BinOp(Sub, IntLit 0, expr)` (the `%prec UNARY` rule in `parser.mly`).
No changes to AST, type inference, or codegen are needed. `sub i32 0, %x` is also the canonical form of integer negation in LLVM IR.

### The as Cast Spans 5 Files
Files changed when `expr as T` was added:
1. `lib/ast.ml` — `Cast of type_expr * expr` constructor
2. `lib/lexer.mll` — `"as"` keyword
3. `lib/parser.mly` — `%nonassoc AS` (lower precedence than arithmetic), `expr AS type_expr` rule
4. `lib/type_inf.ml` — checks the source expression and returns the target type
5. `lib/llvm_gen.ml` — `coerce` function selects the conversion instruction per target type:
   - `int → char`: `trunc i32, i8`
   - `char/i1 → int`: `zext`
   - `int → *T`: `zext i32, i64` → `inttoptr` (MMIO address assignment)
   - `*T → int`: `ptrtoint ptr, i64` → `trunc i64, i32` (displaying a pointer value)
   - `*T → *U`: **no-op** (in LLVM 19, all pointers are the same `ptr` type, so the leading `if vty = dst_ll then v` in `coerce` applies; no compiler change needed)

### Codegen for Immutable and Mutable Variables
The locals table in `llvm_gen.ml` is managed as `(string, local_binding) Hashtbl.t`.

```ocaml
type local_binding =
  | Imm of Ast.type_expr * llvalue  (* immutable: no alloca; holds the SSA value directly *)
  | Mut of Ast.type_expr * llvalue  (* mutable: alloca pointer *)
```

- `let x = e` → evaluates the expression to an llvalue and registers it as `Imm`. No `alloca/store/load` is generated.
- `let mut x = e` → allocates an `alloca` in the entry block (`Mut`) and emits a `store` at the declaration site.
- Function arguments are always `Mut` (parameters can be reassigned).

**`gen_stmt` is defined inside `gen_func`**. This is because the type of an immutable `let` must be resolved via the `res` function that references the HM type inference result. As an OCaml closure, `res` in the `gen_func` scope can be referenced naturally.

### Global Arrays and Uninitialized Global Variables
Uninitialized global variable declarations such as `let heap: [char; 256];` are supported.

- Emitted as `undef` in LLVM IR (not `zeroinitializer`)
- Since `startup.S` zero-clears the BSS section, values are always zero at runtime
- Array type `[T; N]` can only be declared in global scope. Decays to `*T` in function arguments.

Uninitialized case in `gen_global`:
```ocaml
| None -> undef llty  (* BSS is zero-cleared by startup.S, so this is safe *)
```

### Function Pointer Types Span 5 Files
Files changed when the `fn(T...) -> R` type was added:
1. `lib/ast.ml` — `TypeFn of type_expr list * type_expr` constructor
2. `lib/lexer.mll` — `"->"` token, `"void"` keyword
3. `lib/parser.mly` — `fn_type` non-terminal (`FN LPAREN type_list RPAREN ARROW type_expr`)
4. `lib/type_inf.ml` — `Var` retrieves a function name as `TFun` from `fenv`; `Call` supports both direct and indirect calls
5. `lib/llvm_gen.ml` — `ltype_of_ast (TypeFn _) = pointer_type context` (opaque ptr); indirect calls reconstruct `function_type` and use `build_call`

**Function pointers in LLVM 19**:
LLVM 19 has a single pointer kind (`ptr`, opaque pointer). `fn(int) -> char` and `fn() -> void` are both the same `ptr` in LLVM IR. The takibi type checker enforces type distinction; correct calling conventions are generated by passing `function_type` to `build_call`. Unlike C's `void*`, takibi's type checker enforces signature compatibility.

### extern fn Spans 5 Files
Files changed when external assembly function declarations like `extern fn timer_init();` were added:
1. `lib/ast.ml` — `ExternFuncDef of ident * (ident * type_expr option) list * type_expr option`
2. `lib/lexer.mll` — `"extern"` keyword
3. `lib/parser.mly` — `EXTERN FN IDENT LPAREN params RPAREN (ARROW type_expr)? SEMI` rule
4. `lib/type_inf.ml` — adds `TFun` in Pass 1 for `fenv`; `ExternFuncDef _ -> m` in the `genv` fold
5. `lib/llvm_gen.ml` — emits `declare_function` in Pass 1 (Pass 2 does `ExternFuncDef _ -> ()`)

### Struct Implementation (7 Files)

Files changed when `struct Name { field: type; }` was added:
1. `lib/ast.ml` — `TypeNamed of string` (type), `FieldGet of expr * string` (expr), `AssignField of expr * string * expr` (stmt), `StructDef of string * (string * type_expr) list` (top-level)
2. `lib/types.ml` — `TStruct of string` (internal type), added `program_types.structs` field
3. `lib/lexer.mll` — `"struct"` → `STRUCT`, `'.'` → `DOT` token
4. `lib/parser.mly` — `%left DOT` (highest precedence), `struct_fields` rule, `IDENT DOT IDENT ASSIGN expr SEMI` assignment statement, `expr DOT IDENT` field read expression, `IDENT` → `TypeNamed` type expression
5. `lib/type_inf.ml` — `senv : (string * Ast.type_expr) list StringMap.t` collected in Pass 0 and threaded through all inference functions
6. `lib/llvm_gen.ml` — registers `struct_type context fields` in Pass 0; `TypeNamed` returns the alloca/global pointer as-is (same approach as arrays); `FieldGet` uses `build_in_bounds_gep` + load; `AssignField` uses GEP + store
7. `test/test_takibi.ml` + `examples/struct/` — parser/type-inference tests + QEMU demo

**Struct variable codegen design** (unified approach with arrays):
- `let mut s: Name;` local → `alloca [struct_type]` → `Mut (TypeNamed "Name", alloca_ptr)`
- `Var "s"` where `TypeNamed _` → return the alloca pointer as-is (no load)
- Global struct variables are handled the same way (value of `define_global` = return the pointer as-is)
- `s.field` / `p.field` where `p: *Name` → GEP `[0, field_idx]` → load (auto-distinguished by type check)
- `s.field = v` → GEP → store (non-volatile; not MMIO)
- `&s` → return the alloca pointer as `*Name` (for pass-by-pointer)

**Current limitations**:
- Field assignment only in `ident.field = v` form (LHS is a single variable name only)
- Global struct variable as `let g: Name;` only (`let mut` is not supported in global scope; always mutable)

### Synchronization Primitive Design and Current Limitations

Synchronization primitives have a 3-layer structure:

```
assembly (ldaxr / stlxr)
  └── sem_wait / sem_post          ← atomic guarantee only here (extern fn)

takibi
  └── mutex_lock / mutex_unlock    ← named wrappers around sem_wait/sem_post
  └── cond_wait / cond_signal      ← sequence counter method (written in takibi)
```

See the comment in each `.tkb` file for implementation details (`condvar.tkb` explains missed-wakeup prevention in `cond_wait`).

**Current limitation: single-core only**
- `cond_signal`'s `*seq = *seq + 1` is not atomic. The convention of calling it while holding the mutex makes it correct on a single core, but it is insufficient for multi-core.
- `cond_wait`'s spin `while (*seq == s) {}` is a plain volatile load without a hardware memory barrier. Multi-core requires replacing it with `ldar` (load-acquire).

### Distinguishing MMIO from Regular Pointers (`io T`, `*io T` vs `*T`)

**Type relationships**:
- `io T` — volatile-qualified value type (AST: `TypeIo T`). LLVM type is the same as T. A storage qualifier.
- `*io T` — volatile MMIO pointer (AST: `TypePtr (TypeIo T)`). LLVM type is opaque ptr.
- `*T` — regular pointer (AST: `TypePtr T`). Non-volatile.

**Where volatile is generated**:
- `let irq_done: io int;` — all reads and writes to this global variable are volatile
- `irq_done = 1;` → volatile store (automatic)
- `while (irq_done == 0) {}` → `irq_done` is a direct volatile load (automatic)
- `&irq_done` → automatically returns `*io int` (no `as *io int` cast needed)
- Struct field `done: io int;` → `s.done = 1;` is a volatile store
- `*p` where `p: *io int` → volatile load
- `*p = v` where `p: *io int` → volatile store
- `p.field` where `p: *io Struct` → volatile load (`through_io` flag)

**`io` is stripped on Deref**: `*p` where `p: *io int` → result type is `int` (not `io`). Volatile is confined to `set_volatile true` on the load.

- `*io T` is a compiler-level distinction. CPU-level memory barriers are provided by `ldaxr/stlxr` (extern fn).
- Pointer arithmetic `*io T + int` → remains `*io T` (matches `TypePtr _`)
- `int as *io T` — MMIO address literal assignment (inttoptr coercion, `TypePtr _` case)

### Volatile Reads of Global Variables (Interrupt-Shared Flags)
LLVM may hoist a global variable load out of a tight loop like `while (flag == 0) {}`,
resulting in an infinite loop (`cbz reg, self`).
Use `io int` for flags shared with interrupt handlers:

Declare flags shared with interrupt handlers as `io int`:
```takibi
let sched_done: io int = 0;        // volatile global declaration
sched_done = 1;                    // volatile store (automatic)
let p: *io int = &sched_done;      // &io_var automatically returns *io int (no cast needed)
while (*p == 0) {}                 // volatile load — prevents hoisting
```
`AddrOf (Var name)` where `name: io T` → automatically returns `TypePtr (TypeIo T)` = `*io T`. No cast needed.

### Integer Literal → Pointer Coercion
`let dr: *io char = 0x09000000;` assigns an integer literal to an MMIO pointer type variable.
The `coerce` function in `llvm_gen.ml` emits `inttoptr(zext(i32, i64), ptr)` (`TypePtr _` case).

### Makefile Example Registration Convention
Adding a name to the `EXAMPLES` list is all that's needed to register a new example.
Convention: `examples/<name>/<name>.tkb` → `examples/<name>/kernel.elf`

```makefile
EXAMPLES := start hello echo print_int print_hex print_ptr mem array fizzbuzz fibonacci bubblesort ringbuf callstack crc8 djb2 bump timer rtc irq scheduler preempt semaphore condvar struct msgqueue  # ← just add the name here
```

Only targets that require interactive manual startup (like `qemu-echo`) are added individually.
Automatable programs are registered in `qemutest` by providing `.expected` / `.stdin` files.
Use `run_test_timed` for tests that need timing verification (to confirm a delay actually waited).

**Examples requiring extra assembly** (those with `*_asm.S`) are excluded from the `GENERIC_KERNELS` filter and given individual link rules:
```makefile
GENERIC_KERNELS := $(filter-out examples/preempt/kernel.elf examples/semaphore/kernel.elf examples/condvar/kernel.elf, $(ALL_KERNELS))
```
When adding a new `*_asm.S`, three things are required: adding it to this filter, writing a dedicated link rule, and adding the object to `rm -f` in `clean`.

## QEMU Bare-Metal (AArch64)

- Machine: `virt`, CPU: `cortex-a53`
- PL011 UART register: `0x09000000` (QEMU pre-initializes it, so no baud rate setup needed)
- PL031 RTC register: `0x09010000` (RTCDR: +0, RTCCR: +0x0C) — 1-second resolution time counter
  - RTCCR always returns 1 in QEMU (RTC is always running)
  - ARM Generic Timer (`mrs` instruction) cannot be called directly from takibi (it is a system register)
- Load address: `0x40000000` (start of QEMU virt RAM)
- Semihosting exit: `SYS_EXIT` (x0=0x18) + AArch64 extended format
  - x1 is not a value but a pointer to a 2-word block: `[ADP_Stopped_ApplicationExit, 0]`
  - QEMU launch option: `-semihosting-config enable=on,target=native`
- Assembler: `llvm-mc-19`, linker: `ld.lld-19`
- QEMU integration tests feed stdin synchronously via a named pipe (FIFO) (`scripts/run_qemutest.sh`)
- `startup.S` enables IRQ/FIQ for all examples (`msr DAIFClr, #0x3`). All interrupts are disabled when the GIC is not initialized, so existing examples are unaffected.
- Exception vector table (2KB aligned): All IRQ/FIQ entries for EL1t/EL1h are wired to `irq_entry`. `irq_entry` saves all registers then calls `irq_dispatch`. If a takibi program does not define `irq_dispatch`, a `.weak` no-op is used.
- GICv2 (`0x08000000`): built into QEMU virt. Without security extensions (`secure=on` not used), GICD_CTLR bit0=EnableGrp0. All SPIs stay Group0 unless GICD_IGROUPR is written. With GICC_CTLR.FIQEn=0 (default), Group0 interrupts arrive as IRQ (0x280: EL1h IRQ vector). Setting FIQEn=1 is required for them to arrive as FIQ (0x300).
- ARM Generic Timer (EL1 physical timer):
  - `cntp_tval_el0`: countdown timer value register (count until fire)
  - `cntp_ctl_el0`: bit0=ENABLE (1 to enable)
  - `cntfrq_el0`: timer clock frequency (62500000 = 62.5 MHz on QEMU virt)
  - Connected to the GIC via PPI #30 (GICD_ISENABLER0 bit30)
  - To fire at ~15 ms intervals: `lsr x0, cntfrq, #6` → `msr cntp_tval_el0, x0`
  - The virtual timer (CNTV, PPI #27) requires EL2 hypervisor configuration on QEMU virt, so use the physical timer (CNTP, PPI #30) for bare-metal EL1.

## Instructions for Claude Code

- **Do not create git commits.** Only do so when the user explicitly requests it.
- Prefer idiomatic OCaml style. Use `Map.Make(String)` over `Hashtbl`.
- Do not use the `base` package (it causes friction at the boundary with LLVM bindings).
- The user is an OCaml beginner, so explain the reason for code changes from the perspective of "why write it this way."
- **Do not save memories to `~/.claude`.** Consolidate project-specific information in this file (it cannot be shared across environments).

## Dependencies

```
ocaml 5.4.0, dune, menhir
llvm-19 OCaml bindings (llvm, llvm.analysis, llvm.target, llvm.all_backends)
ppx_deriving.show
llvm-mc-19, ld.lld-19   (for bare-metal builds)
qemu-system-aarch64     (for QEMU execution)
```
