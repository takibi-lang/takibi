# takibi

A self-made language compiler written in OCaml 5.4.0. Generates native machine code via an LLVM 19 backend.
The ultimate goal is to implement a TCP/IP stack and run an HTTP server on Raspberry Pi 3 / RISC-V / STM32 bare-metal environments.

## Design Principle: Detect Errors at Compile Time

**In embedded products, zero runtime exceptions and panics is a hard requirement.**
If a runtime trap occurs in a bare-metal environment running timers, UART, and a TCP/IP stack,
the system will silently break or run amok. Nothing is communicated to the user.

- **Detect errors at compile time.** The ultimate goal is to make any access that the type system cannot prove into a compile error.
- **`llvm.trap` is a transitional safety net.** The current array bounds check (`icmp uge` -> `llvm.trap`) aids debugging during development, but on AArch64 it translates to `brk #0` (Synchronous Abort) -- a runtime error that must never occur in production code.
- **The range type `{lo..<hi}` is the solution.** If `hi <= N` and `lo >= 0` can be proven at compile time, no `llvm.trap` code is generated at all.
- **When to use `i32` vs `{lo..<hi}` is the programmer's responsibility**:
  - `i32` = unknown range (MMIO, external input, etc.) -> bounds check required
  - `{lo..<hi}` = value whose range the programmer knows -> check can be omitted
  - Using an unchecked value read from MMIO directly as an array index is a bug hotbed; a bounds check appearing on `i32` is **correct behavior**

**"Code with remaining bounds checks = code whose type annotations are still insufficient."**
The finished form of code is when index ranges are pinned at the type level using `for i in 0..<n` or `{lo..<hi}` annotations.

## Language Specification (Current)

- File extension: `.tkb`
- Types: `bool`, `i8`, `i16`, `i32`, `i64`, `u8`, `u16`, `u32`, `u64`, `usize` (pointer-sized unsigned integer; LLVM width follows the target's actual pointer size via `Llvm_gen.usize_lltype ()` -- `i64` on AArch64/RISC-V64, `i32` on Cortex-M/STM32; falls back to `i64` when no target machine is configured, e.g. in unit tests), `void`, `*T` (regular pointer, non-volatile), `io T` (volatile-qualified value type), `*io T` (volatile MMIO pointer = `TypePtr(TypeIo T)`), `[T; N]` (array type; decays to pointer in function arguments), `fn(T...) -> R` (function pointer type), `Name` (named struct type), `{lo..<hi}` (refined integer subtype)
- Statements:
  - `let x = e` / `let x: T = e` -- immutable variable declaration (initial value required, no reassignment)
  - `let mut x = e` / `let mut x: T = e` -- mutable variable declaration (reassignment allowed)
  - Global scope mirrors this: plain `let NAME: T = e;` is an immutable compile-time constant (reassignment and `&NAME` are compile errors, and it must have an initializer); `let mut NAME: T = e;` is a mutable global variable. `let mut x: T;` (no initializer) is allowed for global scope only, relying on BSS zero-clear.
  - `[T; N]` array size `N` may be a literal integer, or the name of an immutable global declared earlier (in the concatenated source) with a bare literal integer initializer, e.g. `let QUEUE_SIZE: i32 = 16; let mut ring: [T; QUEUE_SIZE];`. Resolved entirely in the parser (see "Array-Size Constants" below); no forward references, no constant folding.
  - `let mut x: T align(N);` -- global variable with N-byte alignment (N must be a power of two). Emits `set_alignment N` on the LLVM global. Use for DMA descriptor rings (`align(4096)`), cache-line buffers (`align(64)`), etc. Optional initializer: `let mut x: T align(N) = e;` (or plain `let x: T align(N) = e;` for an immutable aligned constant). Local variable alignment is not supported.
  - `while`, `return` (always takes an expression -- bare `return;` in a `void` function is a syntax error; let the function fall through instead), assignment (`x = e`), pointer-deref assignment (`*p = v`)
  - `break` -- exits the innermost `while` or `for` loop immediately. Compile error outside a loop.
  - `continue` -- skips to the next iteration of the innermost loop. For `for`, the counter is incremented first. Compile error outside a loop.
  - `if (cond) { ... }` -- `else` is optional
  - `if (cond) { ... } else { ... }` -- regular if/else
  - `if (cond) { ... } else if (cond) { ... } else { ... }` -- else-if chain
  - Taking the address of an immutable variable (`&x`) is a compile error (global variables are always treated as mutable, so `&global_var` is allowed)
- Expressions:
  - Integer literals (decimal and hex `0x...`)
  - Character literals (`'a'`, `'\n'`, `'\r'`, `'\t'`, `'\0'`, `'\\'`) -- desugared to `IntLit (Char.code c)`
  - String literals (`"..."` -- supports `\n` `\r` `\t` `\\` `\"` escapes)
  - Comments (`// line comment`, `/* block comment */`)
  - Arithmetic (`+` `-` `*` `/` `%`), comparison (`<` `>` `<=` `>=` `==` `!=`)
  - Pointer arithmetic: `ptr + i32` / `ptr - i32` -> same pointer type (emitted as GEP). `i32 + ptr` also works. Codegen uses `build_neg + GEP`
  - Unary minus (`-expr`) -- desugared to `BinOp(Sub, IntLit 0, expr)` in the parser
  - Logical OR (`||`)
  - Bitwise NOT: `~expr` -- flips all bits; returns the same type as the operand (desugars to LLVM `not`)
  - Bitwise ops (`>>` right shift (arithmetic for signed types, logical for unsigned), `<<` left shift, `&` bitwise AND, `|` bitwise OR, `^` bitwise XOR) -- both operands must be the same integer type
  - Compound assignments: `+=` `-=` `|=` `&=` `^=` `<<=` `>>=` -- desugared in the parser to `x = x op rhs`; supported on all five LHS forms (variable, `*p`, `*(expr)`, `arr[i]`, `s.field`)
  - Function call, `*expr` (dereference), `&ident` (address-of)
  - `expr as T` -- explicit type cast (i32 <-> u8, `*T` -> i32, `*T` -> `*U`). Lower precedence than arithmetic, so `a + b as u8` = `(a + b) as u8`
  - `sizeof(T)` -- compile-time size of `T` in bytes, type `usize` (fixed, not a polymorphic literal; compare/assign against other integer types requires an explicit `as` cast, e.g. `len >= sizeof(Hdr)` requires `len: usize`). Reads the same LLVM DataLayout used for struct tail-padding, so `sizeof` on a `packed` or `align(N)` struct reflects the true in-memory size.
- `struct Name { field: type; ... }` -- struct type definition (top-level only; fields are primitive types, pointer types, or other struct types)
- `let mut s: Name;` -- struct variable declaration (local/global, always treated as mutable)
- `s.field` -- field read (works for both `s: Name` and `s: *Name`, Zig-style)
- `s.field = v` -- field write (direct dot assignment to a variable name only; not allowed as the left side of an expression)
- `&s` -- take the address of a struct variable (returns `*Name`, used for pass-by-pointer)
- `extern fn name(params) -> ret;` -- external assembly function declaration (emits an LLVM `declare`)
- MMIO / volatile: `io T` is a volatile-qualified value type. `*io T` (= `TypePtr(TypeIo T)`) is a volatile MMIO pointer
  - `*io T` pointer: `*p` is a volatile load, `*p = v` is a volatile store
  - `*T` (regular pointer) load/store is non-volatile (LLVM may optimize)
  - Direct accesses to an `io T` variable (e.g. `let flag: io i32;`) are all volatile
  - `&io_var` automatically returns `*io T` (no `as *io i32` cast needed)
  - Flags shared with interrupt handlers: read as `let flag: io i32; while (flag == 0) {}`

## Build Commands

```bash
make build          # build the compiler (takibi) only (= dune build)
make test           # run unit tests
make qemutest       # run QEMU integration tests (build all examples and verify automatically)
make stm32build     # cross-compile every ported example for STM32F746G-DISCOVERY (no hardware needed)
make check          # run langcheck + test + stm32build + qemutest together
make hwcheck        # like stm32build, but also flashes + UART-diffs against real STM32 hardware
make hwcheck-net    # real-Ethernet hardware tests (needs the board's Ethernet port wired to this host)
make clean          # remove generated artifacts
```

**Parallel by default** (`Makefile`'s `MAKEFLAGS += -j$(shell nproc)`): every `.tkb` example
is an independent build, so `make check`/`make stm32build`/etc. fan out across all cores with
no flag needed. Pass `-j1` explicitly (`make -j1 check`) to force serial execution back, e.g.
when a build error's parallel-interleaved output needs to be read one recipe at a time.
`-Otarget` (which buffers each recipe's output into one clean block) was tried and rejected --
it hides progress until each recipe finishes, worse for watching a long build than the
occasional interleaved line.

**`TAKIBI` invokes `_build/default/bin/main.exe` directly, not `dune exec takibi --`**: `dune
exec` re-locks the dune workspace on every call, which serializes what should be independent
parallel compiles. Every per-example object-file rule depends on the `build` target (`dune
build`) as an **order-only** prerequisite (`| build`, not a plain prerequisite) -- `build` is
`.PHONY`, and a plain (non-order-only) phony prerequisite makes every dependent target look
permanently out-of-date, which was silently forcing a full rebuild of all ~50 examples on
every invocation before this was fixed. Order-only prerequisites are still built when needed,
but don't affect whether the depending target itself is considered stale, so make's normal
`.tkb`-timestamp-based skip-if-unchanged logic works correctly again.

**Known dune footgun found while wiring up `-j`**: running `dune build` and `dune test`
concurrently (e.g. two independent Make recipes under `make -j`) can corrupt/race on
`_build/.lock` ("Unexpected contents of build directory global lock file"), non-deterministically
failing or hanging unrelated recipes. Fixed by making the `test` target depend on `build` (a
normal prerequisite, ensuring `dune build` always completes before `dune test` starts) and by
making sure nothing else in the build graph calls `dune exec`/`dune build`/`dune test` (see the
`TAKIBI` note above and `scripts/run_qemutest.sh`'s `run_compile_error_test`, which had its own
independent `dune exec takibi --` call fixed for the same reason). If a future change
reintroduces a second concurrent `dune` invocation anywhere in the `make -j` graph, expect this
same class of flake to come back.

## Directory Layout

```
lib/
  ast.ml          -- AST definitions (includes TypePtr, TypeArray, TypeFn, Deref, AddrOf, AssignDeref, Cast)
  const_env.ml    -- parser-time table of compile-time integer constants (immutable globals with a literal
                     initializer), used to resolve named array sizes like [T; QUEUE_SIZE]
  lexer.mll       -- ocamllex (includes hex literals, & token, as keyword, ^ token, -> token, void keyword)
  parser.mly      -- Menhir (includes pointer types, array types, function pointer types, prefix * / & / unary -, as cast)
  types.ml        -- internal type (ty) + HM type inference output types + StringMap
  type_inf.ml     -- Hindley-Milner type inference (immutable StringMap based)
  typechecker.ml  -- external wrapper (called from main.ml)
  llvm_gen.ml     -- LLVM IR generation and object file output
bin/
  main.ml         -- CLI (`takibi <file1.tkb> [file2.tkb ...] [-o out.o] [--target <triple>] [--cpu <cpu>] [--features <features>] [-g] [--forbid-trap] [--version]`)
                     Multiple .tkb files are concatenated (flat global namespace) before compilation.
                     -g emits DWARF debug info -- see "Execution Profiling (QEMU)" below.
                     --version prints the version from dune-project's `(version ...)` field via
                     the `dune-build-info` library (`Build_info.V1.version ()`) and exits 0 --
                     bump `dune-project`'s package version to change what this prints, nothing in
                     `bin/main.ml` itself needs editing. Confirmed this populates even under plain
                     `dune build` (no `dune install` needed), despite `dune-build-info`'s own .mli
                     comment saying the value is `None` until "artifact substitution" happens --
                     that turned out to already occur on every build in dune 3.22, at least for
                     this project's setup. Falls back to a literal "unknown (not installed via
                     dune)" string if a future dune/setup combination brings back the documented
                     None case.
examples/
  common/
    startup.S     -- _start -> main, BSS zero-clear, AArch64 semihosting exit (shared by all examples)
    link.ld       -- linker script (load address 0x40000000) (shared by all examples)
    timer_asm.S   -- ARM Generic Timer stubs: read_cntfrq, set_cntp_tval, enable_cntp, disable_cntp, task_exit_stub
    sem_asm.S     -- atomic semaphore: sem_wait (ldaxr/stxr), sem_post (ldxr/stlxr)
    uart.tkb      -- uart_putc, uart_puts, uart_isr_getc (RX-interrupt byte read, no polling)
    print.tkb     -- uart_print_uint, uart_print_hex, uart_print_int
    gic.tkb       -- GicRegs struct, gic_init, gic_enable_timer_ppi, gic_enable_uart_spi,
                     irq_uart_rx_setup/_unmask (uniform names shared with
                     common_stm32/nvic.tkb, see the STM32 section below)
    timer.tkb     -- extern fn timer stubs, setup_task_stack, timer_init (depends on gic.tkb),
                     scheduler_init/_disable/_rearm_tick (uniform names shared with
                     common_stm32/scheduler.tkb, see the STM32 section below)
    sync.tkb      -- extern fn sem_wait/sem_post, mutex_lock/unlock, cond_wait/signal
    virtio_mmio.tkb -- net_init/net_poll_rx/net_rx_buf/net_transmit/net_rx_release/net_read_mac
                     (uniform API shared with common_stm32/eth.tkb, see "STM32 Ethernet" above)
    netconfig.tkb -- OUR_IP (QEMU-side static IP for arp_reply/icmp_echo/tcp_echo),
                     HTTP_SERVER_IP (http_server's own IP, see "Network config" below)
    stm32_stub.tkb -- no-op stand-ins for STM32-only symbols a shared example's dead
                     QEMU-side code still references (see the STM32 section below)
  common_stm32/   -- STM32F746G-DISCOVERY (Cortex-M7) HAL, mirroring common/'s function
                     names/signatures so every example .tkb file is a single file shared
                     by both targets -- see "STM32F746G-DISCOVERY Bare-Metal (Cortex-M7)" below
    startup.S     -- Reset_Handler, 54-word vector table, PendSV_Handler, weak
                     SysTick_Handler/USART1_IRQHandler/pendsv_dispatch stubs
    link.ld       -- MEMORY {FLASH RAM} linker script (RAM = DTCM, 64K)
    link_eth.ld   -- same, RAM = AXI SRAM (Ethernet DMA can't reach DTCM)
    uart.tkb      -- uart_init, uart_putc, uart_puts (USART1, PA9/PB7, AF7), uart_isr_getc
    uart_getc.tkb -- uart_getc (USART1 RX poll; only echo needs RX)
    rtc.tkb       -- rtc_init, rtc_is_running, rtc_read_seconds (real RTC peripheral, LSI)
    nvic.tkb      -- enable_usart1_irq, irq_uart_rx_setup/_unmask
    scheduler.tkb -- setup_task_stack, task_exit_stub, systick_init/_disable, pendsv_trigger,
                     scheduler_init/_disable/_rearm_tick (see the STM32 section below)
    sem_asm.S     -- atomic semaphore: sem_wait/sem_post (ldrex/strex/dmb)
    eth.tkb       -- net_init/net_poll_rx/net_rx_buf/net_transmit/net_rx_release/net_read_mac
                     (real Ethernet MAC/PHY/DMA driver, see "STM32 Ethernet" above)
    netconfig.tkb -- OUR_MAC/OUR_IP (STM32 board's fixed network identity),
                     HTTP_SERVER_IP (same value as OUR_IP here, see "Network config" below)
  <name>/         -- each directory: see the leading comment in <name>.tkb for a description.
                     Every example is now a single file compiled for both targets -- no
                     `<name>_stm32.tkb` exists anywhere in this repo (see the STM32 section
                     below for how the hardest cases, irq/preempt/semaphore/condvar/watchdog/
                     msgqueue, got there too).
scripts/
  run_qemutest.sh -- QEMU integration test script (FIFO sync and timing verification included)
  run_hwtest.sh   -- STM32 hardware integration test script (flash + serial capture; see below)
test/
  test_takibi.ml  -- Alcotest unit tests for parser / type_inf
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
`~` (Bnot) is a unary prefix operator at the same precedence as other unary ops (`*` deref, `&` addrof, unary `-`).

Precedence (low -> high): `||` < `|` < `^` < comparison < `&` < `as` < `+/-` < `>>` `<<` < `*` `/` `%` < unary (`~` `-` `*` `&`)

**`>>` is sign-aware**: for signed types (i8/i16/i32/i64) `>>` generates `ashr` (arithmetic, sign-extending);
for unsigned types (u8/u16/u32/u64) it generates `lshr` (logical, zero-extending). This matches standard C behavior.

### Soundness Condition for % Range Propagation

Range propagation for `n % m` (where m is a positive integer literal) returns `{0..<m}` **only when the left operand is guaranteed non-negative at the type level**.

- `n: {lo..<_}` with `lo >= 0` -> `TRefinedInt(0, m)` / `TypeRefined(0, m)` (safe)
- `n: i32` (possibly negative) -> `TI32` / `TypeI32` (conservative fallback)

**Rationale**: LLVM's `srem` returns a negative remainder when the dividend is negative (`(-5) % 8 = -5`, not 3).
Unconditionally returning `{0..<m}` for `n: i32` would cause `arr[(-5) % 8]` to be judged "safe",
producing an unsound buffer under-read with the bounds check omitted.

**Sync rule**: Both `lib/type_inf.ml` (`Mod` case) and `lib/llvm_gen.ml` (`Mod` case) have a `lo >= 0` guard.
Relaxing only one side causes them to disagree; always change them together.

### break / continue Implementation (4 Files)

Files changed when `break` and `continue` were added:
1. `lib/ast.ml` -- `Break` and `Continue` constructors in `stmt_desc`
2. `lib/lexer.mll` -- `"break"` and `"continue"` keywords
3. `lib/parser.mly` -- `BREAK SEMI` / `CONTINUE SEMI` statement rules
4. `lib/type_inf.ml` -- `in_loop: bool` parameter added to `infer_stmt`; `Break | Continue` raises `TypeError` when `in_loop = false`. `While`/`For` bodies pass `true`; `Block`/`If` propagate the current value.
5. `lib/llvm_gen.ml` -- `loop_stack : (break_bb * continue_bb) Stack.t` inside `gen_func`. Pushed on loop entry, popped on exit. `Break` emits `br break_bb`; `Continue` emits `br continue_bb`.

**`for` loop `continue` target is `incr_bb`, not `cond_bb`**:
The for loop has a dedicated `incr_bb` block that increments the counter and jumps to `cond_bb`.
`continue` jumps to `incr_bb` so the counter is always incremented before rechecking the condition.
`i_val` loaded in `cond_bb` dominates `incr_bb` (all paths to `incr_bb` go through `cond_bb`), so the SSA use is valid.

```
cond_bb: i_val = load ctr; if i_val < hi -> body_bb else exit_bb
body_bb: [body]  break -> exit_bb / continue -> incr_bb / fallthrough -> incr_bb
incr_bb: i_next = i_val + 1; store -> ctr; br cond_bb   <- continue target
exit_bb: ...                                              <- break target
```

### Unary Minus is Desugared in the Parser
`-expr` is converted to `BinOp(Sub, IntLit 0, expr)` (the `%prec UNARY` rule in `parser.mly`).
No changes to AST, type inference, or codegen are needed. `sub i32 0, %x` is also the canonical form of integer negation in LLVM IR.

### The as Cast Spans 5 Files
Files changed when `expr as T` was added:
1. `lib/ast.ml` -- `Cast of type_expr * expr` constructor
2. `lib/lexer.mll` -- `"as"` keyword
3. `lib/parser.mly` -- `%nonassoc AS` (lower precedence than arithmetic), `expr AS type_expr` rule
4. `lib/type_inf.ml` -- checks the source expression and returns the target type.
   **Pointer cast restriction**: `*T as X` where X is a fixed-width integer (`i8/i16/i32/i64/u8/u16/u32/u64`) is a compile error.
   Only `*T as usize` and `*T as *U` are allowed. Use `(ptr as usize) as i32` to make any truncation explicit.
5. `lib/llvm_gen.ml` -- `coerce` function selects the conversion instruction per target type:
   - `i32 -> u8`: `trunc i32, i8`
   - `u8/i1 -> i32`: `zext`
   - `i32 -> *T`: `inttoptr` directly (no manual zext step -- see the STM32 usize note below for why)
   - `*T -> usize`: `ptrtoint ptr, <usize_lltype>` (width follows the target's actual pointer size, not hardcoded)
   - `*T -> *U`: **no-op** (in LLVM 19, all pointers are the same `ptr` type, so the leading `if vty = dst_ll then v` in `coerce` applies; no compiler change needed)

**Invariant: narrow-typed (`i8/u8/i16/u16`) `gen_expr` results must be
i32/i64-widened in-flight, never returned as a bare narrow value.**
`widen_load` documents this: "arithmetic values arrive at `coerce` already
widened; `coerce` narrows only at the point of storage." `Var`/`Index`/
`FieldGet`/`Deref` all follow it. The `Cast` case's fallback branch once
didn't (`coerce v target_ty` with no re-widening), so `expr as u8` composed
with e.g. `arr[i]` (an i32-widened u8) via `==` produced two operands that
disagreed on LLVM type despite matching AST type -- `icmp eq i32 ..., i8 6`
crashed the LLVM verifier. Fixed via `to_arith_width target_ty (coerce v
target_ty)`. **Any future `gen_expr` case returning a narrow type must
widen before returning**, even though the AST type says narrow.

**`gen_func` verifies generated IR with `Llvm_analysis.verify_function` +
`raise (Error ...)`, not `Llvm_analysis.assert_valid_function`.** The
assert variant calls C's `abort()` on invalid IR (uncatchable OCaml-side),
which during the bug above killed `test_takibi.exe` with SIGABRT and
silently dropped every later test with no indication which one crashed;
`verify_function` produces a normal, attributable `[FAIL]` instead. Any
future `gen_func`-adjacent change should keep using this catchable path.
Regression coverage: `test/test_takibi.ml`'s `codegen_tests` group (via a
`gen_codegen`/`expect_codegen_ok` helper running parse -> infer ->
`Llvm_gen.gen_program` with no target machine).

### sizeof(T) Spans 4 Files
Files changed when `sizeof(T)` was added:
1. `lib/ast.ml` -- `SizeOf of type_expr` constructor in `expr_desc`
2. `lib/lexer.mll` -- `"sizeof"` keyword -> `SIZEOF` token
3. `lib/parser.mly` -- `SIZEOF LPAREN type_expr RPAREN` primary-expression rule (no special precedence needed; fully bracketed)
4. `lib/type_inf.ml` -- `SizeOf ty -> TUsize`, with a `senv`/`eenv` lookup that raises `TypeError "unknown type '%s' in sizeof"` for an undefined `TypeNamed` (catches typos at compile time rather than surfacing as an internal codegen error)
5. `lib/llvm_gen.ml` -- `ltype_of_ast ty` (resolves `TypeNamed` through the already-registered `struct_lltypes`, so packed/tail-padded sizes are correct) -> `Llvm_target.DataLayout.abi_size` against the `target_data` ref (same mechanism used for struct tail-padding) -> `const_int (ltype_of_ast TypeUsize) sz`

**Design note -- fixed `usize`, not a polymorphic literal**: unlike `IntLit` (which infers as `fresh ()` and unifies with any integer type via context), `SizeOf` always has type `usize`. This matches the project's established "explicit cast" philosophy for anything involving sizes/addresses (see the pointer-cast restriction above): `if (len >= sizeof(Hdr))` requires `len: usize`, not `len: i32`, since `unify TI32 TUsize` fails (no implicit coercion between fixed integer types in comparisons). Use `(len as usize) >= sizeof(Hdr)` when `len` is genuinely `i32`.

**Not supported**: `sizeof(T)` as an array size (`[T; sizeof(Foo)]`). Array-size constants are resolved entirely in the parser via `Const_env` (see "Global let / let mut and Array-Size Constants" above), before struct layout exists; `sizeof` needs `struct_lltypes`/`DataLayout`, which are only available at codegen time. Combining the two would require moving array-size resolution out of the parser into a later phase -- deferred until a concrete need arises.

### Codegen for Immutable and Mutable Variables
The locals table in `llvm_gen.ml` is managed as `(string, local_binding) Hashtbl.t`.

```ocaml
type local_binding =
  | Imm of Ast.type_expr * llvalue  (* immutable: no alloca; holds the SSA value directly *)
  | Mut of Ast.type_expr * llvalue  (* mutable: alloca pointer *)
```

- `let x = e` -> evaluates the expression to an llvalue and registers it as `Imm`. No `alloca/store/load` is generated.
- `let mut x = e` -> allocates an `alloca` in the entry block (`Mut`) and emits a `store` at the declaration site.
- Function arguments are always `Mut` (parameters can be reassigned).

**`gen_stmt` is defined inside `gen_func`**. This is because the type of an immutable `let` must be resolved via the `res` function that references the HM type inference result. As an OCaml closure, `res` in the `gen_func` scope can be referenced naturally.

### Global Arrays and Uninitialized Global Variables
Uninitialized global variable declarations such as `let heap: [u8; 256];` are supported.

- Emitted as `undef` in LLVM IR (not `zeroinitializer`)
- Since `startup.S` zero-clears the BSS section, values are always zero at runtime
- Array type `[T; N]` can only be declared in global scope. Decays to `*T` in function arguments.

Uninitialized case in `gen_global`:
```ocaml
| None -> undef llty  (* BSS is zero-cleared by startup.S, so this is safe *)
```

### Global Variable Alignment -- align(N) (5 Files)

Files changed when `let x: T align(N)` was added:
1. `lib/ast.ml` -- `LetDef` 4th field: `int option` (`None` = no alignment, `Some N` = N-byte alignment)
2. `lib/lexer.mll` -- `"align"` keyword -> `ALIGN` token
3. `lib/parser.mly` -- `ALIGN` token; two new `item` rules for `align(N)` with and without initializer
4. `lib/type_inf.ml` -- all `LetDef` patterns updated to 4-tuple; alignment field is ignored during type checking
5. `lib/llvm_gen.ml` -- `gen_global` gains `align_opt` parameter; calls `set_alignment n gvar` when `Some n`

**Design note**: alignment is a property of a specific variable instance, not of the type.
`VirtqDesc` structs don't inherently need 4096B alignment -- only the descriptor ring array does.
Type-level alignment (`struct Name align(N) { ... }`) is a separate feature -- see
"Packed Struct and Struct Type-Level Alignment" below.

**Syntax**:
```
let mut buf: [u8; 4096] align(4096);      // no initializer (must be `mut`: no init requires mutability)
let reg: i32 align(64) = 0;               // immutable, with initializer
let mut counter: i32 align(64) = 0;       // mutable, with initializer
```
N must be a power of two (not enforced by the compiler; LLVM will assert at IR generation time).

### Global let / let mut and Array-Size Constants (7 Files)

Global scope now distinguishes immutable constants from mutable variables, mirroring local
variable semantics (`let` = immutable, `let mut` = variable), and a named immutable constant
with a literal initializer can be used as an array size.

Files changed:
1. `lib/ast.ml` -- `LetDef` gains a 5th field `bool` (`is_mutable`); `TypeArray`'s `int` size is
   unchanged (array-size constants are resolved entirely inside the parser, see below).
2. `lib/const_env.ml` (new) -- `(string, int) Hashtbl.t` mapping constant name -> value, populated
   incrementally as the parser consumes top-level items left to right. `reset ()` clears it (called
   once per compiler invocation in `main.ml`, and once per `parse` call in `test_takibi.ml` for test
   isolation). `define_if_literal is_mutable name init_opt` records `name` only when `is_mutable =
   false` and `init_opt` is a bare `IntLit` (no forward references, no constant folding).
3. `lib/parser.mly` -- `%inline mut_flag` nonterminal (`MUT` -> `true`, empty -> `false`) threaded
   through all `item`-level `LetDef` productions. The plain (non-`align`) production calls
   `Const_env.define_if_literal`. New `array_size` nonterminal used in the `[T; N]` grammar
   production: `INT` is used directly; `IDENT` is looked up via `Const_env.find`, raising
   `Types.TypeError` if not found (e.g. undeclared, declared later in the file, or declared with
   `mut`/a non-literal initializer).
4. `lib/type_inf.ml` -- `LetDef` patterns updated to 5-tuple. `genv` now stores the real
   `is_mutable` flag instead of a hardcoded `true`. Because `Assign`/`AddrOf` already key their
   mutability checks off the shared `tyenv` (used for both locals and globals), `&const_global` and
   `const_global = ...` become compile errors automatically, with no new enforcement code. Pass 2
   additionally rejects an immutable global with no initializer.
5. `lib/llvm_gen.ml` -- `LetDef` patterns updated to 5-tuple; `gen_global` takes an `is_mutable`
   parameter and calls `set_global_constant true` on the LLVM global when `false`.
6. `bin/main.ml` -- calls `Const_env.reset ()` once before parsing the (possibly multi-file,
   concatenated) input.
7. `test/test_takibi.ml` -- `parse` helper calls `Const_env.reset ()` first (test isolation); all
   `LetDef` patterns updated to 5-tuple.

**Why resolve array-size constants in the parser, not via a `Types.ty`-level pass**: `Ast.TypeArray`
is pattern-matched directly (not via `Types.ty`) in roughly 15 places across `llvm_gen.ml` (locals,
globals, struct fields, `StructLit` codegen, tail-padding, etc.). Resolving the constant reference to
a plain `int` at parse time means `TypeArray` itself never changes shape, so none of those call sites
needed touching. The trade-off is that the constant must be declared textually before its use (no
forward references) -- acceptable since the feature is scoped to simple "declare a size, use it
below" readability, not a general compile-time-constant system.

**Example**:
```takibi
let QUEUE_SIZE: i32 = 4;              // immutable constant; &QUEUE_SIZE and QUEUE_SIZE = ... are compile errors
let mut ring: [i32; QUEUE_SIZE];      // resolved to [i32; 4] at parse time
```
See `examples/const_global/` (valid usage) and `examples/const_global_wrong/` (compile-error demo).

### Function Pointer Types Span 5 Files
Files changed when the `fn(T...) -> R` type was added:
1. `lib/ast.ml` -- `TypeFn of type_expr list * type_expr` constructor
2. `lib/lexer.mll` -- `"->"` token, `"void"` keyword
3. `lib/parser.mly` -- `fn_type` non-terminal (`FN LPAREN type_list RPAREN ARROW type_expr`)
4. `lib/type_inf.ml` -- `Var` retrieves a function name as `TFun` from `fenv`; `Call` supports both direct and indirect calls
5. `lib/llvm_gen.ml` -- `ltype_of_ast (TypeFn _) = pointer_type context` (opaque ptr); indirect calls reconstruct `function_type` and use `build_call`

**Function pointers in LLVM 19**:
LLVM 19 has a single pointer kind (`ptr`, opaque pointer). `fn(i32) -> u8` and `fn() -> void` are both the same `ptr` in LLVM IR. The takibi type checker enforces type distinction; correct calling conventions are generated by passing `function_type` to `build_call`. Unlike C's `void*`, takibi's type checker enforces signature compatibility.

### extern fn Spans 5 Files
Files changed when external assembly function declarations like `extern fn timer_init();` were added:
1. `lib/ast.ml` -- `ExternFuncDef of ident * (ident * type_expr option) list * type_expr option`
2. `lib/lexer.mll` -- `"extern"` keyword
3. `lib/parser.mly` -- `EXTERN FN IDENT LPAREN params RPAREN (ARROW type_expr)? SEMI` rule
4. `lib/type_inf.ml` -- adds `TFun` in Pass 1 for `fenv`; `ExternFuncDef _ -> m` in the `genv` fold
5. `lib/llvm_gen.ml` -- emits `declare_function` in Pass 1 (Pass 2 does `ExternFuncDef _ -> ()`)

### Struct Implementation (7 Files)

Files changed when `struct Name { field: type; }` was added:
1. `lib/ast.ml` -- `TypeNamed of string` (type), `FieldGet of expr * string` (expr), `AssignField of expr * string * expr` (stmt), `StructDef of string * (string * type_expr) list * bool` (last bool = is_packed)
2. `lib/types.ml` -- `TStruct of string` (internal type), added `program_types.structs` field
3. `lib/lexer.mll` -- `"struct"` -> `STRUCT`, `'.'` -> `DOT` token
4. `lib/parser.mly` -- `%left DOT` (highest precedence), `struct_fields` rule, `IDENT DOT IDENT ASSIGN expr SEMI` assignment statement, `expr DOT IDENT` field read expression, `IDENT` -> `TypeNamed` type expression
5. `lib/type_inf.ml` -- `senv : (string * Ast.type_expr) list StringMap.t` collected in Pass 0 and threaded through all inference functions
6. `lib/llvm_gen.ml` -- registers `struct_type context fields` in Pass 0; `TypeNamed` returns the alloca/global pointer as-is (same approach as arrays); `FieldGet` uses `build_in_bounds_gep` + load; `AssignField` uses GEP + store
7. `test/test_takibi.ml` + `examples/struct/` -- parser/type-inference tests + QEMU demo

**Struct variable codegen design** (unified approach with arrays):
- `let mut s: Name;` local -> `alloca [struct_type]` -> `Mut (TypeNamed "Name", alloca_ptr)`
- `Var "s"` where `TypeNamed _` -> return the alloca pointer as-is (no load)
- Global struct variables are handled the same way (value of `define_global` = return the pointer as-is)
- `s.field` / `p.field` where `p: *Name` -> GEP `[0, field_idx]` -> load (auto-distinguished by type check)
- `s.field = v` -> GEP -> store (non-volatile; not MMIO)
- `&s` -> return the alloca pointer as `*Name` (for pass-by-pointer)

**Current limitations**:
- Field assignment only in `ident.field = v` form (LHS is a single variable name only)
- Global struct variable as `let g: Name;` only (`let mut` is not supported in global scope; always mutable)

### Packed Struct and Struct Type-Level Alignment (5 Files)

Files changed when `struct packed Name { ... }` and `struct Name align(N) { ... }` were added:
1. `lib/ast.ml` -- `StructDef of string * (string * type_expr) list * bool * int option` (is_packed, align_bytes)
2. `lib/lexer.mll` -- `"packed"` keyword -> `PACKED` token (`ALIGN` was already present)
3. `lib/parser.mly` -- 4 rules: plain / packed / align(N) / packed+align(N)
4. `lib/type_inf.ml` -- `StructDef (name, fields, _, _)` in Pass 0 (both flags irrelevant for type checking)
5. `lib/llvm_gen.ml` -- `packed_struct_type` when is_packed; `struct_alignments` table stores align_bytes per struct name; `set_alignment` applied at alloca (locals) and `define_global` (globals) time; also propagates to `[Name; N]` array allocas/globals

**Use case for packed**: protocol headers (Ethernet, IP, USB descriptors) and MMIO register maps where field layout must match hardware exactly without alignment padding.

**Use case for align(N)**: SIMD types (`Vec4 align(16)`), DMA descriptor rings (`Ring align(4096)`), cache-line-separated data. Alignment is set automatically on every variable of that type without repeating `align(N)` at each declaration site.

**Struct tail padding** (`lib/llvm_gen.ml` Pass 0): When `align(N)` is specified and `sizeof(struct) % N != 0`, an `[i8; pad]` field is appended to the LLVM struct type so that `sizeof(struct)` becomes the next multiple of N. This ensures every element of `[Name; K]` arrays satisfies the alignment requirement (same behavior as C `__attribute__((aligned(N)))`). `struct_fields` stores only user-visible fields; the padding field is invisible to GEP and type inference. Tail padding uses the LLVM DataLayout (`Llvm_target.DataLayout.abi_size`) stored in `target_data` ref set by `setup_target`.

**IntLit width sync in BinOp** (`lib/llvm_gen.ml`): `IntLit` always emits `i32` in codegen. When one BinOp operand is `i64` (usize on a 64-bit target) and the other is `i32` (from IntLit), the i32 is widened before the operation. This prevents an LLVM IR type-mismatch error on patterns like `usize_val == 0` or `usize_val & 15`. On a 32-bit target (Cortex-M), usize is itself `i32`, so this widening branch's `i64`-vs-`i32` mismatch condition simply never fires -- no separate code path needed for the two widths.

### Enum Implementation (5 Files)

Files changed when `enum Name: u16 { V = n; _; }` was added:
1. `lib/ast.ml` -- `EnumVariant of string * string` (expr), `Match / match_arm` (stmt, mutual recursion with `and`), `EnumDef of string * type_expr option * (string * int option) list * bool` (last bool = is_nonexhaustive)
2. `lib/lexer.mll` -- `"enum"` `"match"` keywords, `"::"` `"=>"` `"_"` tokens
3. `lib/parser.mly` -- `enum_variants` returns `(string * int option) list * bool`; `UNDERSCORE SEMI` sets `true`; `IDENT COLONCOLON IDENT` expr; `match expr { arms }` stmt
4. `lib/type_inf.ml` -- `eenv : (Ast.type_expr * (string * int) list * bool) StringMap.t` (bool = is_nonexhaustive) collected in Pass 0. `Match` exhaustiveness: exhaustive enum requires all variants or `_`; non-exhaustive enum requires `_` (listing all known variants is not enough).
5. `lib/llvm_gen.ml` -- `enum_underlying`, `enum_variants_tbl`, `enum_nonexhaustive` tables. `EnumVariant` -> integer constant. `Match` -> LLVM `switch`. `int as ExhaustiveEnum` -> switch+trap. `int as NonExhaustiveEnum` -> no-op (any integer is valid).

**Two kinds of enum**:
- Exhaustive (`_` absent): the type guarantees the value is one of the named variants. `int as Enum` traps on unknown values. `match` requires all variants or `_`.
- Non-exhaustive (`_` present): models open sets (IANA-registered protocol fields, etc.). `int as Enum` never traps. `match` requires a `_` wildcard arm (compiler enforces this).

**Round-trip guarantee** (intentional design, must not be broken):
`(raw as NonExhaustiveEnum) as u16 == raw` for any `raw: u16`, including values that fall through to the `_` arm. This holds because `enum -> int` cast is a no-op at the LLVM IR level: no `unreachable` is inserted, so LLVM cannot assume the value is one of the named variants. This differs from C enum (UB for out-of-range values) and is essential for protocol implementations where unknown field values must be forwarded or logged intact.

**eenv lookup pattern** (3-tuple destructuring):
```ocaml
let (_, variants, is_ne) = StringMap.find ename eenv in
```
`EnumVariant` inference and `Match` exhaustiveness check both use this pattern.

### --forbid-trap: Gradual Verification (permissive dev mode / proven ship mode)

`takibi ... --forbid-trap` rejects compilation if ANY runtime trap check
remains in the generated code, listing every unproven site with its source
location (all of them, not just the first -- same report-all philosophy as
run_qemutest.sh). Without the flag, behavior is unchanged: unproven accesses
compile fine and get a runtime check (llvm.trap on violation) -- that IS the
intended permissive development mode for quick driver bring-up. The flag is
ship mode: only type-proven accesses may exist. **Current status: 43 of 44
examples compile clean under --forbid-trap**; the one holdout is
examples/enum/enum.tkb's deliberate `u8 as Color` checked-cast demo, where
the runtime check is the point.

**Mechanism** (`lib/llvm_gen.ml` `trap_sites` / `record_trap`): every trap
check codegen emits (array bounds check, checked refined cast, exhaustive-
enum cast) is recorded with loc + human-readable reason at IR-generation
time. bin/main.ml reads the list after gen_program and errors under the
flag. **The judgment is deliberately type-level, not post-optimizer**: LLVM
passes (correlated-propagation etc.) may well fold a given check away, but
"the optimizer happened to remove it" must never count as proof -- the
guarantee has to stay deterministic across LLVM versions. Consequence:
`while (i < 8) { arr[i] }` is rejected even though LLVM elides its check;
the answer is `for i in 0..<8`, which is proven at the type level.

**What --forbid-trap does NOT guarantee**: pointer indexing (`p[i]` where
`p: *T`) has no bounds checks at all and is therefore invisible to this
mechanism -- raw pointers are takibi's unsafe escape hatch (all the network
code indexes packet buffers through pointers). A future slice type
(pointer + type-level length) is the long-term answer; until then
--forbid-trap means "no runtime trap instructions", not "memory-safe".

**Checked refined cast** (`expr as {lo..<hi}`): previously this cast was
silently UNCHECKED -- type_inf returned the target type for any non-pointer
source, and codegen emitted no check, so `arr[v as {0..<8}]` with `v: i32`
elided the bounds check and produced an unchecked OOB access (a genuine
soundness hole, found while building this feature). Now it mirrors
`int as ExhaustiveEnum`: if the source's static range proves the target
range (`{2..<5} as {0..<8}`, literals, bool/u8/u16 fitting entirely), it is
a free subtype coercion; otherwise a range check + llvm.trap is emitted (and
recorded, so --forbid-trap rejects it). This cast is the explicit bridge
from unproven integers into refined types -- the gradual-verification story
in one construct: permissive mode traps at runtime, ship mode demands the
source range be provable.

**Narrowing invalidation (kill) rule** (`Ast.written_names`, shared by
`type_inf.ml:narrow_from_cond` and `llvm_gen.ml:apply_narrowing/_mut` --
sync rule: both sides MUST use this same function, like the Mod lo >= 0
guard): if-condition narrowing (`if (v >= 0 && v < 8) { ... }`) must not
apply to a variable the branch body can (a) assign, (b) alias via `&v`, or
(c) rebind (let redeclaration or for-counter). All three were soundness
holes before this rule existed: `if (v >= 0 && v < 8) { v = 100; buf[v] }`
compiled with the check fully elided (silent OOB, no trap at all), same for
a write through `&v`, same for `for v in 0..<100` shadowing the narrowed
name. The pre-scan is deliberately flow-insensitive within the branch (a
write anywhere kills narrowing for the whole body, even before the write)
-- simple to reason about, and refining it to a statement-ordered kill is
future work that must keep both consumers in lockstep. `io` variables were
already excluded (apply_narrowing_mut only matches `Mut (TypeI32, _)`);
globals were already excluded (narrowing tables only hold function locals);
function calls cannot touch locals whose address was never taken, and
address-taking is exactly case (b).

**For-loop bounds from named constants** (`Const_env.bound_value`, shared
by both sides -- same sync rule): `for i in 0..<QUEUE_SIZE` now refines `i`
to `{0..<QUEUE_SIZE's value}` when the bound names a Const_env constant
(immutable global with literal initializer), not just when it is a literal.
This is what made examples/const_global --forbid-trap clean. Soundness
precondition: the name must actually denote the global constant, so
**shadowing a Const_env constant name with a local let / parameter /
for-counter is now a compile error** (`type_inf.ml:check_const_shadowing`,
run per function AFTER parsing so declaration order cannot smuggle a shadow
in). Const_env resolves by name with zero scope information; allowing a
local `QUEUE_SIZE` would refine against the global's value while the loop
runs to the local's. Rejecting the shadow keeps by-name resolution sound by
construction (and it also retroactively hardens the existing array-size
feature, which had the same latent ambiguity).

**Exhaustive-enum cast from a refined source** (`llvm_gen.ml` Cast case):
`i as Color` where `i: {0..<3}` and Color = {0,1,2} now emits no switch/no
trap -- the range proves every possible value is a variant. A range with
any non-variant value (e.g. `{0..<3}` into a {1,2}-valued enum) keeps the
runtime check. This removed examples/enum's for-loop cast site.

**Files**: `lib/llvm_gen.ml` (trap_sites/record_trap/ty_str, emit_trap_when
/ emit_bounds_check loc+type params / emit_refined_cast_check, Cast
TypeRefined + enum-proof branches, For bound_value, narrowing kill),
`lib/type_inf.ml` (narrow_from_cond kill, For bound_value,
check_const_shadowing), `lib/ast.ml` (written_names), `lib/const_env.ml`
(bound_value), `bin/main.ml` (flag + report), `test/test_takibi.ml`
(expect_trap_sites helper + 12 cases), `examples/forbid_trap_wrong/` +
`examples/forbid_trap_ok/` (compile-only tests registered in
run_qemutest.sh; run_compile_error_test now accepts trailing extra takibi
flags, and run_forbid_trap_ok_test is the success-side counterpart).

**Deliberately deferred** (recorded so the next step starts from data, not
guesswork): flow-sensitive assignment kill (narrow until the first write
instead of killing the whole branch), while-condition narrowing
(`while (i < 8)`), symbolic/relational bounds (`{0..<n}` where n is a
runtime value, `i < len` facts) -- the last one is the honest decision
point for a VC+SMT (Z3) backend; everything above stays in the
non-relational interval world where plain OCaml implementation is the
right tool. The empirical result that 43/44 examples needed ZERO relational
reasoning is the argument for not introducing a solver yet.

### Synchronization Primitive Design and Current Limitations

Synchronization primitives have a 3-layer structure:

```
assembly (ldaxr / stlxr)
  +---- sem_wait / sem_post          <- atomic guarantee only here (extern fn)

takibi
  +---- mutex_lock / mutex_unlock    <- named wrappers around sem_wait/sem_post
  +---- cond_wait / cond_signal      <- sequence counter method (written in takibi)
```

See the comment in each `.tkb` file for implementation details (`condvar.tkb` explains missed-wakeup prevention in `cond_wait`).

**Current limitation: single-core only**
- `cond_signal`'s `*seq = *seq + 1` is not atomic. The convention of calling it while holding the mutex makes it correct on a single core, but it is insufficient for multi-core.
- `cond_wait`'s spin `while (*seq == s) {}` is a plain volatile load without a hardware memory barrier. Multi-core requires replacing it with `ldar` (load-acquire).

### Distinguishing MMIO from Regular Pointers (`io T`, `*io T` vs `*T`)

**Type relationships**:
- `io T` -- volatile-qualified value type (AST: `TypeIo T`). LLVM type is the same as T. A storage qualifier.
- `*io T` -- volatile MMIO pointer (AST: `TypePtr (TypeIo T)`). LLVM type is opaque ptr.
- `*T` -- regular pointer (AST: `TypePtr T`). Non-volatile.

**Where volatile is generated**:
- `let irq_done: io i32;` -- all reads and writes to this global variable are volatile
- `irq_done = 1;` -> volatile store (automatic)
- `while (irq_done == 0) {}` -> `irq_done` is a direct volatile load (automatic)
- `&irq_done` -> automatically returns `*io i32` (no `as *io i32` cast needed)
- Struct field `done: io i32;` -> `s.done = 1;` is a volatile store
- `*p` where `p: *io i32` -> volatile load
- `*p = v` where `p: *io i32` -> volatile store
- `p.field` where `p: *io Struct` -> volatile load (`through_io` flag)

**`io` is stripped on Deref**: `*p` where `p: *io i32` -> result type is `i32` (not `io`). Volatile is confined to `set_volatile true` on the load.

- `*io T` is a compiler-level distinction. CPU-level memory barriers are provided by `ldaxr/stlxr` (extern fn).
- Pointer arithmetic `*io T + i32` -> remains `*io T` (matches `TypePtr _`)
- `i32 as *io T` -- MMIO address literal assignment (inttoptr coercion, `TypePtr _` case)

### Volatile Reads of Global Variables (Interrupt-Shared Flags)
LLVM may hoist a global variable load out of a tight loop like `while (flag == 0) {}`,
resulting in an infinite loop (`cbz reg, self`).
Use `io i32` for flags shared with interrupt handlers:

Declare flags shared with interrupt handlers as `io i32`:
```takibi
let sched_done: io i32 = 0;        // volatile global declaration
sched_done = 1;                    // volatile store (automatic)
let p: *io i32 = &sched_done;      // &io_var automatically returns *io i32 (no cast needed)
while (*p == 0) {}                 // volatile load -- prevents hoisting
```
`AddrOf (Var name)` where `name: io T` -> automatically returns `TypePtr (TypeIo T)` = `*io T`. No cast needed.

### Integer Literal -> Pointer Coercion
`let dr: *io u8 = 0x09000000;` assigns an integer literal to an MMIO pointer type variable.
The `coerce` function in `llvm_gen.ml` emits `inttoptr(zext(i32, i64), ptr)` (`TypePtr _` case).

### Makefile Example Registration Convention
Adding a name to the `EXAMPLES` list is all that's needed to register a new example.
Convention: `examples/<name>/<name>.tkb` -> `examples/<name>/kernel.elf`

```makefile
EXAMPLES := start hello echo print_int print_hex print_ptr mem array fizzbuzz fibonacci bubblesort ringbuf callstack crc8 djb2 bump timer rtc irq scheduler preempt semaphore condvar struct msgqueue watchdog refined narrow for loop  # <- just add the name here
```

Only targets that require interactive manual startup (like `qemu-echo`) are added individually.
Automatable programs are registered in `qemutest` by providing `.expected` / `.stdin` files.
Use `run_test_timed` for tests that need timing verification (to confirm a delay actually waited).

**Compilation groups** (which common `.tkb` files are prepended to each example)
-- see the Makefile's own "Common file sets passed to takibi" comment
(just above `IRQ_OBJS`) for the authoritative, currently-maintained list;
summarized here:
- Standard (uart.tkb + print.tkb): most examples
- IRQ group (+ gic.tkb): `irq`
- Timer group (+ gic.tkb + timer.tkb): `preempt`, `semaphore`, `watchdog`
- Sync group (+ gic.tkb + timer.tkb + sync.tkb): `condvar`, `msgqueue`
- Net group (+ gic.tkb + virtio_mmio.tkb + netutil.tkb): `net_echo`, `arp_reply`
- Checksum group (+ inet_checksum.tkb + netutil.tkb): `inet_checksum`, `ip_parse`, `tcp_parse`
- App group (+ gic.tkb + virtio_mmio.tkb + inet_checksum.tkb + netutil.tkb): `icmp_echo`, `tcp_echo`, `http_server`

Note: `semaphore.tkb` declares its own `extern fn sem_wait/sem_post` (no `sync.tkb` needed), but still needs `sem_asm.o` at link time.

**Link groups** (which common assembly objects are linked in):
```makefile
TIMER_KERNELS := examples/preempt/kernel.elf examples/watchdog/kernel.elf
                 # linked with: startup.o + timer_asm.o
SEM_KERNELS   := examples/semaphore/kernel.elf examples/condvar/kernel.elf examples/msgqueue/kernel.elf
                 # linked with: startup.o + timer_asm.o + sem_asm.o
GENERIC_KERNELS := (all others)
                 # linked with: startup.o only
```

When adding a new example that needs timer or semaphore support, add it to the appropriate `*_OBJS` and `*_KERNELS` variable in the Makefile. No new `*_asm.S` files should be created; place any new assembly in `examples/common/` and add a build rule there.

**This `EXAMPLES` registration flow is separate from the `-g` debug-build
rules** (`examples/<name>/<name>.debug.o` / `kernel.debug.elf`, e.g. for
`fizzbuzz`, `fibonacci`, `http_server`, `tcp_echo`) -- those are one-off,
manually-written rules outside `EXAMPLES`, not a third compilation group.
See "Execution Profiling (QEMU)" below for why they're kept separate from
the normal (always `-g`-free) build outputs.

## Known Limitations / Deferred Design Decisions

- **`uart_print_uint` / `print_uint` take `i32`, not `u32`** (`examples/common/print.tkb`): the name promises unsigned
  semantics but the parameter type does not enforce non-negativity, and `%`/`/` on `i32` use signed `srem`/`sdiv`. A
  genuinely negative argument prints garbage (e.g. `-5 % 10 = -5` in LLVM, not the mathematical `5`). No current
  caller passes a negative value, so this has not manifested as a bug. Fixing the type to `u32` is a mechanical but
  wide-reaching change (every call site needs an explicit `i32 -> u32` cast, similar in scope to the global
  `let`/`let mut` migration). **Deferred**: the better fix is likely function overloading (same name, dispatch on
  parameter type -- `print(n: u32)` and `print(n: i32)` coexisting), so a `u32`-only rename now would likely be
  reshaped again once that lands. Revisit when a concrete number-to-string design is undertaken; a `printf`-style
  variadic/format-string approach was explicitly ruled out (runtime format parsing, no `void*`/generics, and a
  security-sensitive parser this project doesn't want in a bare-metal image).
- **No function overloading**: only one definition per function name is allowed (`fenv` is keyed by bare name). A
  `u32`/`i32`/`u8` family of `print`-like functions would need this. Estimated to be a moderate addition: `fenv`
  becomes name -> list of signatures, `Call` picks the best match by argument types, and `llvm_gen.ml` needs to
  mangle LLVM symbol names per overload (today one takibi name maps to exactly one LLVM function symbol).
- **`isize` (signed pointer-sized integer) is not implemented** -- tracked as a GitHub issue, not urgent. Needed for
  `ptr - ptr` (pointer difference), which is itself unimplemented. Neither is required for the planned Ethernet L2
  echo server (`ptr + i32` / `ptr - i32` already work for descriptor-ring indexing).
- **`sizeof(T)` cannot be used as an array size** (`[T; sizeof(Foo)]`) -- see the `sizeof(T)` section above for why
  (parser-time vs. codegen-time resolution mismatch) and what combining them would require.
- **Global `let` initializers can't constant-fold `as` casts or reference another global constant** -- only a bare
  `IntLit`/`StructLit` is accepted (`lib/llvm_gen.ml`'s `eval_const`). Hit twice during the STM32 Ethernet/unification
  work: `let ETH_RDES0_OWN: i32 = 0x80000000 as i32;` failed with "unsupported constant expression" (had to drop the
  cast and use a bare literal instead), and `examples/common_stm32/netconfig.tkb`'s `HTTP_SERVER_IP` had to duplicate
  `OUR_IP`'s array literal verbatim rather than reference it, so the two constants can silently drift apart if only
  one is ever edited. **Deferred**: would need extending the array-size-constant folding already done by
  `Const_env` (see "Global let / let mut and Array-Size Constants" above) to general initializer expressions --
  currently that mechanism only resolves bare-`IntLit`-valued names for `[T; N]` sizes, not arbitrary constant
  expressions used as an initializer value.
- **No module/import system for `.tkb` files** -- which common files get concatenated into a given example's build
  is decided entirely by hand-maintained Makefile variable lists (`COMMON_UART`, `COMMON_GIC`, etc.), with nothing
  in the source itself declaring "this file needs that file." Bit us directly while removing `irq.tkb`'s `IS_QEMU`
  branch: a new helper function was first placed in `uart.tkb` (concatenated into literally every example) even
  though its body called `gic_init()`/`enable_usart1_irq()`, symbols that only exist in a handful of builds --
  this silently broke unrelated examples like `start` with an "Undefined function" error, not caught until
  `make stm32build` was re-run over the whole example set. Ended up moving the functions into `gic.tkb`/`nvic.tkb`
  instead (already only included where those symbols exist). **Deferred**: a lightweight `use <file>;`-style
  declaration (even just "this file requires these to be present," checked at parse/link time) would catch this
  class of mistake at the point of writing the code rather than requiring a full rebuild sweep to notice.
- **No built-in memory-barrier intrinsic** -- the STM32 Ethernet DMA bring-up needed a `dsb` instruction between a
  descriptor-ring write and the "poll demand" register kick, because `*io` volatile writes alone don't guarantee the
  CPU's write buffer has retired before a subsequent register write reaches the DMA engine (see the "Hardware
  bring-up bug worth knowing about" paragraph under the STM32 Ethernet section below -- found only via live
  openocd/gdb-multiarch debugging on real hardware, not something the compiler flagged). Worked around with a
  hand-written `extern fn eth_dsb()` (`examples/common_stm32/eth_asm.S`), one target's instruction only.
  **Deferred**: a builtin `fence()`/`barrier()` (lowering to `dsb` on AArch64, `dmb` on Cortex-M, the same way
  `sizeof`/`as` already lower per-target) would remove a whole class of "did you remember the barrier before this
  DMA kick" bugs that today are invisible to the type checker and only surface as real hardware misbehavior.
- **STM32 Ethernet: all five examples are ported -- `net_echo`, `arp_reply`, `icmp_echo`, `tcp_echo`,
  and `http_server` all run on real hardware with real MAC/PHY/DMA, and are the *same source file* as
  their QEMU/virtio-net counterparts.** `examples/common_stm32/eth.tkb` is a from-scratch MAC/DMA-
  descriptor-ring driver + MDIO-based LAN8742A PHY init over RMII (RMII pins, PHY bring-up, and the DMA
  descriptor ring design are documented in that file's header comment).

  **Unified driver API**: `eth.tkb` and `examples/common/virtio_mmio.tkb` both expose the identical
  `net_init() -> i32` / `net_poll_rx() -> i32` / `net_rx_buf() -> *u8` / `net_transmit(buf, len)` /
  `net_rx_release()` / `net_read_mac(mac_out)` functions -- mirroring how `uart.tkb`/`print.tkb` already
  share identical signatures across `examples/common/` and `examples/common_stm32/`. This means
  `examples/net_echo/net_echo.tkb` (and the other four) are a *single* file compiled against either
  backend depending on target, not a QEMU version plus a hand-maintained `_stm32.tkb` copy -- see that
  file's header comment. Descriptor rings, RX/TX buffers, and virtio's 10-byte `virtio_net_hdr` framing
  are all hidden inside each backend; application code never sees them. `virtio_mmio.tkb`'s `net_poll_rx()`
  now polls the used ring directly instead of waiting on a GIC-routed interrupt (removing
  `gic_init`/`gic_enable_virtio_irq`/`virtio_irq_handler`/`virtio_irq_flag`/every app's identical
  `irq_dispatch` entirely) -- QEMU's virtio-mmio device works identically either way, and
  `examples/common/startup.S` already safely no-ops when the GIC is never initialized (relied on today by
  every non-IRQ example). `gic.tkb` itself is untouched, still used by `irq`/`preempt`/`semaphore`/
  `watchdog`/`condvar`/`msgqueue`.

  **Network config**: `examples/common_stm32/netconfig.tkb` holds the board's MAC/IP as plain global
  constants (`OUR_MAC`/`OUR_IP`/`HTTP_SERVER_IP`, array-literal `{...}` initializers). MAC is a fixed
  `00:80:E1:00:00:00`, matching ST's own STM32CubeF7 LwIP example convention (hardcoded, not derived from
  the chip's unique ID -- see that file's comment for the tradeoff). IP is `192.168.10.2`, the same /24 as
  this devcontainer's point-to-point NIC (`enp4s0`, `192.168.10.1/24`), chosen so the board is reachable
  with zero host-side routing changes. `examples/common/netconfig.tkb` holds the QEMU-side counterpart:
  `OUR_IP` = `192.0.2.1` (RFC 5737 TEST-NET-1) for `arp_reply`/`icmp_echo`/`tcp_echo` (MAC is deliberately
  NOT in this file -- `net_read_mac()`'s virtio-net backend reads it from the device at runtime, nothing to
  share). `http_server.tkb` reads a third constant, `HTTP_SERVER_IP`, instead of `OUR_IP`: on the QEMU side
  this is `10.0.2.15` (SLIRP's fixed `-netdev user` guest address, needed for `hostfwd` to route a real
  browser's connection to the guest at all -- see that file's header comment), while on the STM32 side it's
  simply the same value as `OUR_IP` (no SLIRP-style constraint on real hardware). Both `netconfig.tkb` files
  define the same two variable names (`OUR_IP`, `HTTP_SERVER_IP`) for consistency, even though the STM32
  side's `HTTP_SERVER_IP` is a duplicate of its own `OUR_IP`. This lets every example's `main()` do a single
  unconditional `bytes_copy` from the constant it needs, with no runtime branch at all (see the STM32
  section below for `irq.tkb`'s GIC-vs-NVIC enable sequence, which eliminated its own runtime branch the
  same way -- a per-target pair of definitions behind one uniform name).

  All five are verified against a real point-to-point link via `scripts/eth_*_test.py` + `make hwcheck-net`
  (not part of `make check`/`make hwcheck` since it needs a real board wired directly to the test machine's
  NIC, plus `CAP_NET_RAW`). `make hwcheck-net` aggregates all such Ethernet hardware tests via
  `scripts/run_hwtest_net.sh`, same PASS/FAIL-summary style as `scripts/run_hwtest.sh` -- add new Ethernet
  examples there as they're ported (one `run_net_hw_test NAME BIN TEST_SCRIPT` line), rather than each
  getting its own separate `make` target.

  **Real-hardware-only test wrinkle (first hit porting `tcp_echo`, applies to any future short-segment
  test)**: TCP control segments with no payload (bare SYN/SYN-ACK/FIN-ACK, 54 bytes total) are below
  Ethernet's 60-byte minimum frame size. The STM32 MAC's automatic pad handling (MACCR.APCS) pads
  *outgoing* short frames up to 60 bytes regardless of EtherType -- this is a transmit-side behavior,
  distinct from the *receive*-side stripping ambiguity already documented in
  `scripts/eth_net_echo_test.py`'s module comment (which only applies to frames the board receives). A
  test script slicing "everything remaining in the reply" (safe over virtio-net, which never pads) would
  fold those trailing pad bytes into a TCP checksum verification and fail it for the wrong reason.
  `scripts/eth_tcp_echo_test.py` slices every reply to its exact expected length instead of an open-ended
  slice, for exactly this reason.

  `http_server.tkb` combines `arp_reply`'s ARP response with `tcp_echo`'s state machine in one kernel
  (dispatching on EtherType), plus initiating its own FIN right after the response
  (`build_http_response_fin`) -- needed because a real client always ARPs before sending IP packets,
  unlike the hand-crafted-packet test scripts the other four examples are verified with (both on QEMU,
  via SLIRP, and identically on the real STM32 board, via the devcontainer host's TCP/IP stack). Confirmed
  reachable from the devcontainer host's real TCP/IP stack (`curl http://192.168.10.2/` after flushing the
  ARP neighbor cache, forcing a genuine cold-start ARP resolution + full TCP handshake/request/close --
  request counter incremented `#1` -> `#2` across two requests as expected) and from a real Firefox on the
  same machine. `scripts/eth_http_server_test.py` (wired into `make hwcheck-net` like the other four) is
  deliberately NOT another hand-crafted raw-socket script -- it uses Python's `http.client` over ordinary
  OS sockets (the real TCP/IP stack, same path a browser takes). No `sudo`-only privilege is actually
  needed for the HTTP requests themselves (plain sockets, unlike the other four's raw `AF_PACKET`) -- only
  the `ip neigh flush` step needs root, which `make hwcheck-net`'s existing blanket `sudo` already covers.

  Deliberately still deferred: **polling-only, no interrupt-driven RX** on the STM32 side --
  `examples/common_stm32/startup.S`'s vector table currently only extends through IRQ37 (USART1), and
  every other STM32 example links against that same shared file, so extending it through IRQ61 (ETH) is
  left for a follow-up once polling-only was confirmed working across all five examples.

  **Hardware bring-up bug worth knowing about**: the very first working version had every DMA descriptor field
  byte-for-byte correct (verified live via openocd/gdb-multiarch register+memory dumps) yet the TX descriptor's
  OWN bit would never clear -- the DMA engine simply never acted on it. Root cause: writing the descriptor
  fields (AXI SRAM) and then immediately poking the "poll demand" register (a different peripheral) has no
  ordering guarantee on Cortex-M7 -- `*io` writes in takibi are volatile (the compiler won't reorder/drop them)
  but that says nothing about the CPU's write buffer having actually retired the SRAM write before the very next
  store lands, so the DMA engine could race ahead and read a stale (OWN=0) descriptor. Confirmed by re-issuing
  the poll-demand write by hand through the debugger after enough time had passed for the earlier write to
  settle -- the descriptor completed instantly. Fixed with a `dsb` (Data Synchronization Barrier) instruction
  between the descriptor write and the poll-demand kick (`examples/common_stm32/eth_asm.S`, called via
  `extern fn eth_dsb()` -- same `extern fn` mechanism as `sem_wait`/`sem_post`). **Any future takibi code that
  writes memory a DMA engine will read, then kicks that DMA engine via a register write, needs the same barrier
  -- volatile alone is not enough.**

## QEMU Bare-Metal (AArch64)

- Machine: `virt`, CPU: `cortex-a53`
- PL011 UART register: `0x09000000` (QEMU pre-initializes it, so no baud rate setup needed)
- PL031 RTC register: `0x09010000` (RTCDR: +0, RTCCR: +0x0C) -- 1-second resolution time counter
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
  - To fire at ~15 ms intervals: `lsr x0, cntfrq, #6` -> `msr cntp_tval_el0, x0`
  - The virtual timer (CNTV, PPI #27) requires EL2 hypervisor configuration on QEMU virt, so use the physical timer (CNTP, PPI #30) for bare-metal EL1.

## STM32F746G-DISCOVERY Bare-Metal (Cortex-M7)

Real-hardware port, running alongside (not replacing) the QEMU/AArch64 build. All 38
examples are now ported, including `net_echo`/`arp_reply`/`icmp_echo`/`tcp_echo`/
`http_server` (real Ethernet MAC+PHY driver, `examples/common_stm32/eth.tkb` -- see the
"STM32 Ethernet" entry under Known Limitations/Deferred Design Decisions above for the
full story) and `irq`/`preempt`/`semaphore`/`condvar`/`watchdog`/`msgqueue` (NVIC +
SysTick/PendSV scheduler -- `examples/common_stm32/scheduler.tkb`/`nvic.tkb`). **Every
example is now a single shared `.tkb` file that compiles for both targets** -- no
`_stm32.tkb` variant exists anywhere in this repo anymore; see below for how the last 6
(genuinely the hardest case, since GICv2's and NVIC's dispatch models differ, not just
addresses) got there too.

**Devcontainer/USB setup** (`.devcontainer/devcontainer.json`): `runArgs` passes through
`/dev/bus/usb` (ST-LINK debug/flash interface, VID:PID `0483:374b`) with a
`--device-cgroup-rule` so hot-replug doesn't require editing the device path.
`postCreateCommand` installs `openocd` `stlink-tools` and adds the `vscode` user to the
`plugdev`/`dialout` groups (host GIDs 46/20) so neither needs `sudo`/`sg` after a fresh
rebuild.

**ST-LINK VCP serial (`/dev/ttyACM0`) is deliberately NOT bind-mounted directly** (no
`--device=/dev/ttyACM0`, unlike an earlier version of this file): that form requires the
device to already exist on the host at container create time, so building/starting the
devcontainer would fail outright whenever the ST-LINK wasn't plugged in yet -- a real
problem, since `/dev/bus/usb`'s own hot-replug tolerance (mounting the always-present
parent directory, so individual bus-numbered device files can come and go freely) doesn't
apply to `/dev/ttyACM0` (a flat file directly under `/dev`, with no similarly-stable parent
to mount instead). Fixed by bind-mounting the host's entire `/dev` tree read-only at
`/dev-host` (`-v /dev:/dev-host:ro`) plus `--device-cgroup-rule=c 166:* rmw` (166 = ttyACM's
major number) instead: the devcontainer builds/starts fine with no board attached, and a
board plugged in afterward shows up live at `/dev-host/ttyACM0` with no rebuild/restart.
The container's own `/dev` (and its `/dev/shm`/`/dev/pts` isolation) is left untouched --
only a read-only side path is added, not a replacement of `/dev` itself. The `ro` flag only
blocks directory-level operations (create/delete/rename) on the mirrored tree; it does not
block read/write I/O to a character device reached through it, so `/dev-host/ttyACM0` is
fully usable for serial communication. Path visibility through `/dev-host` is also not the
same as access: the container's cgroup device policy still only allows major 166 (ttyACM)
and 189 (USB) -- e.g. `/dev-host/sda` is visible by name but not actually readable, since
block-device majors were never added to the allowlist. `scripts/run_hwtest.sh`'s
`STM32_SERIAL_DEV` env var and the Makefile's `STM32_SERIAL_DEV` variable both default to
`/dev-host/ttyACM0` accordingly (override to plain `/dev/ttyACM0` only if running this
Makefile outside this devcontainer, e.g. directly on a Linux host with the board attached).

**Build model**: `Makefile`'s `STM32_TARGET`/`STM32_CPU` (`thumbv7em-none-eabi` /
`cortex-m7`) and `STM32_EXAMPLES` list mirror `AARCH64_TARGET`/`EXAMPLES`. Most examples
just recompile the *same* `.tkb` file against `examples/common_stm32/` instead of
`examples/common/` (same pattern as the AArch64 side's compilation groups); a handful
that need one extra common file beyond the standard uart+print pair (`rtc`, `timer`,
`echo`, `irq`, `preempt`, `semaphore`, `condvar`, `watchdog`, `msgqueue`) get their own
one-off rule pairs, same reasoning as the existing `-g` debug-build rules. `make
stm32build` compiles every ported example (no hardware needed, part of `make check`);
`make hwcheck` additionally flashes and verifies each one against the real board (not
part of `make check` -- needs physical hardware).

**Files that turned out to need zero STM32-specific changes**: `examples/common/
print.tkb`, `examples/common/sync.tkb`, `examples/common/inet_checksum.tkb`,
`examples/common/netutil.tkb` are all pure takibi logic with no MMIO addresses --
reused completely unchanged, just recompiled/relinked against the STM32 HAL.

**`irq`/`preempt`/`semaphore`/`condvar`/`watchdog`/`msgqueue` used to need a genuinely
separate `<name>_stm32.tkb`, and are now unified anyway.** GICv2's shared-IRQ-vector-
plus-software-ID-dispatch model and Cortex-M's NVIC-direct-vectoring-plus-SysTick/PendSV
model aren't the same shape behind different addresses -- unlike the networking examples
(where polling replaced interrupts entirely, making the dispatch mechanism invisible to
the app), here the interrupt *entry-point names themselves* are dictated by each
platform's assembly: QEMU's is always `irq_dispatch(frame_sp) -> frame_sp`
(`examples/common/startup.S`'s `irq_entry`); STM32's is `USART1_IRQHandler()` (`irq`) or
`SysTick_Handler()` + `pendsv_dispatch(sp) -> sp` (the other five), vectored directly by
`examples/common_stm32/startup.S`'s hardware vector table. The fix: define **both**
platforms' entry points unconditionally in the one shared file (`examples/preempt/
preempt.tkb`'s header comment has the full reasoning) -- whichever one isn't relevant to
the target being built is simply dead code there, same idea as `OUR_MAC` sitting unused
in `net_echo`'s STM32 binary. Three small pieces of shared infrastructure make both
definitions actually *compile* on both targets:
- **`scheduler_init()`/`scheduler_disable()`/`scheduler_rearm_tick()`** (uniform names,
  real implementations in both `examples/common/timer.tkb` and `examples/common_stm32/
  scheduler.tkb`) hide the one genuine naming/arity mismatch found: STM32's
  `systick_init()` needs an explicit reload value `timer_init()` has no parameter for,
  and the ARM Generic Timer needs re-arming every tick where SysTick auto-reloads and
  doesn't. `main()` calls these three uniformly, no per-platform branch needed for any
  of it. (The `249999` reload value used to be duplicated at every STM32 example's call
  site; hoisting it into `scheduler_init()` removed that too.)
- **`examples/common/stm32_stub.tkb`** (QEMU-only): a no-op stand-in for
  `pendsv_trigger()` -- an STM32-only function that a shared file's dead-under-QEMU
  code (`SysTick_Handler`'s body) still references. Never actually invoked; exists
  solely so compilation succeeds under `aarch64-none-elf` too.
- `watchdog`'s `wdt_check()` needed no hook/override mechanism to call from both
  `irq_dispatch` and `SysTick_Handler` -- both entry points already live in the same
  file, so it's just an ordinary in-file function call on either platform.
- `examples/irq/irq.tkb` additionally needed a tiny `uart_isr_getc() -> u8` added to
  both `uart.tkb` files (PL011 `DR` vs USART1 `RDR` -- the one example here where the
  actual byte-read address, not just the dispatch wrapper, differs by platform), so its
  shared ISR body needs no per-platform branch either. Its interrupt *enable* sequence
  (GICv2 init+SPI-routing vs. NVIC line enable, then a final unmask done after the
  "ready" message so nothing can arrive before the handler is wired up) is handled the
  same way: **`irq_uart_rx_setup()`/`irq_uart_rx_unmask()`** -- uniform names, real
  implementations in `examples/common/gic.tkb` and `examples/common_stm32/nvic.tkb`
  (not `uart.tkb`, even though they're UART-interrupt related: `uart.tkb` is
  concatenated into *every* example's build, including ones that never touch GIC/NVIC
  at all, so a function defined there calling `gic_init()`/`enable_usart1_irq()` would
  fail to resolve on those other builds; `gic.tkb`/`nvic.tkb` are only ever included
  where those symbols already exist). `main()` calls both uniformly with no branch, and
  `register_irq()` itself (writing into a QEMU-only dispatch table) is harmless to call
  unconditionally too, since the STM32 side's `USART1_IRQHandler` never reads that
  table.

**USART1** (VCP, confirmed via ST/Zephyr docs + the board schematic): TX=PA9, RX=PB7,
AF7. STM32F7's USART is the "improved" generation (`CR1/BRR/ISR/ICR/RDR/TDR`), **not**
the classic F1/F4 `SR`/`DR` layout -- copying an F4-style init would silently compile and
produce no output. `uart_init()` uses the default HSI (16MHz) clock, no PLL setup;
`BRR = round(16_000_000 / 115200) = 139` for 115200 baud (OVER8=0, BRR used directly as
the divider in this USART generation, no mantissa/fraction packing).

**RTC**: LSI (~32kHz nominal, imprecise, no external crystal needed), PWR_CR1.DBP unlock
-> RCC_BDCR RTCSEL=LSI+RTCEN -> RTC_WPR 0xCA,0x53 unlock -> RTC_ISR.INIT/INITF -> PRER
left at the LSE-tuned reset default (close enough for "does it visibly tick", not
accurate timekeeping). **RTC_TR is BCD**, not a linear counter like QEMU's PL031 --
`rtc_read_seconds()`/`examples/rtc/rtc.tkb`'s wait loop never subtracts two samples
(`0x09 -> 0x10` is a raw jump of 7, not 1, whenever the BCD units nibble rolls over, not
just at 60 seconds); the loop instead waits for the raw value to change once and, since
that's guaranteed to be exactly one tick by construction, prints a fixed `"1"` rather
than a computed difference. Software must read RTC_DR after RTC_TR (even if unused) to
unfreeze the calendar shadow registers for the next read (RM0385).

**NVIC vs. GICv2**: GICv2 has one shared IRQ vector; the ISR reads `GICC_IAR` to learn
which source fired (software dispatch by ID) and writes `GICC_EOIR` to acknowledge.
NVIC vectors *directly* to a per-source handler address (`examples/common_stm32/
startup.S`'s vector table, 54 words: core exceptions + IRQ0-37) -- no software
dispatch table or EOI register at all; reading/clearing the peripheral's own interrupt
flag (e.g. USART1 RDR read clearing RXNE) *is* the acknowledgment. USART1 = IRQ37
(confirmed via search), vector position 16+37=53, byte offset `0xD4`.

**SysTick+PendSV preemptive scheduler** (`irq_dispatch(frame_sp) -> frame_sp` on the
AArch64 side splits into two on Cortex-M):
- `SysTick_Handler` (plain takibi -- SysTick auto-reloads from `LOAD`, no per-tick rearm
  needed unlike the ARM Generic Timer's `tval`) does per-tick bookkeeping, then requests
  a switch via `pendsv_trigger()` (sets `ICSR.PENDSVSET`).
- `PendSV_Handler` (hand-written asm, `examples/common_stm32/startup.S`, always present
  and lowest priority via `SHPR3=0xFF`) is the only place touching PSP: saves r4-r11
  (hardware already stacked r0-r3/r12/lr/pc/xPSR), calls takibi's
  `pendsv_dispatch(sp) -> sp` (same shape as `irq_dispatch`, round-robin `tcb_sp` swap
  only, no IAR/EOIR), restores r4-r11, `msr psp`, returns via `EXC_RETURN=0xFFFFFFFD`.
- `setup_task_stack` keeps its exact AArch64 name/signature so callers are unchanged;
  only the frame differs -- 64 bytes (8 words hardware-shaped: r0-r3,r12,LR=
  task_exit_stub,PC=f,xPSR=0x01000000; 8 words software-shaped below: r4-r11=0) instead
  of AArch64's 272-byte one. `task_exit_stub` is a plain takibi `while (true) {}` --
  Cortex-M needs no assembly stub for this.
- `sem_wait`/`sem_post` (`examples/common_stm32/sem_asm.S`): ARMv7-M `ldrex`/`strex`
  with explicit `dmb` (no acquire/release-encoded instructions like AArch64's
  `ldaxr`/`stlxr`), `dmb` placed after the successful acquire and before the release
  store (standard ARM Cortex-M synchronization-primitives placement).

**Critical bug found and fixed: MSP/PSP must not overlap.** `Reset_Handler` switches
Thread mode to PSP (`CONTROL.SPSEL=1`) before calling `main`, since a preemptive-
scheduler example treats `main()` as "task 0", switched via the exact same PendSV
mechanism as its explicitly-created tasks -- `main()` must already be on PSP by the
time SysTick/PendSV can first fire (PendSV_Handler unconditionally reads/writes PSP,
but Cortex-M defaults to MSP for everything after reset). The first version of this
switch did `mrs r0,msp; msr psp,r0` -- a plain copy, giving MSP and PSP the *same*
starting address, so the two stacks fully overlapped rather than occupying separate
memory. Every `preempt`/`semaphore`/`condvar`/`msgqueue` test happened to pass anyway
(their task functions and SysTick_Handlers are shallow enough that the corruption never
touched anything load-bearing) until `watchdog` -- whose `SysTick_Handler` calls the
real function `wdt_check()`, using more MSP stack depth -- hit a HardFault. Confirmed via
`openocd`/`gdb-multiarch` register inspection: `CFSR` (`0xE000ED28`) bit 18 = INVPC,
`HFSR` (`0xE000ED2C`) bit 30 = FORCED, `LR = 0xFFFFFFFD` (the fault was inside PendSV's
own exception-return path). Fixed by reserving the top `0x800` (2KB) of the boot stack
region exclusively for MSP and starting PSP that much lower
(`mrs r0,msp; sub r0,r0,#0x800; msr psp,r0`), giving each stack a genuinely separate
region. **Any future change to this switch must keep the two stacks non-overlapping.**

**Hardware test harness** (`scripts/run_hwtest.sh`, `make hwcheck`): flashes via
`st-flash write` and captures UART output, diffing against the *same* `.expected` files
`run_qemutest.sh` already uses (`uart_puts`/`uart_print_*` write identical bytes on
either HAL). Two things had to be solved that QEMU's semihosting-exit model doesn't need
to deal with:
- `st-flash write` itself resets and runs the newly-flashed program as a side effect,
  before the harness ever opens the serial port -- and that unread run's output doesn't
  vanish cleanly (a short tail fragment survives in a small kernel/USB-CDC buffer and
  would otherwise contaminate the *next* capture). Fixed with a drain step (open the
  port, discard whatever's already sitting there) before the real, explicitly-triggered
  `st-flash reset` that the harness actually measures.
- A fixed-duration `timeout N cat` capture (this project's first approach) was
  needlessly slow multiplied across ~40 examples per run, *and* wrong for examples with
  a real mid-test pause (`rtc`/`timer` wait up to an LSI-clocked "second" between two
  print statements; a naive short idle-quiet threshold mistook that pause for
  completion and truncated the capture). Replaced with `read_until_quiet`: polls file
  size until no growth for N consecutive polls, with a `WAIT_FOR_DATA` gate (don't
  declare quiet before anything has arrived at all -- needed since the reader starts
  before the `st-flash reset` that actually triggers output) and per-call overrides for
  tests needing a longer pause tolerance (`rtc`/`timer` use a much longer idle threshold
  than the ~200ms default). Cut the full suite from ~125s to ~30-45s.
- `echo`/`irq` (the two examples needing input) use `run_hw_test_stdin`: waits for the
  first output byte (confirming the firmware's read loop has actually started, since
  USART's RDR is only 1 byte deep -- writing input any earlier risks an overrun) before
  writing the `.stdin` file to the serial port.

## virtio-net Examples (examples/net_echo, examples/arp_reply, examples/icmp_echo)

QEMU-only stepping stones toward the TCP/IP stack goal, each adding one
protocol layer on top of the same virtqueue/DMA/IRQ plumbing:
- `net_echo`: receives a raw Ethernet frame over virtio-net, swaps
  src/dst MAC, sends it back unchanged otherwise. No protocol parsing at
  all -- proves the plumbing works.
- `arp_reply`: answers ARP "who-has 192.0.2.1" with "is-at <our MAC>"
  (192.0.2.1 is RFC 5737 TEST-NET-1, chosen specifically because it's
  reserved for exactly this kind of test/example use); every other frame
  (wrong EtherType, wrong OPER, request for a different IP) is dropped,
  not echoed. First real protocol dispatch and in-place header rewriting.
- `icmp_echo`: answers ICMP echo requests (ping) addressed to 192.0.2.1
  with an echo reply, preserving identifier/sequence/payload. First
  example needing a *correct* checksum on the wire (not just a validated
  one) -- see the inet_checksum/ip_parse entries below for the two smaller
  steps this was deliberately split from.

`virtio-net` doesn't exist on real hardware (RPi3/RISC-V/STM32 will need
dedicated MAC/PHY drivers later); what transfers is the ring-buffer/IRQ
pattern and the raw-byte-offset header manipulation technique, not the
virtio protocol itself.

- **Legacy virtio-mmio only** (`-global virtio-mmio.force-legacy=on`).
  Skips the FEATURES_OK handshake and the split 64-bit feature/queue-address
  registers of modern (v2) virtio-mmio -- Version register reads 1. This
  depends on a QEMU compatibility knob that could be removed in a future
  release; if legacy mode disappears, this driver needs a rewrite against
  the modern register layout.
- **The virtio-mmio slot is discovered at boot, not hardcoded**
  (`virtio_net_find()` in `examples/common/virtio_mmio.tkb`). A lone
  `-device virtio-net-device` does NOT land on slot 0: empirically, under
  this devcontainer's QEMU 8.2.2, it landed on slot 31 (base `0x0a003e00`).
  The driver scans all 32 slots for `DeviceID == 1` (network) and derives
  the base address from whatever slot it actually finds, so a future QEMU
  version placing the device elsewhere doesn't break it. (Earlier versions
  of this driver also derived a GIC IRQ number from the discovered slot
  for interrupt-driven RX; `net_poll_rx()` now polls the used ring
  directly instead, so no IRQ/GIC involvement remains here at all -- see
  the STM32 Ethernet entry above for why and when that changed.)
- **The vring is manipulated as raw byte offsets, not struct arrays.**
  Struct field assignment only supports `ident.field = v` (a bare variable
  name on the left -- see "Current limitations" under Struct Implementation
  above), so a descriptor-table *entry* picked out by a runtime index
  (`descs[i].field = v`) isn't expressible. `desc_set`/`avail_ring_set`/
  `used_ring_get_*` in `virtio_mmio.tkb` poke fixed byte offsets through
  cast pointers instead, the same way a minimal C driver would.
  `arp_reply.tkb` extends the same technique to the ARP header itself
  (`bytes_eq`/`bytes_copy`/`read_u16be`/`write_u16be`), rewriting the
  request into a reply in place with no temporary struct/copy -- this was
  a deliberate choice over copying into a local struct and back (see
  git history around 2026-07 for the reasoning): raw offsets touch only
  the bytes that actually change and avoid a full extra copy in and out,
  and takibi has no struct-literal-from-bytes/memcpy builtin that would
  make the copy-based version meaningfully shorter anyway.
- **MAC/IP fields are always handled as raw byte arrays, never as a single
  multi-byte integer.** They're compared/copied byte-by-byte
  (`bytes_eq`/`bytes_copy`), not loaded as e.g. a `u32`, specifically to
  avoid an endianness bug: ARP fields are big-endian on the wire, this
  target is little-endian, and a raw multi-byte load would silently
  byte-reverse the value. `read_u16be`/`write_u16be` (used for EtherType
  and ARP OPER, which *are* conventionally written/compared as 16-bit hex
  constants like `0x0806`) manually compose/decompose big-endian integers
  from individual byte reads/writes instead of relying on the host's
  native load width, sidestepping the issue entirely regardless of target
  endianness.
- **`arp_reply.tkb` reads its own MAC from the device instead of
  hardcoding it**, via `virtio_net_read_mac()` in `virtio_mmio.tkb`
  (Config space offset `0x100`, gated on negotiating `VIRTIO_NET_F_MAC`).
  This is why `virtio_negotiate()` takes a `features: i32` parameter
  instead of always acking 0 -- `net_echo.tkb` still passes `0` (it never
  reads Config space), `arp_reply.tkb` passes `VIRTIO_NET_F_MAC`. Avoids a
  second hardcoded MAC constant that would need to be kept in sync with
  the QEMU command line's `mac=` value.
- **Used-ring polling reads must be `io`.** `used_idx_get` etc. read memory
  the device writes via DMA and are polled in a busy-wait loop in the main
  loop -- exactly the "LLVM may hoist a load out of a tight loop" hazard
  described under "Volatile Reads of Global Variables" above, since
  nothing else marks that memory as externally modified.
- **Test harness**: `scripts/virtio_net_test.py`, `scripts/arp_test.py`,
  and `scripts/icmp_echo_test.py` send/verify raw frames over a UDP-backed
  `-netdev dgram` (one UDP datagram == one raw Ethernet frame, no
  ARP/DHCP noise since it's a private point-to-point socket, unlike
  `-netdev user`). This is the one place in the test suite that depends
  on Python -- `run_qemutest.sh` invokes them via
  `run_virtio_test NAME KERNEL SCRIPT`, which judges pass/fail by the
  script's exit code rather than diffing QEMU's stdout, so the kernels
  are free to print debug output. Deliberately NOT unit-tested in
  isolation (no QEMU-free test of the comparison logic): the scripts are
  simple enough (plain byte-equality checks) that the cost of a second,
  QEMU-booting "does the test detect a broken echo" test wasn't judged
  worth it -- see git history around 2026-07 if that tradeoff needs
  revisiting as the scripts grow more complex.

### IPv4/ICMP: split into 3 deliberately small steps (examples/inet_checksum, examples/ip_parse, examples/icmp_echo)

The original ask was "an IPv4 echo server" (ICMP ping responder), but that
bundles two genuinely new things at once -- the Internet checksum
algorithm (RFC 1071) and real virtio-net RX/TX of a new protocol -- making
failures hard to attribute to one or the other. Split into three
increasingly-integrated steps instead:

1. **`examples/inet_checksum`** -- the checksum algorithm alone, no
   networking I/O at all, following the exact same pure-compute demo
   pattern as `crc8.tkb`/`djb2.tkb` (operate on a fixed buffer, print a
   hex result, diff against a `.expected` file). Test vector is a real
   20-byte IPv4 header, verified independently in Python before being
   committed: checksumming it with its correct checksum field in place
   yields `0x0000` (how a receiver verifies a packet); checksumming it
   with that field zeroed yields `0xb1e6`, the value that belongs there
   (how a sender computes it). The function itself lives in
   `examples/common/inet_checksum.tkb` so `ip_parse` and `icmp_echo` can
   both reuse it rather than duplicating it.
2. **`examples/ip_parse`** -- IPv4 header field extraction and checksum
   *validation* only, no reply, and deliberately **not** wired to
   virtio-net at all: it parses two canned buffers baked into the binary
   (one valid, one with a corrupted TTL so the checksum no longer
   verifies) and prints the results. The virtqueue/IRQ plumbing was
   already fully proven by `net_echo`/`arp_reply`; re-exercising it here
   would test the same thing twice while adding nothing to what's new in
   this step (the parsing logic itself). Scope is intentionally narrow:
   only headers with no IP options (IHL must be exactly 5/20 bytes).
3. **`examples/icmp_echo`** -- the real thing: live virtio-net RX/TX
   (same pattern as `net_echo`/`arp_reply`) combined with IPv4/ICMP
   parsing and, for the first time, checksum *construction* (not just
   validation) for the reply. Validates the request's IP and ICMP
   checksums independently before replying and silently drops anything
   that fails either check, isn't addressed to `our_ip`, or isn't a
   well-formed echo request -- `scripts/icmp_echo_test.py` explicitly
   tests a corrupted-checksum request is dropped, not just that a valid
   one is answered. Builds the reply in place (swap MACs, swap IPs, fresh
   TTL, ICMP type 8->0, identifier/sequence/payload untouched) and
   recomputes both checksums from scratch with `inet_checksum` rather
   than attempting an incremental update -- simpler and reuses the
   already-verified function instead of a second, subtler algorithm.
- **`run_qemutest.sh` prints a `Failed: name1 name2 ...` line in its final
  summary** (via a `FAILED_TESTS` array appended to on every failure
  branch) rather than stopping at the first failure. Deliberate: QEMU
  boot cost makes fail-fast expensive to iterate against in CI (you'd only
  learn about the next failure after fixing and re-running), so the
  script always runs everything and reports the full failure list at the
  end instead.

### TCP: examples/tcp_parse (parse-only) + examples/tcp_echo (grown incrementally)

TCP is being split differently than IPv4/ICMP was, because TCP itself
splits into two genuinely different kinds of step:

- **`examples/tcp_parse`** is a one-shot separate example, exactly
  mirroring `ip_parse`: canned buffers, no virtio-net, just field
  extraction and checksum validation. This is a clean split because
  header parsing is a self-contained concern independent of connection
  state.
- **`examples/tcp_echo`** (handshake -> data echo -> close) is deliberately
  **one example grown incrementally**, not a separate example per stage:
  unlike ARP/ICMP (stateless, one-frame-in-one-frame-out), TCP's stages
  share a connection, so a standalone "handshake-only" binary wouldn't be
  a real artifact. Regression granularity instead comes from accumulating
  test *functions* in `scripts/tcp_echo_test.py` (mirrors
  `icmp_echo_test.py`'s multi-function structure), one per stage --
  `test_handshake_only`, `test_data_echo`, `test_close`,
  `test_reconnect_after_close`. **These functions are not independent**:
  `tcp_echo.tkb` supports exactly one connection, so
  `test_data_echo()`/`test_close()` continue the *same* connection
  `test_handshake_only()` established (shared module-level constants:
  `HANDSHAKE_CLIENT_PORT`/`HANDSHAKE_CLIENT_ISN`/`SERVER_ISN`) and must run
  in that order (`main()`'s `ok4 = ok3 and test_data_echo()` chain). Each
  still prints its own labeled PASS/FAIL line, so per-stage regression
  attribution still works even though execution is a chain, not
  independent calls. `test_reconnect_after_close()` is the one function
  that *is* independent -- a brand new connection after `test_close()` --
  specifically to catch a "close looks right but forgot to reset
  `conn_state`" bug that `test_close()` alone can't see (it only checks
  the reply, not that the server is usable again afterward).

  State cycle: `TCP_LISTEN` -> `TCP_SYN_RCVD` -> `TCP_ESTABLISHED` ->
  `TCP_LAST_ACK` -> back to `TCP_LISTEN`. No separate `CLOSE_WAIT`/
  `FIN_WAIT`: the server never has queued outbound data by the time a
  client FINs, so it ACKs the FIN and sends its own FIN in the same
  segment (`build_fin_ack`) rather than as two events.

**TCP checksum needs a "pseudo-header"** (12 bytes: src IP, dst IP, a
zero byte, protocol, TCP length) that is never actually transmitted but
is included in the checksum computation, prepended to the TCP header+data.
This doesn't fit `inet_checksum`'s single-contiguous-buffer signature, so
`examples/common/inet_checksum.tkb` was split into `checksum_add(data,
len, sum_in)` (accumulates an *unfolded* running sum, chainable across
non-contiguous buffers) and `checksum_fold(sum)` (carries + one's
complement, done once at the end) -- `inet_checksum` itself is now just
`checksum_fold(checksum_add(data, len, 0))`, so `ip_parse`/`icmp_echo`
needed no changes. The two-chunk chaining is valid per RFC 1071 because
the pseudo-header is exactly 12 bytes (a whole number of 16-bit words),
so only the *last* chunk (the actual TCP segment) can be odd-length and
need padding -- see `checksum_add`'s comment.

**`bytes_eq`/`bytes_copy`/`read_u16be`/`write_u16be` were extracted into
`examples/common/netutil.tkb`** at this point too (previously duplicated
verbatim in both `arp_reply.tkb` and `icmp_echo.tkb`) -- three call sites
needing the same four helpers was the threshold where deduplication
clearly paid for itself. Also added `read_u32be`/`write_u32be` for TCP's
32-bit sequence/acknowledgment numbers, same big-endian-byte-by-byte
reasoning as the 16-bit versions. Note `read_u32be` can produce a
"negative" `i32` bit pattern for seq numbers >= `0x80000000` (i32 is
signed) -- harmless for display (print via `uart_print_hex`, which shows
the bit pattern regardless of sign, not `uart_print_uint`, which assumes
non-negative) and harmless for the modular arithmetic TCP sequence
numbers actually need, but worth remembering if a future step adds
seq-number *comparisons* (`<`, `>`) -- those need wraparound-aware
comparison logic, not a plain signed or unsigned `<`.

## HTTP Server (examples/http_server) -- the TCP/IP progression's payoff

Serves a single styled HTML page (inline CSS, dark/monospace theme) with
a live request counter on port 80. Built on `tcp_echo`'s state machine
(same LISTEN/SYN_RCVD/ESTABLISHED/LAST_ACK cycle), but is the first
example that is genuinely usable from a real browser, not just the
`-netdev dgram` synthetic test transport -- and getting that working
surfaced two real bugs/gaps that no earlier example's automated tests had
caught, because those tests only ever talked to *themselves*
(hand-crafted Python packets, never a real TCP/IP stack):

- **QEMU's `-netdev user` (SLIRP) refuses to deliver any IP packet until
  the guest has answered an ARP request for its address.** `net_echo`'s
  and `arp_reply`'s own tests never needed this, because `-netdev dgram`
  is a raw point-to-point pipe where the python script already knows the
  guest's MAC -- there's no link layer to resolve. A real network path
  always has one. Consequence: `http_server.tkb` has to combine ARP
  response (reused from `arp_reply.tkb`) and TCP/HTTP handling in the
  *same* kernel, dispatching on ethertype, since only one kernel can run
  at a time. Discovered by writing a throwaway probe kernel that just
  logged every received frame's ethertype under `-netdev user` -- only
  ARP frames showed up until ARP response was added.
- **Real TCP clients (SLIRP's kernel-grade TCP stack, and any real
  browser) always include a TCP options block on the SYN** (at minimum an
  MSS option, making the header 24 bytes / data offset 6, not the bare
  20-byte / data-offset-5 header `tcp_echo.tkb` and `tcp_parse.tkb`
  originally required). Since `scripts/*_test.py` construct every packet
  by hand and never bothered with options, this was completely invisible
  to `make qemutest` -- it only surfaced once tested against a real
  client. Fixed in both `http_server.tkb` and (for consistency,
  afterward) `tcp_echo.tkb`: compute `tcp_hdr_len` from the segment's
  actual data offset (accepting doff 5..15) and use it to locate where
  data starts, rather than hardcoding the no-options 20-byte assumption;
  options themselves are never parsed, just skipped over.
  `tcp_parse.tkb` turned out not to need this fix at all -- it already
  computed and *displayed* `data_offset` generically, it just never used
  it to locate anything (no reply construction, so nothing was ever
  assumed to start at a fixed offset).

  **The fix is not just "accept a wider range of doff values"; the data
  itself has to move.** `tcp_echo.tkb`'s echo reply always writes a clean
  20-byte header (no options) starting at `tcp+0`, so if the *received*
  segment had a 24-byte header, its payload sits at `tcp+24`, not
  `tcp+20` -- reusing the same buffer in place without shifting the
  payload down would silently prepend 4 bytes of stale option data and
  truncate the last 4 bytes of the real payload. `build_data_echo` now
  takes the actual data pointer and `bytes_copy`s it down to `tcp+20`
  first when they differ; safe even though the ranges can overlap,
  because the destination never leads the source and the copy loop goes
  forward (same direction requirement as `memmove` for this case -- see
  the function's comment). Loosening the acceptance check *without* this
  shift would have silently swapped "reject options-bearing segments" for
  "corrupt them," which is worse. `scripts/tcp_echo_test.py` gained
  `test_syn_with_options_accepted()` (sends a SYN with a real 4-byte MSS
  option, verifies a normal SYN-ACK, then RSTs the half-open connection
  so it doesn't hold the single connection slot for the rest of the
  file's tests) so this doesn't silently regress again.

**our_ip is `10.0.2.15`, not the `192.0.2.1` TEST-NET-1 address every
earlier example uses.** SLIRP's `hostfwd` rule routes to a fixed default
guest address (confirmed empirically, not just from memory -- see the
probe kernel above), and the guest must actually own that address for
the connection to land anywhere. `scripts/http_server_test.py` (still a
`-netdev dgram` test) uses the same `10.0.2.15` for consistency even
though its raw transport doesn't technically require it.

**Response construction needed two new `netutil.tkb` primitives**:
`copy_str(dst, src)` (copies a NUL-terminated string literal into a
buffer, returns length -- same idea as `uart_puts` but targeting memory
instead of streaming to UART) and `write_udec(buf, n)` (writes decimal
digits with no leading zeros, returns digit count -- same recursive
approach as `print.tkb`'s `uart_print_uint`, targeting a buffer). Needed
because the response's `Content-Length` and the request counter are both
variable-width at runtime, so the response has to be *built* (body first,
into a staging buffer `html_body`, to learn its length; then headers,
using that now-known length; then the body copied in after) rather than
templated with a fixed size like every earlier fixed-format reply
(SYN-ACK, ICMP echo reply, etc.) was.

**Manual browser access**: `make qemu-http-server` (uses `-netdev
user,hostfwd=tcp::$(HTTP_HOST_PORT)-:80` instead of the automated tests'
`-netdev dgram`; `HTTP_HOST_PORT` defaults to 18080 -- not 8080, which
immediately collided with Syncthing on a real dev machine the first time
this was tried outside the devcontainer; override with e.g.
`make qemu-http-server HTTP_HOST_PORT=8081` if 18080 is also taken), then
open `http://localhost:18080/` in a real browser. Reloading the page
re-runs the whole connect/request/respond/close cycle and the counter
visibly increments -- this is deliberately *not* something
`make qemutest` exercises (see the request-counter determinism note
below), since it depends on a human clicking reload, not a scripted
sequence.

`qemu-http-server` quits on plain **Ctrl-C** (every other `qemu-*` target
needs QEMU's Ctrl-A X escape instead) -- see `HTTP_SERVER_QEMU_FLAGS` in
the Makefile for the full reasoning (raw-mode terminal pass-through vs.
`-serial file:/dev/stdout`, confirmed via `kill -INT` rather than assumed).
The Makefile target also echoes the actual browser URL right before
launching QEMU, since the guest has no way to know the host-side
`HTTP_HOST_PORT`.

**`make stm32-http-server`**: same demo, on the real STM32F746G-DISCOVERY board instead of
QEMU (flashes `examples/http_server/kernel_stm32.bin` via `st-flash`, prints the URL to open,
then streams the board's own UART log lines until Ctrl-C). Unlike `qemu-http-server`'s fixed
`localhost:$(HTTP_HOST_PORT)`, the printed URL is parsed live from `examples/common_stm32/
netconfig.tkb`'s `HTTP_SERVER_IP` constant (`grep`+`tr`, no hardcoded IP in the Makefile), so it
can't silently drift out of sync if that constant is ever changed. The serial reader is
attached (backgrounded) *before* the explicit `st-flash reset`, not after, so the board's
earliest "ready" message isn't lost to a reader that hasn't opened the port yet -- same
ordering reasoning as `read_until_quiet`'s `WAIT_FOR_DATA` case in `scripts/run_hwtest.sh`.
Needs the board connected and its Ethernet port wired directly to this machine's NIC (see the
STM32 hardware bring-up section's devcontainer note for the `/dev-host/ttyACM0` serial path).

**Request counter determinism** (flagged as a concern before
implementation, worth recording why it's actually safe): `make qemutest`
boots a fresh QEMU process per test, so `request_count` always starts at
0. `scripts/http_server_test.py` sends exactly two real, sequential
requests and asserts the counter reads 1 then 2 -- deterministic, not
timing-dependent. The one way this *could* have been flaky is if a
network-level retry (see `send_and_wait`, used for the SYN and the GET in
case a packet is lost before the guest finishes booting) caused the
server to process the same logical request twice; it can't, because the
retry resends the identical frame bytes (same sequence number), and the
server only acts on a segment when its `seq` matches `conn_rcv_nxt`
exactly -- a resent duplicate's `seq` is already stale by the time a
retry would fire, so it's silently ignored. This is the same
duplicate-suppression property `tcp_echo_test.py` already depends on,
just relied on for a new reason here.

## Execution Profiling (QEMU)

Two things exist here: DWARF debug-info emission in the compiler itself
(so a real profiler/debugger has line info to resolve addresses against),
and a small gdbstub-based sampling profiler built on top of it
(`scripts/profile_*.py`) to actually try using that info on a real
example. The headline finding from building and using the profiler is
**this specific technique only works for CPU-bound code, not for the
network servers it was originally built to profile** -- read the "What
actually worked" section below before reaching for it again.

**DWARF (`-g`)**: `takibi ... -g -o out.o` emits DWARF line-table debug
info (compile unit / per-file `DIFile` / per-function `DISubprogram`, plus
`DILocation` on every statement) via the `Llvm_debuginfo` OCaml binding
(`lib/llvm_gen.ml`). `DW_TAG_variable`/`DW_TAG_formal_parameter` entries
are also emitted for `let mut` locals and parameters (immutable `let`
bindings and struct-typed fields are deliberately left out -- see
`lib/llvm_gen.ml`'s `ditype_of_ast` comment for why: immutable bindings
have no memory location to point a `dbg.declare` at, and struct types are
represented as memberless forward declarations to sidestep both
self-referential-struct recursion and needing per-field byte offsets, an
acceptable simplification since neither profiling nor basic scalar/pointer
variable inspection needs it). `DEBUG=1`-style global flags were
considered and rejected in favor of per-example dedicated `.debug.o`/
`kernel.debug.elf` build rules (see `examples/fizzbuzz`, `examples/
fibonacci`, `examples/http_server`, `examples/tcp_echo` in the Makefile)
kept entirely separate from the normal (always `-g`-free) build outputs --
this is also why `scripts/run_qemutest.sh`'s `run_dwarf_test`/
`run_dwarf_var_test` use narrow, targeted queries (`llvm-dwarfdump-19
--name=<X>`, checking 5 independent substrings) rather than diffing full
`llvm-dwarfdump` output: a full diff would couple the test suite to
LLVM's internal text formatting (attribute order, wording), which isn't
what's actually being tested.

**The sampling profiler**: `scripts/profile_pc_sampler.py` is the reusable
core -- it spawns `gdb-multiarch` fresh *per sample* against a QEMU
gdbstub (`-gdb tcp::PORT`, no `-S`) and just connects + `print/x $pc` +
detaches. This relies on two behaviors confirmed empirically before
writing it: connecting to QEMU's gdbstub halts the vCPU (so `$pc` is a
live snapshot), and detaching resumes it. This is deliberately NOT built
around a single long-lived gdb session using `continue &` + `interrupt`
(the more obvious "poor man's profiler" design) -- that was tried first
and abandoned because gdb's Python `interrupt` sends the stop request
asynchronously and doesn't reliably flip gdb's internal running/stopped
bookkeeping within batch mode (`gdb.error: Selected thread is running`,
even after polling `is_running()` for a full second). The per-sample
subprocess approach costs about 75ms of gdb startup overhead per sample
(measured in this devcontainer) but sidesteps that whole class of problem.
Requires `gdb-multiarch`, not stock `gdb` -- see the Dependencies section.

`scripts/profile_http_server.py` and `scripts/profile_tcp_echo.py` (run
via `make profile-http-server` / `make profile-tcp-echo`) are the two
existing entry points, each pairing the sampler with a purpose-built load
generator (`profile_http_load.py`, `profile_tcp_burst_load.py`).

**What actually worked, and what didn't**: profiling `http_server.tkb`
under real request traffic put **100% of samples in the idle interrupt-
wait loop** (`while (*flag_p == 0) {}`, http_server.tkb:283) -- because
each HTTP request/response cycle is dominated by network round trips plus
`http_server_test.py`'s deliberate 1-second "confirm silence"
correctness check, the server is idle almost the entire wall-clock
duration of a request, which is comfortably longer than the sampler's
~75ms resolution. Switching to `tcp_echo.tkb` (one layer below HTTP) with
a workload designed to remove that dead time (one connection, no
silence-check waits, near-max-size 1400-byte payloads sent back to back)
hit the *same* 100%-idle result, but for a deeper, protocol-level reason
found by reading the code: `tcp_echo.tkb` only accepts a new data segment
when `ack == conn_snd_nxt` (see `examples/tcp_echo/tcp_echo.tkb`'s
segment-accept condition), meaning at most one unacknowledged segment can
ever be in flight -- there is no client-side trick that can queue up
several packets' worth of continuous processing, because the server's own
state machine has no pipelining/sliding-window support (a deliberate
simplicity choice, see the TCP section above). So for *both* examples, the
actual per-packet compute (checksum, copy, header rewrite) is real but
far too short relative to 75ms to ever get sampled -- this is a resolution
mismatch, not something fixable by taking more samples or generating more
load.

To confirm the sampler itself is sound and the failure above is really
about *this specific I/O-bound workload shape* rather than the tool, it
was validated against a throwaway pure-compute program (two functions,
`heavy_a` looping 4x more than `heavy_b`, no I/O at all, run for ~18s):
the profile came back 82.5%/17.5%, matching the 80/20 iteration-count
ratio closely. **Conclusion: this technique is a reasonable tool for
comparing CPU-bound code paths against each other (e.g. "which of these
two checksum implementations is hotter"), but not for finding a hot spot
inside network/interrupt-driven I/O code**, where the interesting work is
sub-millisecond and buried in mostly-idle wall-clock time.

**Cortex-A (this QEMU target / a real Raspberry Pi 3) vs. Cortex-M
(STM32) need genuinely different profiling techniques, not just a change
of debug probe.** This gdbstub-halt-sampling technique works on any
Cortex-A/AArch64 target (QEMU or real RPi3 hardware) but does not carry
over to STM32 as the "right" approach. Cortex-M cores have a hardware
ITM/DWT unit that can sample the PC and stream it out over the SWO pin
essentially for free (<1% overhead reported by SEGGER); that mechanism
does not exist on Cortex-A at all -- it's a completely different piece of
silicon, not a QEMU limitation. Practical notes for when STM32 profiling
actually comes up: ST-Link's SWO support has been reported unreliable
across firmware versions (a J-Link-class probe is the safer bet for
serious tracing); SEGGER SystemView / Percepio Tracealyzer are the
de-facto industry-standard tools built on top of that hardware; a
from-scratch external gdb+OpenOCD halt-sampler (this project's technique,
ported) also works on Cortex-M without needing SWO at all, but real
hardware reports ~50ms/sample overhead for that approach (similar
resolution problem to what was found here) plus a new consideration QEMU
doesn't have: each halt is a genuine physical interruption of the running
target (real observer effect on timing-sensitive code), not just a paused
software process.

## Instructions for Claude Code

- **Do not create git commits.** Only do so when the user explicitly requests it.
- Prefer idiomatic OCaml style. Use `Map.Make(String)` over `Hashtbl`.
- Do not use the `base` package (it causes friction at the boundary with LLVM bindings).
- The user is an OCaml beginner, so explain the reason for code changes from the perspective of "why write it this way."
- **Do not save memories to `~/.claude`.** Consolidate project-specific information in this file (it cannot be shared across environments).
- **All text in this repository must be ASCII-only.** Never write Japanese or any other non-ASCII characters in source files, comments, documentation, or any other file. `make langcheck` enforces this and will fail if non-ASCII characters are found.

## Dependencies

```
ocaml 5.4.0, dune, menhir
llvm-19 OCaml bindings (llvm, llvm.analysis, llvm.target, llvm.all_backends, llvm.passbuilder, llvm.debuginfo)
ppx_deriving.show
llvm-mc-19, ld.lld-19   (for bare-metal builds)
qemu-system-aarch64     (for QEMU execution)
gdb-multiarch           (AArch64-capable gdb; stock `gdb` on this platform is x86_64-only and
                         cannot parse QEMU's AArch64 target-description XML over the remote
                         protocol -- confirmed by the "unknown architecture aarch64" / truncated
                         register errors it raises. Needed for gdb-remote-based tooling, e.g. a
                         QEMU-based sampling profiler; not needed for DWARF emission itself.
                         Also used for STM32 hardware debugging via openocd's gdbstub.)
openocd, stlink-tools   (for STM32F746G-DISCOVERY: openocd for SWD debug/register inspection,
                         `st-flash`/`st-info` (stlink-tools) for flashing -- see "STM32F746G-
                         DISCOVERY Bare-Metal" above. Requires USB passthrough set up in
                         .devcontainer/devcontainer.json; `make hwcheck` needs the real board
                         connected, everything else (including `make check`'s `stm32build`)
                         does not.)
```
