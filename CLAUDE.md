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
  - `[T; N]` array size `N` may be a literal integer, the name of an immutable global declared earlier (in the concatenated source) with a bare literal integer initializer, or `+`/`-`/`*`/`/` arithmetic combining those (parentheses allowed for grouping), e.g. `let QUEUE_SIZE: i32 = 16; let mut ring: [T; QUEUE_SIZE]; let mut pair: [T; QUEUE_SIZE * 2];`. Resolved entirely in the parser (see "Array-Size Constants" below); no forward references. This arithmetic folding is scoped to the `[T; N]` grammar position only -- a global `let`'s own initializer expression still cannot fold arithmetic (see "Global Constant Folding" below for what that one does and does not support).
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

### {lo..<hi} Bounds Are Rejected Outside i32 Range at Parse Time

**Superseded in part by "Refinement Numerical Type" below**: `TRefinedInt`/
`TypeRefined` no longer always represents as i32 at the LLVM level in
general -- it now carries its own base type (`TRefinedInt of int * int *
ty`), and `ltype_of_ast`/codegen represent it at that base's actual
width. What remains true, and is what this section is actually about: the
SURFACE `{lo..<hi}` type syntax (what a programmer can literally type)
always constructs base = i32 (`lib/parser.mly`'s `type_expr` rule hardcodes
`TypeI32`) -- there is no source syntax for writing a refined u64/i64
directly, only the compiler's own range-propagation machinery (Add/Sub/
Mul/Band/Mod/min/max/narrowing) ever produces a non-i32 base. So the
range check below (bounds must fit in i32) is specifically a limit on
the parsed surface syntax, not a general limit on every `TRefinedInt`
value that can exist internally. Subtyping a `{lo..<hi}` value into a
wider/narrower concrete type (u8, u64, usize, ...) remains a separate
check (`lib/types.ml`'s `TRefinedInt _, TU8/TU16/TU32/TU64/TUsize/TI8/
TI16/TI64 when ...` cases), unrelated to which base the value's own
representation happens to carry.

`lo`/`hi` come from the `INT` token (originally OCaml `int`, 63-bit; now
`Int64.t` -- see "64-bit Integer Literals" below for why that changed), so
a bound outside i32's range (e.g. `{0..<5000000000}`) used to parse and
type-check with no error, then silently misbehave at codegen time -- e.g.
`emit_refined_cast_check`'s `const_int (i32_type context) hi` truncates
`hi` to its low 32 bits, turning a nonsensical range into a wrapped-around
one with no warning. This was a real, if never-yet-triggered, latent
soundness hole (no example ever wrote a bound this large -- embedded
buffer sizes stay well under 2^31 -- but nothing stopped it).

Fixed in `lib/parser.mly`'s `type_expr` rule (the single grammar
production that ever constructs a literal `TypeRefined` from source,
covering every use site: parameter/return types, `let` annotations, and
`expr as {lo..<hi}` casts): `lo < -2147483648L || hi > 2147483647L` (an
`Int64.t` comparison now) is a compile error (`Types.TypeError`), raised
at the same `$symbolstartpos` pattern already used by `array_size`'s
unknown-constant error, before the checked value is narrowed to `int` via
`Int64.to_int` for storage in `TypeRefined`'s `int * int` fields (safe at
that point -- the check already proved it fits comfortably in i32, let
alone a 63-bit native int). The lower bound is currently unreachable via
source syntax (`{lo..<hi}`'s grammar only accepts a bare non-negative
`INT` token for `lo`/`hi` -- no unary minus support at the type level, a
separate pre-existing limitation, not one this check introduces), but is
included for when that syntax gap is closed. Test coverage:
`test/test_takibi.ml`'s parser_tests (in-range bound parses, out-of-range
upper bound is a `TypeError` mentioning "i32 range").

**Deliberately NOT addressed by this fix**: widening `TRefinedInt` itself
to genuinely support ranges beyond i32 (e.g. for `usize`/`u64`/`i64`
values whose real range exceeds 2^31, such as an SD card LBA offset
`lba * 512` on a card larger than 2GB). This is a bigger change (a new
LLVM-level representation choice, propagating through every binop/
narrowing rule) with no concrete example needing it yet -- deferred until
one does, per this project's usual practice of not generalizing ahead of
a real need. The guard added here only prevents *silent miscompilation*
of an out-of-range bound; it does not lift the range limit itself.

### 64-bit Integer Literals (IntLit's Payload: `int` -> `Int64.t`)

**The bug**: `Ast.IntLit` was `IntLit of int` -- OCaml's native `int`,
63 bits on a 64-bit host (`Sys.int_size = 63`). `lib/lexer.mll` parsed
literals via plain `int_of_string`, which raises an uncaught `Failure`
(a raw OCaml exception, not a clean compile error) for any literal at or
beyond 2^62 -- e.g. `0xFFFFFFFFFFFFFFFF` crashed the compiler outright,
even in a plain function body with no global involved. Below that
threshold there was a second, quieter bug: `lib/llvm_gen.ml`'s `gen_expr`
unconditionally embedded every `IntLit` as `const_int (i32_type context)
i`, truncating the value to 32 bits before the surrounding `coerce`/widen
logic ever got a chance to see it -- so `let x: u64 = 5000000000;` (a
value comfortably within OCaml's 63-bit int and requiring no cast at all)
silently became a *wrong*, truncated-then-zero-extended value, since
`const_int` wraps its input to the target type's width with no warning.
Filed as GitHub issue "IntLit support 64bit value" and fixed here.

**Representation choice: `Int64.t`, not a bignum**. u64's range
(0..2^64-1) does not fit in a *signed* 64-bit container either in
principle, but `Int64.t` is exactly the right tool anyway: LLVM constants
have no inherent signedness (a bit pattern is a bit pattern; `icmp`/
`ashr`/`lshr` are what apply a signed or unsigned *interpretation*), and
`Llvm.const_of_int64 ty v signed` already takes exactly this kind of raw
64-bit container. `Int64.t` -1 and u64's `0xFFFFFFFFFFFFFFFF` are the
same bit pattern; which one a piece of code means is a question the
*type* answers, not the *value*. This mirrors how the whole codebase
already treats integers (see `is_unsigned`, `coerce`'s sext/zext choice).

**Deliberately not a step toward i128/u128 today, but not a dead end
either**: no primitive type beyond u64/i64/usize exists in takibi yet, so
actually supporting one is out of scope here (per this project's usual
practice of not building ahead of a concrete need -- see the `TRefinedInt`
i32-range note above for the same reasoning applied to a different
subsystem). What this change *does* do is remove the one hard blocker
that would have made ANY future widening impossible: OCaml's native `int`
literally cannot hold a full 64-bit pattern, so no width wider than
"64 bits minus a bit for the tag" could ever have been represented at
all, no matter how the rest of the compiler was designed. `Int64.t` itself
tops out at 64 bits too, so it does not directly hold a future i128
value -- a real i128 add would still need a further representation change
(e.g. a pair of `Int64.t`, or a bignum library like `zarith`). What
*does* carry forward is the pattern this change establishes: a literal's
storage type is independent of, and wider than, what any *particular*
consumer needs, and consumers that only ever need a small, realistic
value narrow explicitly (see `int_of_intlit` below) with a defined,
sound fallback on overflow -- rather than every one of the ~30 call
sites across the compiler assuming the literal already fits whatever
width it happens to need.

**Lexer (`lib/lexer.mll`)**: hex and decimal digits are now accumulated
by hand in `Int64.t` space (`int64_of_digits`), not via `int_of_string`/
`Int64.of_string`. This is not just a width change -- `Int64.of_string`
range-checks a plain decimal digit string against Int64's *signed* range
(rejecting a perfectly valid u64 value like 2^63) and raises `Failure`
past 16 hex digits. Neither restriction matches what an integer literal
here means (a raw bit pattern, not a signed magnitude), so hand-rolled
digit-by-digit accumulation (`Int64.add (Int64.mul acc base) digit`) is
used for both bases instead, wrapping silently past 64 bits exactly like
hex already did -- an astronomically unrealistic edge case (no type in
this language is wider than 64 bits, so no literal ever legitimately
needs more), accepted as wraparound rather than turned into a new
diagnostic category no other part of the compiler has.

**The narrowing discipline (`Ast.int_of_intlit`)**: most of the compiler
(range propagation, narrowing, array sizes, alignment, enum
discriminants, `Const_env`) only ever needs to reason about small,
realistic values and was written entirely in native `int`, long before
this change. Rather than rewrite that machinery in `Int64.t` arithmetic
(high risk, no benefit -- these subsystems are already capped to small
values by their own domain, e.g. `TypeRefined` is i32-only regardless),
every one of those call sites now narrows via one shared helper:
```ocaml
let int_of_intlit (k : Int64.t) : int option =
  let i = Int64.to_int k in
  if Int64.of_int i = k then Some i else None
```
Round-tripping through `Int64.of_int (Int64.to_int k)` and comparing
catches exactly the case a plain `Int64.to_int` would get wrong: OCaml's
`int` is 63 bits, one bit short of `Int64.t`, so a genuinely-wide value
can silently wrap into the wrong native int with no warning -- the same
class of silent-miscompilation risk the `{lo..<hi}` i32-range check above
and the `Mod`/`lo>=0` sync rule both already guard against. What a caller
does with `None` splits into two disciplines, matching whether the call
site already had a defined "can't reason about this" fallback:
- **Analysis/proof call sites** (range propagation's `TRefinedInt`
  formulas, if-narrowing, the same-base subslice rule, `var_plus_const`,
  `slice_len_mins`) already had a conservative fallback for "this operand
  isn't a usable compile-time constant" -- `None` is routed into that
  exact same fallback (unrefined `TI32`, "don't narrow", "not this
  shape"), via a small `intlit_opt`/`IntLit k -> Ast.int_of_intlit k`
  wrapper duplicated (sync rule) in `type_inf.ml` and `llvm_gen.ml`.
- **Grammar positions with no such fallback** (`array_size`, `align(N)`,
  a struct's `align(N)`, an enum's explicit discriminant) use a second
  helper, `parser.mly`'s `narrow_int64 pos what n`, which raises a
  `Types.TypeError` instead -- there is no sensible "conservative" array
  size or alignment, so overflow here is a hard compile error, not a
  silent fallback.
- **Constant-index bounds checks** (`Index`/`AssignIndex` in
  `type_inf.ml`) are a hybrid: a literal too large to narrow is not
  merely "unprovable", it is certainly out of bounds for any real array
  (arrays are never anywhere near 2^63 elements), so it is reported as an
  out-of-bounds error directly rather than silently passing through.
- **`Const_env`** (`define_if_literal`/`bound_value`, backing array-size
  names and for-loop bounds) treats a too-large literal as if it were
  never a recognized bare-literal constant at all -- simply not recorded
  -- so each consumer's own pre-existing "not found" handling (an
  `array_size` name-lookup error, or `bound_value`'s conservative
  unrefined case) applies unchanged.

**Codegen (`lib/llvm_gen.ml`)**: `Llvm.const_int` takes a plain `int`, so
every direct construction site now uses `Llvm.const_of_int64` instead.
Two places needed more than a mechanical swap:
- **`eval_const_int`** (the global-initializer constant-folding
  evaluator added for `as`-cast/cross-global-reference folding -- see
  "Global Constant Folding" below) now threads `Int64.t` all the way
  through instead of `int`, including `mask_to_bits`'s truncating-cast
  masks (`Int64.logand`/`Int64.shift_left`, not native bit operators) --
  otherwise the SAME representational gap this whole feature closes
  would have just reappeared one level down, inside global constant
  folding specifically.
- **`gen_expr`'s `IntLit` case** (ordinary expression codegen, function
  bodies -- distinct from `eval_const`, which only handles global
  initializers) picks i32 vs i64 representation per-literal: i32 when the
  value is `0 <= i <= 0x7FFFFFFF`, i64 otherwise. This is **deliberately
  narrower than the full signed i32 range**, not merely "whatever fits in
  32 bits" -- `gen_expr` has no visibility into whether the surrounding
  context will eventually sign- or zero-extend this value (that decision
  lives in `coerce`, driven by the destination type's signedness, at some
  later, unrelated call site), and an i32 representation can only be
  safely widened *either* way -- reconstructing the identical 64-bit
  value regardless of which extension is later applied -- when bit 31 is
  clear. Once bit 31 is set, sign- and zero-extension diverge:
  `0xFFFFFFFFFFFFFFFF` (`Int64.t` -1) naively "fits" the full signed i32
  range too, but truncating it to i32 -1 and then *zero*-extending (as
  `coerce`'s `TypeU64` case does) gives the wrong
  `0x00000000FFFFFFFF`, not the correct all-ones value -- a real bug this
  project's own test suite caught (see `examples/int64`'s "argument" case
  below) before this narrower threshold was chosen. Routing anything with
  bit 31 set through the i64-native path instead sidesteps the ambiguity
  entirely: `i64 -> narrower` is always a sign-agnostic `build_trunc` (see
  `coerce`'s and `to_i32`'s narrowing branches), so a wide value
  reconstructs correctly regardless of which narrower type it ends up
  used as, with no need to guess a destination's signedness upfront.
- **`to_i32`** (used only for index/bound expressions -- `Index`,
  `SliceOf`, `min`/`max`) gained a `build_trunc` branch for an i64 source,
  alongside its existing widen-only (`build_zext`) branches. Under a
  normally type-checked program this is unreachable (`type_inf.ml`'s
  `Index`/`SliceOf` cases unify their operand with plain `TI32`, so the
  inferred type already guarantees i32), *except* for a bare wide `IntLit`
  used directly as an index/bound: it type-checks as `TI32` via ordinary
  context-driven unification (`IntLit _ -> fresh ()` is fully polymorphic
  and carries no magnitude check), but codegens to an i64 llvalue once it
  doesn't fit i32. A truncate is the well-defined, if unusual, outcome for
  that case (e.g. a nonsensical huge literal used as an array index)
  rather than an invalid "narrow via build_zext" call or a crash.

**Files**: `lib/ast.ml` (`IntLit of Int64.t`, `int_of_intlit`,
`var_plus_const`/`slice_len_mins` narrowing), `lib/lexer.mll`
(`int64_of_digits`, `INT` token, char-literal productions),
`lib/parser.mly` (`%token <Int64.t> INT`, `narrow_int64`, every
`align`/struct-`align`/enum-discriminant/`array_size`/`{lo..<hi}` site),
`lib/const_env.ml` (`define_if_literal`/`bound_value`), `lib/type_inf.ml`
(`intlit_opt`, all range-propagation and bounds-check sites),
`lib/llvm_gen.ml` (`intlit_opt`, `gen_expr`'s `IntLit` case, `to_i32`,
`eval_const_int`/`eval_const`, all range-propagation mirror sites),
`test/test_takibi.ml` (39 existing `IntLit n` patterns gained the `L`
suffix; new tests for full-width hex/decimal parsing, the local-u64 and
wide-function-argument codegen regressions, and array-size/`align(N)`
overflow producing a clean `TypeError`), `examples/int64/` (new QEMU
example exercising all three runtime-codegen-relevant forms -- a global,
a local variable, and a bare wide literal passed as a function argument
-- registered in `run_qemutest.sh`'s ordinary and no-trap example lists
and in the Makefile's `EXAMPLES`/`STM32_EXAMPLES`).

### Follow-up: `gen_expr`'s `?expected_ty` Hint (Genuinely Polymorphic
### Literals, Not Just Correct-by-Constant-Folding)

The 64-bit fix above left one honestly-documented gap: `gen_expr`'s
`IntLit` case, with no hint available, still had to *guess* i32 vs i64
from the literal's own magnitude, because it had no visibility into what
type the surrounding context actually wanted. For a literal already
sitting in an unambiguously-typed position (`let v: u64 = LITERAL;`, a
`return`, a function call argument, an assignment, a struct/array
literal field), this guess-then-`coerce` two-step happened to produce
the right final *value* -- but only because `coerce`'s `build_zext`/
`build_trunc`, given a compile-time-constant operand, get silently
constant-folded by LLVM into a single direct constant, erasing the i32
intermediate from the emitted IR. That erasure is an LLVM implementation
detail, not something this compiler's own architecture guaranteed --
confirmed by dumping unoptimized IR for `let w: u64 = LITERAL + n;`
(`n: i32`), where the i32 stage is NOT erased (`add i32 <lit>, %n` then a
real `zext i32 %addtmp to i64` instruction), because a runtime value is
involved and there is nothing left to fold.

**The fix**: `gen_expr` gained an optional `?expected_ty : Ast.type_expr`
parameter, defaulting to `None` (so every existing recursive call within
`gen_expr` itself, and any call site that has no natural type hint to
offer, is unaffected byte-for-byte). `IntLit`'s case checks it first: if
`expected_ty` names a concrete scalar type (`TypeI8`..`TypeUsize`,
`TypeBool`, or `TypeIo` wrapping one -- `io` is a storage qualifier, so
it is stripped before the check, matching how `io` is handled everywhere
else in this file), the literal is constructed DIRECTLY at that width via
`const_of_int64`, with the old magnitude-based i32-or-i64 guess now only
a fallback for when no hint is available or the destination is something
`?expected_ty` deliberately doesn't special-case (`TypeRefined`,
`TypeSlice`, a pointer -- the existing guess already serves those
correctly).

**Threaded from every call site that already knows a concrete expected
type**, each a small, targeted change (no broad "expected-type inference"
system added -- `Types.program_types` still only carries types by name,
not per-expression-node, so this is deliberately a *codegen-side*
threading of already-available name-keyed type information, not a new
type-inference capability):
- `Let` (both the immutable case, and the mutable case via
  `init_memory` -- which also covers nested struct/array literal fields,
  since `init_memory` recurses into those with each field's own type)
- `Return` (hinted by the function's own return type, `ret_ast`)
- `Assign` (a second, cheap lookup of the assignment target's stored type
  happens *before* evaluating the RHS, so the existing store-side match
  logic afterward is unchanged)
- `AssignField` (hinted by `field_info`'s already-resolved field type)
- `AssignDeref` (the pointer is evaluated first as before; its pointee
  type, once known, hints the value expression evaluated second)
- `AssignIndex` (a lightweight peek at the container's element type,
  mirroring the fuller match used later for the actual store, happens
  before the RHS is evaluated)
- Function call arguments, both direct (`Call` resolving to a known
  `fenv` function) and indirect (a function-pointer-typed variable) --
  each argument is hinted by its corresponding parameter's declared type

**Deliberately NOT threaded**: `BinOp` operands. `LITERAL + n` (`n: i32`)
genuinely should compute the literal as i32 -- that IS what unification
already required of the whole expression (both operands unify to the
same type) -- so there is no bug to fix there; only the FINAL result,
if used somewhere needing a wider type, needs a real runtime extension,
which already happens correctly. Conflating "the literal's own natural
type in this expression" with "the type some later cast might want" would
be a mistake, not a generalization.

**Verification**: `test/test_takibi.ml` gained
`assert_direct_i64_literal`, which inspects the actual generated
function body text (`Llvm.string_of_llvalue`) for the ABSENCE of any
`zext`/`trunc` instruction and the PRESENCE of the literal's exact bit
pattern -- a stronger check than "compiles and returns the right value",
since that weaker check cannot distinguish "genuinely direct" from
"correct only because LLVM folded it". Confirmed directly via manual
unoptimized-IR dumps (a throwaway scratch executable linking this
project's own `Llvm_gen`/`Parser`/`Type_inf` modules and calling
`Llvm.dump_module`) before writing the automated tests, covering all of:
global, immutable local, mutable local, function argument (direct and
indirect call), assignment, struct field, array index, and pointer
deref -- all confirmed to emit the literal directly as `i64 -1`
(`0xFFFFFFFFFFFFFFFF`'s bit pattern) with no `zext`/`trunc` anywhere.
`examples/int64/int64.tkb` gained a `local_full_mask()` function
exercising this at runtime under QEMU too (a value that, unlike
`local_big_value()`'s 5\_000\_000\_000, only reaches the correct answer
because of this fix -- 5 billion happened to already round-trip through
the old guess-based path correctly, since it doesn't have bit 31 set;
`0xFFFFFFFFFFFFFFFF` is the case that actually needed a hint).

### Refinement Numerical Type: {lo..<hi} Generalized to Carry Any Base Integer Type

Historically `TRefinedInt`/`TypeRefined` was ALWAYS represented as i32 at
the LLVM level, no matter which integer type a `{lo..<hi}` value was used
with (see the older note on this below, now superseded) -- this meant
`is_unsigned (TypeRefined _)` always returned `false` unconditionally,
which was a real bug: a refined value derived from a u64 (e.g. via `&`,
`min`/`max`, if-narrowing) silently lost its unsignedness the moment it
became refined, so a subsequent i32/i64 BinOp width-sync could pick
`sext` instead of `zext` for it. Fixed by generalizing `TRefinedInt`/
`TypeRefined` to a 3-argument form that carries its own base type:
`TRefinedInt of int * int * ty` (`types.ml`) / `TypeRefined of int * int *
type_expr` (`ast.ml`) -- `{lo..<hi}` is no longer implicitly i32, it is
"a value of type `base` known to be in `[lo, hi)`", where `base` is
(by convention, not enforced by the type system itself) one of
i8/i16/i32/i64/u8/u16/u32/u64/usize.

**Files changed** (the same "sync rule" duplication pattern as every
other feature in this file -- type_inf.ml and llvm_gen.ml were changed in
lockstep, verified by re-running the full test suite after each pass):
1. `lib/types.ml` -- `TRefinedInt of int * int * ty`; `unify`'s
   `TRefinedInt, TRefinedInt` case now also unifies the two bases (not
   just checking bounds equality); every subtyping-into-concrete-type rule
   (`TRefinedInt _, TI32/TI64/TU8/.../TUsize`) keeps its existing
   bounds-only condition, now with `_` for the ignored base field; the
   generalized anti-subtyping guard (`t1, TRefinedInt (lo, hi, base) when
   t1 = repr base -> raise (Unify_error "cannot pass unproven ...")`) now
   fires for ANY base, not just i32.
2. `lib/ast.ml` -- `TypeRefined of int * int * type_expr` (surface AST
   mirror).
3. `lib/parser.mly` -- the literal `{lo..<hi}` type syntax always
   constructs `TypeRefined (lo, hi, TypeI32)` -- the SURFACE SYNTAX still
   defaults to i32 (there is no source-level way to write "{lo..<hi} of
   u64" directly); non-i32 bases arise only from the type system's OWN
   range-propagation machinery (Add/Sub/Mul/Band/Mod/min/max/narrowing),
   never from what a programmer types. This was a deliberate scope
   decision, not an oversight -- see "Deliberately NOT addressed" below.
4. `lib/type_inf.ml` -- every TRefinedInt-producing site threads/unifies
   `base` instead of hardcoding TI32: `canon_ty` (widens to the value's
   OWN base, not always TI32 -- this single change is what fixed several
   previously-latent bugs in Mul/Bor/Bxor/Shr/Shl's fallback cases, see
   below), BinOp Add/Sub/Mul/Band/Mod, `narrow_from_cond`/`collect_bounds`
   (generalized from matching only `TI32` locals to matching any of
   i8/i16/i32/i64/u8/u16/u32/u64/usize), the `Let` "proofs survive weaker
   annotations" `bind_ty` check, min/max (see its own paragraph below).
   `For` loop counters deliberately stay `base = TI32` always (loop
   counters are array-index-shaped; see "Deliberately NOT addressed").
5. `lib/llvm_gen.ml` -- the codegen mirror of all of the above, plus the
   actual representation-width change: `ltype_of_ast (TypeRefined (_, _,
   base)) = ltype_of_ast base` (was hardcoded `i32_type context`), so a
   `{lo..<hi}` value with a u64/i64 base now genuinely occupies an LLVM
   `i64`, not a truncated-then-implicitly-widened i32. `is_unsigned`
   (**the fix for the originally-reported bug**) now recurses:
   `TypeRefined (_, _, base) -> is_unsigned base`. `coerce`, `ditype_of_ast`,
   `int_bits_of_ast`, and every Index/SliceOf/narrowing site were updated
   the same way.
6. `test/test_takibi.ml` -- all existing `TypeRefined`/`TRefinedInt`
   pattern matches and constructions updated to the 3-arg form (the
   literal-syntax tests all expect base = `TypeI32`, matching point 3
   above); new regression tests added for the two bugs found during this
   work (see below).

**Two latent bugs fixed as side effects of the systematic pass** (not the
originally-reported bug, but found while touching every call site):
- `canon_ty`'s old fallback (`TRefinedInt _ -> TI32` unconditionally)
  meant Mul/Bor/Bxor/Shr/Shl's "operation doesn't preserve the range"
  fallback cases returned a STALE, no-longer-valid refined range in some
  paths instead of correctly widening to the value's actual base type --
  a real, if narrow, pre-existing soundness gap. `canon_ty` now widens to
  the value's OWN base (`TRefinedInt (_, _, base) -> base`), which fixed
  this everywhere `canon_ty` is already called, with no new call sites
  needed.
- `llvm_gen.ml`'s min/max codegen previously called `to_i32` unconditionally
  on both operands (silently truncating a genuine u64 argument) and always
  used signed comparison (`Icmp.Slt/Sgt`, wrong for e.g. a u32 value with
  the top bit set). Both fixed to mirror BinOp's existing i32/i64
  width-sync-with-`is_unsigned`-for-extension-direction pattern, and to
  pick `Icmp.Ult/Ugt` vs `Icmp.Slt/Sgt` based on `is_unsigned`.

**Bug found and fixed DURING verification (a real regression caught by
the existing test suite, not a new one)**: the `Let` binding's "proofs
survive weaker annotations" check and the generalized anti-subtyping
guard both originally compared the extracted `base` field directly with
OCaml's structural `=` (`t_ann = base`, `t1 = base`). This is unsound
because `repr` (the HM union-find dereference function) only resolves
the TOP-LEVEL type passed to it -- it does NOT recursively resolve fields
NESTED inside an already-matched constructor. If `base` came from a
still-unresolved unification variable at the time the `TRefinedInt` was
constructed (e.g. `0x0f & v` where `0x0f`'s own type variable only gets
unified with `v`'s type LATER, inside the same expression), `base` could
still be a raw `TVar (ref (Link TI32))` rather than the plain `TI32`
constant, so `t_ann = base` compared `TI32` against a boxed TVar wrapper
and (structurally) never matched, silently discarding an already-proven
range. Caught by the existing "mask propagation is symmetric ... (v &
0x0f) * 4 carries {0..<16} to {0..<61}" test (which started failing with
an unexpected trap site after the generalization). Fixed by comparing
`repr base` instead of the raw `base` in both places. **Sync note for any
future code touching an extracted `base` field**: always `repr` it
before comparing/pattern-matching its concrete shape; the field is not
guaranteed pre-resolved just because the outer `TRefinedInt`/`TypeRefined`
value itself was matched via an already-`repr`'d discriminant.

**Second bug found and fixed DURING post-verification manual testing (not
caught by the existing suite -- none of it exercised min/max with a
non-i32 base before this work)**: min/max's "unknown bound" sentinel
range (`sentinel_lo = -1_000_000_000`, `sentinel_hi = 1_000_000_000`,
used when neither argument's range is statically known) is only a legal
value of the RESULT's base type when that base accepts negative numbers.
Before this generalization, min/max's result was always unified against
`TI32` (whose `TRefinedInt _, TI32 -> ()` subtyping rule has no `lo >= 0`
restriction), so the negative sentinel was always fine. Once min/max
started unifying its two arguments against EACH OTHER (letting e.g. two
`u64` arguments through), the SAME negative sentinel became illegal
against any unsigned destination (`TU8/TU16/TU32/TU64/TUsize`'s subtyping
rules all require `lo >= 0`), so `min(a, b)` with two unconstrained `u64`
parameters raised `cannot unify {-1000000000..<1000000000} with u64`, an
outright regression for a previously-nonexistent capability. Fixed in
both files (sync rule) by making `sentinel_lo` conditional:
`is_unsigned_ty base` (type_inf.ml) / `is_unsigned at` (llvm_gen.ml)
selects `0` instead of `-1_000_000_000`; `sentinel_hi` was left at
`1_000_000_000` unconditionally at the time, believed "imprecise for a
narrow base like u8, but conservative/safe, not unsound" -- **this belief
was wrong, corrected below.** The `base`/`at` value consulted here must
ALSO be resolved through `repr` before this check (same class of issue as
the `Let`/anti-subtyping fix above, applied proactively here since
`is_unsigned_ty` PATTERN MATCHES the base's concrete shape rather than
comparing it, and an unresolved TVar would silently fall through to "not
unsigned" regardless of what it actually resolves to). Regression tests:
`test/test_takibi.ml`'s `refnum_min_u64`/`refnum_max_u64` (unconstrained
u64 arguments, must not raise), `refnum_min_clamp_u64` (min against a
literal still proves an array index against a smaller buffer),
`refnum_narrow_u64` (if-narrowing a u64 variable proves an index with
zero trap sites).

**Follow-up fix (same session, prompted by the user asking specifically
whether the sentinel should be "clamped to the base's actual width"):
the "conservative/safe" claim above was wrong.** `sentinel_hi =
1_000_000_000` is only harmless for bases whose subtyping rule has no
upper-bound restriction at all (`TI32`/`TI64`, unconditional; `TU32`/
`TU64`/`TUsize`, `lo >= 0` only) -- but `TU8` requires `hi <= 256`, `TU16`
requires `hi <= 65536`, and `TI8`/`TI16` require `hi <= 128`/`32768`
(with a matching `lo` floor). A sentinel of 1 billion FAILS all four of
those checks outright, so a fully-unconstrained `min`/`max` call on two
u8/u16/i8/i16-typed arguments (e.g. `min(a: u8, b: u8)` with neither
argument statically bounded) raised a spurious `cannot unify` error --
the exact same class of regression as the u64 case above, just not
triggered by anything in the existing test suite (nothing exercised
min/max on a narrow base with no known bound at all) or by the earlier
manual verification (which only tried u64). Fixed by replacing the
single hardcoded sentinel pair with `min_max_sentinel base` (added right
after `is_unsigned_ty`/`is_unsigned`, sync rule), which returns the
correct per-base placeholder: `(-128, 128)` for i8, `(-32768, 32768)` for
i16, `(0, 256)` for u8, `(0, 65536)` for u16, `(0, 1_000_000_000)` for any
other unsigned base, `(-1_000_000_000, 1_000_000_000)` otherwise (i32/
i64) -- i.e. each narrow type's placeholder is its own true representable
range, while the wide types keep the original arbitrary-but-sufficient
constant (their subtyping rules don't care how large `hi` is anyway, so
there's no benefit to computing their true 2^31/2^63-ish bounds, and doing
so for i64/u64 would risk overflowing OCaml's 63-bit native `int`).
**`llvm_gen.ml`'s codegen mirror needed one additional correction found
while wiring this up**: `at` (the min/max call's own operand type) can
itself still be a `TypeRefined` wrapping the true base (e.g. one operand
was already narrowed by an outer `if` before reaching this call) --
`min_max_sentinel` pattern-matches concrete base constructors directly, so
calling it on a raw, un-`canon_ty`'d `at` would miss the `TypeU8`/`TypeI8`
/etc. cases, silently fall through to the wide generic sentinel, and
produce a bound that then fails `ret_ty`'s OWN subtyping check one line
later -- the same "extract the base without canonicalizing/repr'ing it
first" mistake as the two bugs above, just one call deeper. Fixed by
computing `let base = canon_ty at in` once and reusing that same `base`
for both the sentinel lookup and `ret_ty`'s construction (previously
`ret_ty` computed `canon_ty at` separately, a second call that coincidentally
gave the same right answer for `ret_ty` itself but not for the sentinel
if evaluated on the raw value). Regression test:
`test/test_takibi.ml`'s `refnum_min_u8_unconstrained` (u8/u16/i8/i16, all
four fully-unconstrained, must not raise).

**Deliberately NOT addressed by this generalization**:
- The surface `{lo..<hi}` type syntax still always means "base i32" --
  there is no source-level way to write a refined u64/i64 literally.
  Non-i32 bases only ever arise from the compiler's OWN range-propagation
  machinery. Adding source syntax for this (e.g. `{lo..<hi}: u64` or
  similar) is a natural follow-up but has no concrete need yet.
- `For` loop counters are hardcoded to `base = TI32` regardless of the
  loop bound's own type -- loop counters are conventionally used as array
  indices (i32-shaped), and generalizing this specific site had no
  motivating example.
- This work does NOT change anything about how bare integer LITERALS are
  typed in a `BinOp` (`LITERAL + n` still directly computes as `n`'s own
  type, which was already correct -- see the "Deliberately NOT threaded"
  paragraph in the Polymorphic Literal section above). The user explicitly
  separated these two topics and asked for this generalization FIRST,
  planning to revisit BinOp/literal handling as a distinct discussion
  afterward.

**Full verification**: `make check` (langcheck, 363 unit tests -- up from
360, +3 for this work's own regressions -- stm32build, and all 125
qemutest cases including every `--forbid-trap`/no-trap check) passes with
zero regressions after both bugs above were fixed.

### Explicit-Base {lo..<hi as base} Surface Syntax

Motivated by a concrete need the "Deliberately NOT addressed" list above
predicted but didn't yet have an example for: rewriting the protocol
examples (`ip_parse`, `tcp_parse`, `icmp_echo`, `tcp_echo`, `http_server`)
to use natural wire-width types (`u8` for IP version/IHL/TTL/protocol,
TCP flags/data-offset; `u16` for ports/total-length; `u32` for TCP
sequence/ack numbers) instead of i32 everywhere. Several of these files
pass an `ihl: {20..<21}` value across a function boundary (e.g.
`build_echo_reply`, `build_syn_ack`, `parse_tcp`) to prove the same-base
subslice rule `ip[ihl..<ihl+tcp_len]`. Because the surface `{lo..<hi}`
syntax could only ever spell base = i32, passing a narrower-based local
into such a parameter failed to unify at all (`TRefinedInt`'s
subtyping/unification requires bounds AND base to match exactly for a
function argument -- there's no "narrower fits into wider" rule the way
slice minimum-length subtyping has), which transitively forced every
variable entangled in that one proof chain to stay i32-based even when
every one of them is naturally narrower on the wire. Lifting this
required letting a programmer spell a non-i32 base directly in source,
not just receive one indirectly from the compiler's own range-propagation
machinery (Add/Sub/Mul/Band/Mod/min/max/narrowing).

**Syntax**: `{lo..<hi as base}`, where `base` is one of i8/i16/i32/i64/
u8/u16/u32/u64/usize (the same set "by convention" already documented as
`TRefinedInt`'s allowed bases). Reuses the existing `AS` token rather than
inventing new grammar -- `{20..<21 as u8}` reads as "a value in this
range, as this base type", and there is no ambiguity with the ordinary
`expr AS type_expr` cast (this form only ever appears between `hi` and
`RBRACE`, strictly inside the braces). The bare `{lo..<hi}` form (no `as`)
is unchanged and still defaults to i32.

**Per-base range validation, generalizing the existing i32-only check**:
just like a bare `{lo..<hi}` bound outside i32's range used to silently
wrap at codegen time before that check was added, `{lo..<hi as u8}` with
`hi > 256` would silently wrap via `const_int i8_type <hi>` with no
warning. `lib/parser.mly`'s new production validates `lo`/`hi` against
each base's own representable range (`base_bound_range`): i8 needs
`lo >= -128 && hi <= 128`, i16 needs `lo >= -32768 && hi <= 32768`, i32
matches the existing bare-form check, u8 needs `lo >= 0 && hi <= 256`, u16
needs `lo >= 0 && hi <= 65536`, u32 needs `lo >= 0 && hi <= 4294967296`.
i64/u64 impose no upper-bound check at all, matching `types.ml`'s own
`TRefinedInt` subtyping rules for those bases (which likewise never
restrict `hi`) -- and also sidestepping a real representational limit:
`i64`'s true upper bound (2^63) does not fit in an `Int64.t` `hi` value
either. `usize` is checked the same as `u32` (`hi <= 4294967296`) even
though it's i64-wide on AArch64/RISC-V64, because it's only 32-bit on
Cortex-M and the parser doesn't know the target yet at parse time --
conservatively assuming the narrowest supported width is the safe
direction (rejects some values that would be fine on a 64-bit target
rather than silently accepting values that would wrap on a 32-bit one).

**A real, previously-latent bug found immediately while testing this**:
the first program exercised through this new syntax (`let x: u8 = a &
mask; let y: u8 = x * 4;` then passing `y` into a `{20..<21 as u8}`
parameter) crashed `gen_func`'s own `Llvm_analysis.verify_function` with
`mul i8 %x, i32 4` -- an LLVM type mismatch. Root cause: `widen_load`
(aliased `to_arith_width`, used by every `Var`/`Index`/`FieldGet`/`Deref`
codegen case per the project's "narrow-typed gen_expr results must be
widened in-flight" invariant) pattern-matches `TypeI8|TypeI16|TypeI32` /
`TypeU8|TypeU16|TypeU32` explicitly but had no case for `TypeRefined` at
all, falling through to `| _ -> v` (return unchanged). **This was
harmless before the "Refinement Numerical Type" generalization above**,
because every `TypeRefined` value was i32-shaped in memory regardless of
what it represented, so returning it unwidened was a no-op (it was
already the right width). Once a `TypeRefined` value can genuinely be
i8/i16-shaped (e.g. `base = TypeU8`, reachable ever since that
generalization landed, just never exercised end-to-end until this new
syntax made it easy to write), the SAME fallthrough silently returned a
still-narrow value to a caller (e.g. `BinOp`'s Mul case) that assumes
arithmetic-width (i32/i64) input. This is the same class of oversight as
the `is_unsigned`/`canon_ty` fixes documented above, just in a THIRD
function that also needed the "recurse into `TypeRefined`'s base" case
and was missed in the original pass. Fixed by making `widen_load`
`rec` and adding `TypeRefined (_, _, base) -> widen_load base v` as its
first case (`lib/llvm_gen.ml`). Regression test:
`test/test_takibi.ml`'s `refnum_widen_mul`/`refnum_widen_add`/
`refnum_widen_call_site` (Imm bindings with a narrow refined base used in
further arithmetic and passed across a `{lo..<hi as base}` parameter
boundary; `expect_codegen_ok` catches a regression here because
`gen_func`'s IR verifier -- not a hand-written assertion -- is what
actually fails).

**Files**: `lib/parser.mly` (`int_base_type_expr`, `base_bound_range`,
`check_refined_base_range`, the new `{lo..<hi as base}` production),
`lib/llvm_gen.ml` (`widen_load`'s `TypeRefined` case), `test/
test_takibi.ml` (parser tests for all 9 bases + the out-of-range/
no-upper-bound-for-64-bit cases, codegen regression tests for the
`widen_load` bug). This unblocks, but does not itself perform, the
protocol-examples rewrite described above -- that is tracked separately.

### The Protocol Examples Rewrite: i32-Forced Refinement Locals -> Natural
### Wire-Width Types

Rewrote `ip_parse.tkb`, `tcp_parse.tkb`, `icmp_echo.tkb`, `tcp_echo.tkb`,
and `http_server.tkb` so that fields naturally a single byte (IP version/
IHL/TTL/protocol, TCP flags/data-offset), a 16-bit half-word (ports,
total-length, window), or a 32-bit word (TCP sequence/ack numbers) use
`u8`/`u16`/`u32` instead of the i32 that was the only option before the
Refinement Numerical Type generalization and the explicit-base syntax
above. `arp_reply.tkb` needed no change (every field is compared inline,
no i32-forced refinement locals exist there); `refined.tkb`/`narrow.tkb`
(deliberately illustrate narrowing an i32-of-unknown-range index/MMIO
value -- i32 is the CORRECT type there) and `crc8.tkb`/`foreach.tkb`/
`int64.tkb` (checksum accumulators needing i32 headroom, or generic i32
input by design) were likewise left alone.

**A real, previously-latent bug found immediately while testing the
first rewritten file**: `pkt[0..<ihl]` (`ihl: u8`, `ip_parse.tkb`'s
existing `min(...)`-clamped IHL) raised `cannot unify u8 with i32`.
Root cause: `SliceOf`'s bound check in `lib/type_inf.ml` did `unify_at
lo_e.loc (canon_ty lo_t) TI32` -- `canon_ty` WIDENS a refined bound to
its bare base FIRST (e.g. `TRefinedInt(0,21,TU8) -> TU8`), and a bare
`TU8` has no unification rule against `TI32` at all. `Index`'s parallel
check (`unify_at idx.loc it TI32`, no `canon_ty`) never had this bug,
because unifying the RAW `TRefinedInt` directly relies on `types.ml`'s
existing base-agnostic subtyping rule (`TRefinedInt _, TI32 -> ()`,
unconditional regardless of the refined value's own base) -- exactly what
a u8/u16/etc.-based bound needs. This was invisible before this session's
work only because every refined bound was i32-based anyway (`canon_ty`'d
i32 unifies with i32 trivially, masking that `canon_ty` was doing nothing
useful there even then). Fixed by removing the `canon_ty` call, matching
Index's pattern exactly: `unify_at lo_e.loc lo_t TI32` /
`unify_at hi_e.loc hi_t TI32`. `llvm_gen.ml`'s codegen mirror
(`gen_bound`) needed no change -- it calls `to_i32` directly on the
LLVALUE (not the AST type), which already handles any integer LLVM width
correctly regardless of the AST type tag. Regression test:
`test/test_takibi.ml`'s `refnum_slice_bound_u8`.

**The `ihl`-entanglement finding, and why several fields stay i32 after
all**: the explicit-base syntax unblocks `ihl: {20..<21 as base}` as a
parameter, but `tcp_parse.tkb`/`icmp_echo.tkb`/`tcp_echo.tkb`/
`http_server.tkb` all compare `ihl`/`total_len`/`tcp_len` against
quantities ultimately derived from `net_poll_rx()`'s return value (`len`),
which is deliberately-unconstrained `i32` (external, device-reported,
per this project's `i32 = unknown range` convention). Casting a value to
a plain (non-refined-syntax) target type ALWAYS discards any refined
range the source had (`type_inf.ml`'s `Cast` case: `| _ -> tgt`,
unconditional) -- so bridging `total_len`/`ihl` into a narrower base at
the point they're compared against `ip_len_in_frame = len - 14` would
silently break the narrowing chain the whole checksum-span proof depends
on. Consequences, worked out per file:
- `ip_parse.tkb`: no entanglement at all (its `ihl` is a purely local
  `min(...)`-clamped value, never compared against anything `len`
  -derived) -- `version`/`ihl`/`ttl`/`protocol` -> `u8`, `total_len` ->
  `u16`, no explicit-base syntax needed.
- `tcp_parse.tkb`: `ihl` IS a `{lo..<hi}` parameter, but `ip_total_len`
  there comes directly from `read_u16be` (inherently 16-bit, never
  compared against a `len`-derived value) -- `ihl: {20..<21 as u16}`,
  `ip_total_len`/`tcp_len` follow at `u16`; `flags`/`data_offset` (display
  -only, never touch the `ihl` chain) -> `u8`; ports -> `u16`; seq/ack ->
  `u32` (display-only via `uart_println_hex`).
- `icmp_echo.tkb`/`tcp_echo.tkb`/`http_server.tkb`: `ihl`/`total_len`/
  `ip_len_in_frame`/`tcp_len`/`tcp_hdr_len`/`data_len`/`data_off` ALL stay
  `i32` (the `len`-entanglement above). Only `version` (standalone),
  `doff`/`flags` (TCP's own byte-scale fields, never directly combined
  with the `ihl` chain -- `tcp_hdr_len = doff * 4` upcasts `doff` back to
  `i32`), ports, and seq/ack/`conn_snd_nxt`/`conn_rcv_nxt` (equality/
  increment only, confirmed no `<`/`>` ordering comparisons exist, so the
  CLAUDE.md caveat about `read_u32be`'s signed bit pattern for large seq
  numbers no longer applies to these fields at all) narrow.
- Wire-VALUE constants compared against a narrowed field follow it
  (`TCP_FLAG_*`/`PROTO_TCP` -> `u8`; `TCP_ECHO_PORT`/`HTTP_PORT` -> `u16`;
  `OUR_ISN` -> `u32`) -- unlike the pure OFFSET constants (`IP_TTL`,
  `TCP_SEQ`, `ARP_SHA`, ...), which stay `i32` as array indices, matching
  the codebase's existing for-loop-counter convention.
- A narrowed counter combined with an i32-entangled value needs one
  explicit cast at the point of combination, not a redeclaration:
  `conn_rcv_nxt = conn_rcv_nxt + (data_len as u32);` (`conn_rcv_nxt: u32`,
  `data_len: i32`, entangled). Safe because `conn_rcv_nxt`/`conn_snd_nxt`
  are never used as a slice bound or index anywhere -- no proof depends
  on their refined-ness (they have none to begin with, being plain
  running counters), so discarding it via the cast costs nothing.
- `netutil.tkb`/`inet_checksum.tkb`'s shared function signatures
  (`read_u16be`/`read_u32be`/`write_u16be`/`write_u32be`, `checksum_add`/
  `checksum_fold`) were NOT changed -- narrowing those ripples into every
  caller across 5 files for uncertain benefit; an explicit `as u16`/
  `as u32` cast at the call site gets the same local clarity without
  that ripple. `checksum_add`'s running `sum` accumulator keeps `i32` too
  (needs >16-bit headroom during folding, a correct design choice, not
  an oversight).

**A second real regression found via `--forbid-trap` while rewriting
`http_server.tkb`** (not merely a type error this time -- a SILENT loss
of a proof that had been catching zero trap sites before): naively
upcasting `doff` to `i32` right before multiplying (`(doff as i32) * 4`)
compiles fine and LOOKS equivalent, but a plain `as i32` cast discards
`doff`'s if-narrowed `{5..<16 as u8}` range (same "Cast to a
non-refined-syntax target always drops refinement" rule as above), so
`tcp_hdr_len` came out unrefined instead of the `{20..<61}` its own
comment claimed -- and `data_off = 34 + tcp_hdr_len` lost its upper bound
as a direct consequence, reopening a trap site at
`frame[data_off..<data_off+3]` (the TCP-options-skip / "GET" sniff,
previously proven by the same-base rule with ZERO runtime check). Caught
immediately by re-running `--forbid-trap` after the rewrite (exactly the
verification step the plan called for), not by a passing-but-wrong test.
Fixed with the EXPLICIT refined cast instead of a plain one:
`(doff * 4) as {20..<61 as i32}` -- `doff * 4` on the narrowed
(u8-based) `doff` proves `{20..<61 as u8}` via ordinary Mul propagation,
and casting that to an EXPLICIT `{20..<61 as i32}` target (same bounds,
different base) is a free coercion (the checked-refined-cast machinery
proves it needs no runtime check, since the source range already implies
the target range exactly) -- carrying the proven range across the width
change instead of discarding it. Applied to `tcp_echo.tkb` too for
consistency (not strictly required there for `--forbid-trap`, since that
file's equivalent `data_off`/`data_len` site is already `unsafe`-wrapped
and skips the check regardless of `tcp_hdr_len`'s range -- but a plain
cast would still have been quietly wrong in the same way, just invisible
there). **General lesson reinforced**: any `as ConcreteType` cast on a
value whose refined range is later needed for a proof is a potential
silent proof-loss point, not just a width conversion -- the explicit
refined-cast form (`as {lo..<hi as base}`) is the correct tool whenever
that range must survive a base change, now that the syntax exists to
express it.

**Verification**: every one of the 5 rewritten files was checked
individually (not just at the end) -- `dune build`, `--forbid-trap`
(zero new trap sites in each), a byte-exact diff against `.expected`
output for the parse-only demos (`ip_parse`, `tcp_parse`), and the live
`scripts/*_test.py` protocol tests under QEMU for the networked ones
(`icmp_echo_test.py`, `tcp_echo_test.py` -- including the data-echo stage
that exercises `tcp_echo.tkb`'s one `unsafe` site, `http_server_test.py`
-- including the request-counter bump). Full `make check` (langcheck,
370 unit tests, stm32build, all 125 qemutest cases) passes with zero
regressions after both bugs above were fixed.

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
   `mut`/a non-literal initializer). `array_size` also has `+`/`-`/`*`/`/` and parenthesized-grouping
   productions (added later, see "Array-Size Arithmetic Formulas" below) evaluating directly to an
   `int` during parsing, using the same flat-ambiguous-alternatives-plus-global-`%left`-precedence
   idiom the main `expr` grammar already uses for `PLUS`/`MINUS`/`TIMES`/`DIV` (confirmed this
   resolves precedence correctly for a second, unrelated nonterminal reusing the same token
   declarations -- `2 + 3 * 4` parses as `2 + (3 * 4)` = 14, not `(2 + 3) * 4`).
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

### Array-Size Arithmetic Formulas

`array_size` originally only accepted a bare `INT` or a single `Const_env`-resolvable name --
combining two constants (`QNUM * RX_BUF_SIZE`, `ETH_RX_DESC_COUNT * ETH_DESC_SIZE`) had to be
hand-computed into a literal, with a comment recording the formula so a future edit to either
constant wouldn't silently leave the array size out of sync (exactly the drift risk "Global
Constant Folding" below closes for a global's *value*, just on the *array-size* side instead).
`examples/common/virtio_mmio.tkb`'s `rx_queue_mem`/`tx_queue_mem`/`rx_bufs` and
`examples/common_stm32/eth.tkb`'s `eth_rx_descs`/`eth_tx_descs`/`eth_rx_bufs` all had exactly
this shape before this feature.

**Extended `array_size` to a small arithmetic grammar**, evaluated to a plain `int` directly
during parsing (no new phase, no `Types.ty` involvement -- same reasoning as the original
"resolve in the parser, not via a `Types.ty`-level pass" trade-off above still applies): a
literal, a `Const_env`-resolvable name, `+`/`-`/`*`/`/` combining two `array_size`s, or a
parenthesized `array_size` for grouping. Division by zero is a `Types.TypeError` at the
division site, not a crash. No forward references (same restriction as before -- a referenced
name must already be in `Const_env`'s table). `sizeof(T)` still cannot appear in an array-size
formula (unchanged from the existing "Not supported" note above -- `sizeof` needs
`struct_lltypes`/`DataLayout`, only available at codegen time, well after array sizes are
already resolved).

**Scope boundary vs. "Global Constant Folding" below**: this only widens the `[T; N]` grammar
position specifically. A global `let`'s own initializer expression is a completely separate
code path (`lib/llvm_gen.ml`'s `eval_const`/`eval_const_int`, operating on an already-parsed
`Ast.expr` at codegen time) and still cannot fold arithmetic BinOps -- `let ETH_DESC_SIZE: i32 =
ETH_DESC_WORDS * 4;` still fails with "unsupported constant expression" today, only
`let mut eth_rx_descs: [u8; ETH_RX_DESC_COUNT * ETH_DESC_SIZE];` (the array-size position) is
fixed by this feature. Likewise, a few remaining hand-computed literals with an explanatory
comment are deliberately NOT touched by this feature because they are not in the array-size
grammar position at all -- e.g. `examples/common/virtio_mmio.tkb`'s and
`examples/common_stm32/eth.tkb`'s `min(net_last_rx_desc_idx, 7)` / `min(eth_rx_cur, 3)` calls,
where the `7`/`3` is a plain function-call argument that needs to be recognized as a
compile-time constant by `Const_env.bound_value` (used by the refined-type range machinery),
not by `array_size` -- `Const_env.bound_value` still only recognizes a bare `IntLit` or `Var`,
not arithmetic, so `min(idx, QNUM - 1)` there still does not resolve to a proven range today.
Extending `Const_env.bound_value` the same way is a natural, still-open follow-up, not done as
part of this feature.

Files: `lib/parser.mly` (`array_size` grammar), `examples/common/virtio_mmio.tkb` +
`examples/common_stm32/eth.tkb` (hand-computed literals replaced with their formulas), 7 new
parser unit tests in `test/test_takibi.ml` (product/difference of named constants, operator
precedence without and with explicit parentheses, division, division-by-zero error, and an
undefined name inside a formula).

### Global Constant Folding: `as` Casts and Cross-Global References

Extends the same "compile-time constant" idea as the array-size constants
above (and reuses the same no-forward-references convention), but for the
*value* side: an immutable global's initializer can now be an `as` cast
chain (`let ETH_RDES0_OWN: i32 = 0x80000000 as i32;`) or a reference to an
earlier immutable global constant (`let HTTP_SERVER_IP: [u8;4] = OUR_IP;`),
not just a bare `IntLit`/`StructLit`. Motivated by two real pain points hit
during the STM32 Ethernet work (see git history around 2026-07): the `as
i32` cast above used to fail with "unsupported constant expression" (had to
be written as a bare literal instead), and `examples/common_stm32/
netconfig.tkb`'s `HTTP_SERVER_IP` had to duplicate `OUR_IP`'s array literal
verbatim, so the two could silently drift apart if only one was ever
edited. Both are fixed now (see that file and `examples/common_stm32/
eth.tkb`'s `ETH_RDES0_OWN`/`ETH_TDES0_OWN`).

**Design: fold in OCaml-int space, not via LLVM constant-expression ops.**
`lib/llvm_gen.ml`'s `eval_const_int` reduces an integer/bool-valued
constant expression (`IntLit`, an `as` cast chain, the unary-minus desugar
`BinOp(Sub, IntLit 0, _)` -- see "Unary Minus is Desugared in the Parser"
above -- or a `Var` reference) to a plain OCaml `int`, entirely without
calling into LLVM. This sidesteps a real gap: the LLVM 19 OCaml bindings
expose `const_trunc` but not `const_zext`/`const_sext`, so there is no
direct constant-folding primitive for a *widening* cast. Working in OCaml
int space avoids needing one at all -- `Llvm.const_int` already wraps/
truncates its input to the target width when the value is finally
embedded, exactly like the pre-existing `IntLit i, _ -> const_int
(ltype_of_ast ft) i` case already relied on. The only place explicit
masking is still needed is a *narrowing* cast **in the middle of a chain**:
`(300 as u8) as i32` must truncate to 44 before widening back to i32, or
the outer i32 cast would silently see the untruncated 300. `eval_const_int`
handles this by masking at every `Cast` layer using *that layer's own*
target width (from the AST node itself, not the outer caller's `ft`), so
each truncation happens at exactly the point the source `as` chain says it
should.

**Cross-global references reuse one table, `global_const_defs`**
(name -> declared type + original initializer expr), populated by
`gen_global` in source order as each immutable global with an initializer
is processed. `eval_const`'s new `Var name, _` case looks the name up and
recursively re-evaluates the *referenced global's own initializer
expression* against the current `ft` -- this one case handles scalar,
array, and struct references uniformly (no separate array-specific logic
needed), and `eval_const_int`'s own `Var` case does the same for the
integer-folding path. A `let mut` global is never recorded (its value can
change at runtime, so it is never a compile-time constant); referencing
one, or referencing a global declared *later* in the source (no forward
references, same restriction as `Const_env`'s array-size constants),
simply finds no entry and raises a clear `Llvm_gen.Error` rather than
silently reading a stale or wrong value.

**Why this didn't need a `type_inf.ml` change for scalars, but did for
arrays/structs**: `infer_expr`'s ordinary `Var` case decays an array-typed
variable to a pointer (correct for using the array as an ordinary
expression value, e.g. passed to a function) -- but a global referencing
another global by name means "copy that global's value", so unifying the
declared array type against the decayed pointer type was rejecting exactly
the case this feature exists to allow. Pass 2 of `infer_program` (global
initializer checking) now has a dedicated `Var vname` branch that looks
`vname` up in `genv` directly (the raw, undecayed type) and unifies
against that instead of going through `infer_expr`. Scalar references
already worked before this change (a scalar type never decays), so this
branch is a pure generalization, not a behavior change for the cases that
already passed.

**Deliberately NOT implemented**: general constant-expression arithmetic
(`Add`/`Mul`/etc. between two constants). The unary-minus case is handled
only because it is a single, very common, already-desugared shape
(`BinOp(Sub, IntLit 0, _)`); a broader "constexpr" evaluator was judged
out of scope for what was actually asked for (an `as` cast and a
same-value global reference), per this project's usual practice of not
generalizing ahead of a concrete need. Revisit if a real example needs
e.g. `let X: i32 = A + B;` between two global constants.

**Files**: `lib/type_inf.ml` (Pass 2's `Var` branch), `lib/llvm_gen.ml`
(`global_const_defs`, `eval_const_int`, `eval_const`'s `Cast`/`Var` cases),
`examples/common_stm32/eth.tkb` (`ETH_RDES0_OWN` cast restored,
`ETH_TDES0_OWN` now references it), `examples/common_stm32/netconfig.tkb`
(`HTTP_SERVER_IP` now references `OUR_IP`), 7 new unit-test cases in
`test/test_takibi.ml`'s `codegen_tests` (cast folding, chained truncating
cast, unary minus, scalar/array cross-references, and the two rejection
cases: mutable-global reference and forward reference).

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

**This workflow is a central goal of the project, not a side feature**:
start permissive (traps allowed -- a trap is not a bug but a SIGNAL that
type information is missing), strengthen types incrementally (for-loop
refinement, {lo..<hi}, slice minimum lengths, narrowing), and finally ship
with --forbid-trap, which guarantees the emitted binary contains zero trap
instructions. SPARK/Dafny assume rigor from day one; takibi's bet is that
raising rigor PER DEVELOPMENT PHASE, supported at the language level, is
the right shape for embedded work ("Gradual Elimination of Runtime Traps").
Two invariants keep the path to ship monotonic:
- **Proofs are only lost at mutation points, never at annotation**: an
  immutable `let` keeps the initializer's proven type (slice minimum /
  refined range) even under a weaker annotation -- a weaker annotation must
  never manufacture trap sites out of already-proven code, because those
  would resurface as ship-time rejections with no real proof gap behind
  them. `let mut` keeps its declared (honestly weak) type: reassignment
  can bring weaker values, so its checks mark real gaps.
- **Unchecked assertions are visibly marked** (`unsafe { ... }`, see below):
  the checks/trap axis and the trust axis stay separate.
Naming note for the future: --forbid-trap may later split into per-category
options (array-bounds trap freedom, checked-cast freedom, safe-pointers-
only, ...) with today's flag becoming the umbrella that enables all of
them; a rename (e.g. --notrap) is on the table then. Not worth churn yet.

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

**`unsafe { expr }`** (expression form; `lib/ast.ml` Unsafe, gated in
`lib/type_inf.ml` via a module-level `unsafe_depth` counter, transparent in
codegen): permits unchecked-assertion constructs inside -- currently
exactly one, slice construction from a raw pointer (`unsafe { p[0..<n] }`,
the driver-boundary op whose false length claim would poison every
downstream proof; that categorical difference from an ordinary local
pointer bug is why unsafe starts HERE and not at general pointer
arithmetic). Key distinction, deliberately preserved: **unsafe produces no
traps** -- a trap is a CHECK the compiler still doubts; unsafe is a
checkless ASSERTION the compiler is told to trust. --forbid-trap polices
the first axis; auditing the second is a future `--list-unsafe`-style
concern (how many human oaths underlie the shipped binary's proofs).
Deliberately NOT yet unsafe-gated: int->ptr / ptr->ptr casts and the
integer-literal->pointer Let coercion (Tier 2 -- ~16 `as *io` sites plus
ring-manipulation reinterprets, concentrated in the HALs; needs a decision
on the no-`as` literal coercion form first), and general pointer
deref/index/arith (Tier 3 -- ~113 pointer bindings in the HALs; marking
everything would drown the signal. Revisit as an `unsafe fn`-style marker
once slices have pushed pointers out of application code).

**Deliberately deferred** (recorded so the next step starts from data, not
guesswork): flow-sensitive assignment kill (narrow until the first write
instead of killing the whole branch), while-condition narrowing
(`while (i < 8)`), symbolic/relational bounds (`{0..<n}` where n is a
runtime value, `i < len` facts) -- the last one is the honest decision
point for a VC+SMT (Z3) backend; everything above stays in the
non-relational interval world where plain OCaml implementation is the
right tool. The empirical result that 43/44 examples needed ZERO relational
reasoning is the argument for not introducing a solver yet.

### Slice Type (P1): []T / [T; N..] -- fat pointer with a compile-time minimum length

Designed from a full census of examples/http_server's raw-pointer usage (see
git history around 2026-07): ~77 of its pointer operations are constant
offsets/lengths inside views whose size was guarded by a constant comparison
-- i.e. provable with interval reasoning only -- so the slice type carries a
compile-time MINIMUM length and nothing more. `[]u8` = minimum 0 (length
unknown), `[u8; 54..]` = at least 54 bytes. No relational (`i < len`-style)
reasoning was added; the census showed exactly one app-layer site that needs
it (tcp_hdr_len options skip), deferred to a later phase.

**Representation / ABI**: an LLVM first-class struct value `{ptr, usize}`
(`ltype_of_ast TypeSlice`), so `gen_expr` returns it as one llvalue and
LLVM's own ABI lowering passes it in register pairs on both targets. The
len half follows the target pointer width: `{ptr, i64}` on AArch64,
`{ptr, i32}` on Cortex-M7. Slices never cross `extern fn` boundaries.

**`.len` is usize, not i32** (deliberate): composes cast-free with
`sizeof(T)` (`if (s.len >= sizeof(Hdr))`), encodes non-negativity in the
type instead of as an out-of-band invariant, and forces an explicit
`(wire_value as usize)` exactly at the untrusted-input trust boundary,
consistent with the pointer-cast philosophy.

**Creation forms**:
- `arr as []u8` -- array variable to slice; the array's static size becomes
  the minimum ([u8; 16] -> [u8; 16..]). Note infer_expr's Var case decays
  arrays to *T, so BOTH type_inf's and llvm_gen's Cast cases recover the
  length from the declared binding, not from the decayed source type.
- `s[a..<b]` on a slice/array -- constant-bound subslice, proven against
  the base's minimum at compile time (a runtime-bound subslice is a
  compile error for now -- P3), yields `[T; (b-a)..]`.
- `unsafe { p[a..<b] }` on a raw pointer -- UNCHECKED slice construction
  (the driver-boundary escape hatch; as unsafe as the pointer arithmetic it
  replaces, but done once, after which accesses are bounds-governed). The
  `unsafe { ... }` marker is REQUIRED (compile error without it -- see the
  unsafe paragraph in the --forbid-trap section): this is a length
  assertion with no evidence, and it must be visible when writing and when
  reading. Constant bounds still yield a minimum. Rejected on `*io T`
  (slice loads/stores are non-volatile and would silently drop io
  semantics).

**Indexing / proof rule**: `s[i]` is proven (no check, no trap site) iff
i's range `{lo..<hi}` satisfies `lo >= 0 && hi <= minimum`; the minimum is
a lower bound of the runtime length, so this is sound. Anything unproven
gets a runtime check against the RUNTIME length (`emit_bounds_check_dyn`:
zext the i32-widened index to usize width -- negative indices become huge
unsigned values -- one unsigned compare, llvm.trap, recorded as a
--forbid-trap site).

**Length narrowing**: `if (s.len >= K)` upgrades the binding's minimum to K
inside the branch. Single shared recognizer `Ast.slice_len_mins` consumed
by type_inf's narrow_from_cond AND llvm_gen's apply_narrowing/_mut (sync
rule), subject to the same written_names kill rule as integer narrowing
(assign/alias/rebind of the slice kills it). Mut bindings go through
narrowing_ctx (consulted via effective_slice_min at Index/AssignIndex/
SliceOf sites); Imm bindings are replaced in the locals table directly.

**Subtyping**: `unify (TSlice m_actual) (TSlice m_expected)` succeeds iff
m_actual >= m_expected (mirrors TRefinedInt's one-directional rule; unify's
call sites all pass (actual, expected)). **Annotations do NOT weaken
immutable bindings**: `let m: []u8 = s[2..<6];` keeps the initializer's
proven `[u8; 4..]` (and `let x: i32 = v` keeps v's `{lo..<hi}`) -- see the
"proofs are only lost at mutation points" invariant in the --forbid-trap
section for why (an earlier version let the annotation win, which
manufactured ship-time --forbid-trap rejections out of already-proven
code). `let mut` keeps the declared type; its checks mark real proof gaps.
Documented in examples/slice/slice.tkb's header.

**Codegen re-verifies what type_inf proved** (constant subslice range vs.
its own effective minimum) and raises a "BUG:" Error on disagreement,
rather than trusting silently -- keeps the two-sided sync-rule discipline
auditable.

**Files**: `lib/ast.ml` (TypeSlice, SliceOf, slice_len_mins, written_names
case), `lib/lexer.mll` (DOTDOT -- ".." lexes after "..<" by longest-match),
`lib/parser.mly` ([]T, [T; N..] via array_size, IDENT[e..<e]),
`lib/types.ml` (TSlice + subtyping unify), `lib/type_inf.ml` (.len, Index,
SliceOf, AssignIndex, Cast, narrow_from_cond), `lib/llvm_gen.ml` (ltype,
ditype-as-pointer, slice_ptr/slice_len/make_slice/effective_slice_min,
emit_bounds_check_dyn, Index/AssignIndex/SliceOf/Cast/FieldGet cases,
narrowing), `examples/slice/` (demo, both targets, --forbid-trap clean:
forbid_trap_slice in run_qemutest.sh), 11 unit-test cases.

P2 (for-in + builtins), P3 (checked/refined subslices + the http_server
migration), and P4a (interval extensions + same-base rule -- see its
section below) are delivered. **P4a proved the "no solver needed"
hypothesis**: the TCP-options skip and the runtime-length segment view --
the two sites P3 classified as relational -- are both PROVABLE now (the
ftp4_probe unit test reproduces http_server's full guard chain with zero
trap sites). What remains (P4b, source migrations + one genuine leftover):
- rewriting http_server's checksum spans and options skip onto the
  now-provable slice forms (needs inet_checksum's slice signatures first,
  which drags all its callers -- one migration wave with the `*_p`
  removal below);
- response building (copy_str / write_udec appends at runtime offsets) --
  bounded today only by a documented static margin; needs bounded-append
  forms (e.g. range-carrying slice_copy returns), the one item where new
  design is still open;
- migrating arp_reply / icmp_echo / tcp_parse / tcp_echo off the
  TRANSITIONAL `*_p` netutil wrappers (mechanical, http_server is the
  template).

### for-in Element Iteration and Slice Builtins (P2)

The P2 goal: variable-length buffer code (the netutil.tkb /
inet_checksum.tkb shape) must be writable with zero trap sites and zero
relational reasoning. Three pieces, all demonstrated end-to-end in
examples/foreach (which runs under QEMU on both targets and is
--forbid-trap clean -- forbid_trap_foreach in run_qemutest.sh):

**`for x in s { ... }`** (`Ast.ForEach`): element iteration over a slice.
The compiler generates the counter (`__foreach_<name>`, usize-width, pre
-allocated by collect_lets like For's `__for_`), the length compare, and
the in-bounds element load -- safe by construction, no index exists so no
index proof exists. The slice expression is evaluated ONCE at loop entry
(snapshot semantics, like For's bounds); x is an immutable per-iteration
value (widened per the widen_load invariant). Block layout mirrors For
exactly, including `continue` -> incr_bb. Iterating a non-slice is a
compile error suggesting `arr as []T`. ForEach is covered by
written_names (rebinding kills outer narrowing) and
check_const_shadowing -- both have explicit ForEach cases; note
check_const_shadowing and collect_lets have `_ -> ()` fallbacks, so a
future statement form must be added there BY HAND (the OCaml
exhaustiveness check will not flag those two).

**`slice_copy(dst, src) -> usize` / `slice_eq(a, b) -> bool`** (compiler
builtins, dispatched in type_inf's and llvm_gen's Call cases BEFORE the
fenv/functions lookup; the names are reserved -- defining fn/extern fn
with them is a compile error via check_reserved_fn, since a user
definition would be silently unreachable). Both are TOTAL functions:
- slice_copy copies min(dst.len, src.len) elements FORWARD and returns the
  count; a length mismatch shows in the return value, never as a trap.
  The forward loop keeps the overlap guarantee bytes_copy's callers
  already rely on (dst not leading src -- tcp_echo's payload shift).
- slice_eq is false on length mismatch, true iff all elements match.
Codegen builds phi-based loops, NOT allocas (an alloca at the call site
would sit inside any enclosing loop and grow the stack per iteration),
and NOT llvm.memcpy (with a dynamic length the intrinsic lowers to a
memcpy libcall = bare-metal link error, the same reason run_optimizations
excludes the loop-idiom pass).

**The checksum pattern**: examples/foreach's checksum_slice writes RFC
1071 without indexed access -- a hi/lo alternation flag replaces
inet_checksum.tkb's stride-2 loop (`data[i]`, `data[i+1]`, guarded by
`i + 1 < len`), which is exactly the loop shape that would otherwise
demand relational reasoning. Same algorithm, verified against the same
kind of vector at runtime under QEMU.

Files: `lib/ast.ml` (ForEach + written_names case), `lib/parser.mly`
(second FOR production -- LBRACE vs DOTDOTLT after the expression
disambiguates, no grammar conflict), `lib/type_inf.ml` (ForEach inference,
check_const_shadowing case, two builtin Call cases, check_reserved_fn),
`lib/llvm_gen.ml` (collect_lets case, gen_stmt ForEach, two builtin Call
intercepts), `examples/foreach/`, 7 unit-test cases.

### Checked/Refined Subslices and the http_server Migration (P3)

**Refined-bound subslice proof**: subslice bounds are judged by their
STATIC VALUE RANGES (a constant k is {k..<k+1}; a refined-typed expression
contributes its {lo..<hi}), shared formula in type_inf's SliceOf
`bound_range` and llvm_gen's SliceOf `gen_bound` (sync rule; llvm_gen also
consults narrowing_ctx for Mut bound variables, like Index does). Proven
iff `min(lo) >= 0 && max(lo) <= min(hi) && max(hi) <= base minimum`; the
result minimum is the guaranteed length `min(hi) - max(lo)`. This is what
makes the driver-boundary pattern interval-only: after
`if (len >= 54 && len <= 1514)`, `frame[0..<len]` on a [u8; 1514..] frame
is proven with NO runtime check and yields [u8; 54..].

**Runtime-checked subslice (gradual form)**: an unprovable subslice on a
slice base emits `0 <= lo && lo <= hi && hi <= s.len -> llvm.trap`, one
recorded --forbid-trap site; the result keeps whatever minimum the static
ranges still guarantee. SEMANTICS CHANGE from P1: a constant subslice
beyond the base's minimum (s[2..<10] on [u8; 8..]) is now a checked
subslice, NOT a compile error -- the runtime length may exceed the
minimum. Only definitely-malformed bounds (lo < 0, lo > hi) and
array-base violations (arrays have EXACT lengths) remain compile errors.

**Smaller pieces**: `"literal" as []u8` (compile-time byte length, NUL
excluded, becomes the minimum -- `slice_copy(dst, "..." as []u8)` is the
bounded replacement for copy_str's unbounded scan, not yet used by
http_server's response island); `s as *T` (explicit bridge back to the
pointer world, just the ptr half -- casting a slice to anything else is
still an error); Const_env constant names as PROVEN INDICES
(`tcp[TCP_FLAGS]` -- Index/AssignIndex idx_ty now checks
Const_env.bound_value first, sound because check_const_shadowing forbids
shadowing).

**Driver boundary**: both backends gained
`net_rx_frame() -> [u8; 1514..]` (the return ANNOTATION matters: an
earlier `-> []u8` silently erased the minimum and broke every downstream
proof -- annotation weakening still applies at function boundaries, only
immutable `let` bindings are exempt). The single `unsafe { p[0..<1514] }`
lives inside the driver, next to the buffer-size evidence that justifies
it; application code contains no unsafe at all.

**http_server migration** (the payoff; wire behavior verified byte-exact
by the existing protocol tests + real handshake/GET/counter flow): all
header parsing and rewriting now goes through constant-offset views
(`frame[14..<34]` ip, `frame[34..<54]` tcp) and the slice-based
read/write_u16/32be; adjacent offset constants double as field subslices
(`arp[ARP_SHA..<ARP_SPA]`). The DEVICE-REPORTED length is clamped once
(`len <= 1514` in the IPv4 branch) before total_len may trust it --
killing the latent OOB found in the P3 census. http_server remains
--forbid-trap clean (locked in by forbid_trap_http_server in
run_qemutest.sh). Its remaining pointer islands are enumerated in the
file header and in the P4 list above.

**netutil.tkb**: read/write_u16be/u32be now take [u8; 2..] / [u8; 4..]
(bodies are fully proven, zero checks); `*_p` TRANSITIONAL pointer
wrappers (each containing the one unsafe assertion its pointer caller was
implicitly making) keep arp_reply / icmp_echo / tcp_parse / tcp_echo
compiling until they migrate -- do not use `*_p` in new code.
bytes_copy/bytes_eq/copy_str/write_udec keep pointer signatures for the
un-migrated callers and http_server's response island.

Files: `lib/type_inf.ml` + `lib/llvm_gen.ml` (SliceOf rework, Cast
additions, Index const-name rule), `examples/common/netutil.tkb`,
`examples/common/virtio_mmio.tkb`, `examples/common_stm32/eth.tkb`,
`examples/http_server/http_server.tkb`, `_p` renames in the four
un-migrated examples, 5 unit-test cases + 2 updated to the new checked
semantics.

### Interval Extensions and the Same-Base Subslice Rule (P4a)

Four small, individually-sound extensions that together discharge both
sites P3 had classified as "genuinely relational" -- still with no
relational abstract domain and no solver. The ftp4_probe unit test
reproduces http_server's complete guard chain (device-length clamp, ihl
equality, total_len-vs-frame-room, runtime-length segment view, options
skip) and proves it end to end with zero trap sites.

1. **Interval arithmetic propagation** (type_inf's and llvm_gen's BinOp
   typing, sync rule -- change together):
   `{a..<b}+{c..<d} -> {a+c..<b+d-1}`, `{a..<b}-{c..<d} -> {a-d+1..<b-c}`,
   `{a..<b}*k -> {a*k..<(b-1)*k+1}` for a positive literal k (what carries
   doff's {5..<16} into tcp_hdr_len's {20..<61}).
2. **Equality narrowing**: `if (ihl == 20)` narrows to {20..<21} (Eq joins
   Ge/Gt/Le/Lt in both bound collectors).
3. **Comparison against a range-known operand**: the bound collectors were
   rewritten around a range_of helper -- a literal / Const_env constant is
   {k..<k+1} (subsuming the old 8 patterns) and a VARIABLE with a refined
   binding contributes its own range, so `total_len <= ip_len_in_frame`
   narrows total_len's upper bound to ip_len_in_frame's static maximum.
   The fact collapses to a constant AT COLLECTION TIME, which is why this
   is still interval reasoning and needs no new kill obligations (the
   constant was true when the condition executed; the narrowed variable's
   own kill is governed by written_names as before). type_inf's
   collect_bounds now takes tyenv; llvm_gen's collect_bounds_cond takes
   locals (+ narrowing_ctx, which moved above it in the file).
4. **Same-base subslice rule** (`Ast.var_plus_const`, single shared
   decomposition -- sync rule): `s[v + j ..< v + k]` (same variable,
   constant offsets) has length exactly k - j, and lo <= hi holds iff
   j <= k regardless of v's value -- the correlation plain intervals treat
   as two independent occurrences. This is the depth-1 "difference
   constraint" (ABCD's minimal subset) obtained syntactically. io-qualified
   bases are excluded in both checkers: the two bound loads would be
   volatile and could disagree. With v's range known the subslice is fully
   proven; without it, the runtime check remains but the EXACT length k - j
   still survives into the result minimum (so `frame[off..<off+3]` with an
   unbounded off is 1 site, and d[2] inside is still proven).

**Known conservative gap (safe direction, documented in
collect_bounds_cond's comment)**: codegen does not consult narrowing_ctx
for variables reached through arithmetic inside bound expressions, and
does not see refined globals -- where type_inf proves but codegen cannot,
the check stays and --forbid-trap reports it; binding the value to an
immutable local (the natural style anyway) resolves it. All the guard
values in the probe/http_server chain are immutable lets, so this gap
never fires there.

Files: `lib/type_inf.ml` (BinOp Add/Sub/Mul, collect_bounds rewrite,
SliceOf same-base), `lib/llvm_gen.ml` (BinOp mirror, collect_bounds_cond
rewrite, SliceOf same-base), `lib/ast.ml` (var_plus_const), 6 unit-test
cases including the probe.

### P4b: The Migration Wave (netutil/inet_checksum -> slices, all five
### protocol examples off pointer+length pairs)

P4a's probe proved the TECHNIQUE works; P4b applied it everywhere and, in
doing so, found and fixed one more real gap in the narrowing machinery
plus confirmed exactly where the honest relational boundary sits in
practice (one file, one path, precisely accounted for -- not "the census
was wrong").

**inet_checksum.tkb migrated to slices**: `checksum_add(data: []u8,
sum_in: i32)` and `inet_checksum(data: []u8)` -- no length parameter; the
slice's own `.len` (walked via `for b in data`, examples/foreach's hi/lo
alternation technique) replaces the old stride-2 index loop entirely.
`checksum_fold` is unchanged (pure integer folding, never touched a
buffer).

**The critical redesign that made checksum spans provable across a
function call: pass an ALREADY-SLICED SEGMENT, never an integer length.**
`fix_tcp_checksum(ip: [u8; 20..], tcp_seg: [u8; 20..])` takes the full
segment directly and reads `tcp_seg.len` back for the pseudo-header's
length field (so it can never disagree with what it's actually
checksumming). This sidesteps a hard limit: **TRefinedInt-to-TRefinedInt
function arguments require an EXACT range match, not subtyping**
(`unify`'s TRefinedInt/TRefinedInt case raises unless `lo1=lo2 && hi1=hi2`
-- there is no general "narrower fits into wider" rule the way slice
minimum-length subtyping has). Passing an integer LENGTH into a function
and trying to prove a subslice INSIDE that function against a plain `i32`
parameter therefore never works (the parameter carries no range at all).
Passing an already-constructed SLICE VALUE instead works, because slice
parameters use genuine covariant subtyping (`m_actual >= m_expected`) --
so the proof happens once, at the call site (where the length variable's
real refined range is still in scope), and the callee just consumes the
slice's own runtime `.len`.

**Where exact-match refined parameters DO work**: `ihl: {20..<21}` is used
as a parameter type in every migrated file's header-touching functions.
This is legitimate specifically because each file's scope is "IHL always
exactly 20, no IP options" -- an existing runtime precondition, previously
enforced only by an `if`, now stated in the type signature -- and the ONE
caller narrows via `ihl == 20` (Eq narrowing), producing the EXACT SAME
`{20..<21}` the callee declares. This only works because caller and
callee agree on the identical literal range; it would NOT generalize to
"pass any 16..<24 IHL", which is the real content of the TRefinedInt
exact-match limitation above.

**Second real bug found and fixed: if-narrowing silently no-oped on an
ALREADY-refined variable.** Both `narrow_from_cond` (type_inf.ml) and
`apply_narrowing`/`apply_narrowing_mut` (llvm_gen.ml) originally matched
only `Some (TI32, is_mut)` / `Some (Mut (TypeI32, _))` -- if the variable
arriving at the `if` was ALREADY `TRefinedInt` (extremely common once
P4a's interval propagation and the B-plan "proofs survive weaker
annotations" rule are both in play -- e.g. `icmp_len: i32 = total_len -
ihl` picks up a refined range straight from its Sub-propagated
initializer), the narrowing branch didn't match, fell through to `_ ->
env`/`_ -> saved`, and the condition's tighter bounds were silently
DISCARDED -- the variable kept its wider pre-existing range instead of
the INTERSECTION. Found migrating icmp_echo (`if (icmp_len >= 8 &&
icmp_len <= 1480)` failed to narrow icmp_len past its Sub-derived
`{0..<1481}`, so the resulting subslice's minimum stayed 0, failing to
satisfy a callee's `[u8; 8..]` parameter). Fixed by adding an
`TRefinedInt (elo, ehi) -> intersect` case to all three call sites (a
Mut variable can also arrive already-narrowed from an OUTER if via
narrowing_ctx -- llvm_gen's fix intersects with any existing narrowing_ctx
entry too, not just the locals table's declared type). Two regression
tests added (`ftp4b_intersect`, `ftp4b_nested_mut`).

**Companion technique for a MUTABLE accumulator (http_server's response
length, tcp_echo's data_len parameter): snapshot into an immutable
local.** `apply_narrowing`/`_mut`'s narrowing_ctx overlay is only consulted
when the narrowed variable is used DIRECTLY as an index/subslice bound
(`Var n` pattern match in `gen_bound`/Index's idx_ty lookup) -- burying it
inside an arithmetic expression like `54 + len` bypasses narrowing_ctx
entirely (gen_expr's ordinary `Var` case for a Mut binding just returns
the DECLARED type, ignoring narrowing_ctx). The fix used throughout: after
the bounding `if`, `let n: i32 = len;` -- an immutable let's initializer
type comes from `tyenv` directly (which DOES reflect the narrowing) and
the B-plan keeps it via the refined-initializer-survives-weaker-annotation
rule, so plain arithmetic on `n` is fully visible to codegen with no gap.
Documented as a **known conservative gap** (safe direction: codegen may
keep a check type_inf proved away) rather than fixed at the root, since
"make narrowing_ctx aware of arbitrary bound sub-expressions" is
materially more machinery for a problem this local snapshot solves in one
extra line, at the one place it's needed. Both http_server's
`HTTP_MAX_PAYLOAD` check and tcp_echo's `TCP_MAX_PAYLOAD` check are this
pattern AND close a real latent gap simultaneously (the payload/segment
length was previously trusted downstream with no capacity check at all).

**http_server.tkb**: fully migrated, remains --forbid-trap clean
(`forbid_trap_http_server`). The options-skip and the request-checksum
span are now both PROVEN (not just "gradual", per P4a's confirmation);
the two-line `n` snapshot proves the REPLY's checksum span too. Response
BODY CONSTRUCTION (copy_str/write_udec into a raw pointer) remains the one
deliberately-deferred pointer island -- see its own header comment for
exactly why (needs bounded-append primitives, not subslice/interval
machinery) and the enforced `HTTP_MAX_PAYLOAD` margin that bounds it today.

**arp_reply.tkb, icmp_echo.tkb**: fully migrated and fully proven (both
now registered as `forbid_trap_arp_reply` / `forbid_trap_icmp_echo`).
icmp_echo needed the same `len <= 1514` upper clamp http_server already
had (without it, `ip_len_in_frame` stays unrefined and the
narrowing-against-a-range-known-variable extension never fires) plus the
intersect fix above.

**tcp_parse.tkb, ip_parse.tkb**: migrated to slices but DELIBERATELY left
with one genuine runtime-checked (gradual) subslice each -- these
parse-only demos never validate a wire-derived length (`ihl` / `tcp_len`)
against the packet's actual capacity (that's the whole point of their
"corrupted packet" demonstrations), so the checksum span is honestly
unprovable, and the check is a REAL SAFETY IMPROVEMENT over the original
raw-pointer code (which read out of bounds on a corrupted length with no
check at all). Both were removed from run_qemutest.sh's no-trap example
list (which predates this migration and only passed before because
pointer indexing has no checks to begin with, not because these files
were ever proof-complete).

**tcp_echo.tkb**: fully migrated but keeps 2 recorded trap sites in
`build_data_echo`'s data-echo path -- the one place across this entire
migration wave that is genuinely, unavoidably relational with the current
toolkit. `data_off` (where payload starts, past any TCP options) and
`data_len` (how much payload there is) are independently-derived
quantities; proving `data_off + data_len <= frame's capacity` needs a
two-variable fact plain interval arithmetic cannot carry, and the
same-base rule doesn't apply either (it only handles a variable plus a
COMPILE-TIME CONSTANT offset -- `data_len` is a runtime variable, not a
constant). Confirmed concretely by trying to compute `data_len`'s own
Sub-propagated range here: with `tcp_len`/`tcp_hdr_len` both refined, the
formula gives `{-40..<1461}` -- a NEGATIVE lower bound, even though the
existing runtime guard (`tcp_len >= tcp_hdr_len`) makes that impossible at
runtime. Intervals only see each variable's OWN range, not the RELATION
between two of them, so this pessimism is fundamentally the domain's
limit, not a missing extension. Removed from the no-trap example list for
the same honest reason. This is the ONE (out of five protocol examples,
one algorithm library, and one server) file/path in the whole P4 wave that
would need a genuine relational domain or VC+SMT to close -- a strong
empirical data point for "not yet, and maybe not ever, for this
codebase's actual shape."

Files: `examples/common/inet_checksum.tkb`, `examples/common/netutil.tkb`
(`_p` transitional wrappers deleted -- every caller migrated),
`examples/http_server/http_server.tkb`, `examples/arp_reply/arp_reply.tkb`,
`examples/icmp_echo/icmp_echo.tkb`, `examples/ip_parse/ip_parse.tkb`,
`examples/tcp_parse/tcp_parse.tkb`, `examples/tcp_echo/tcp_echo.tkb`,
`examples/inet_checksum/inet_checksum.tkb`, `lib/type_inf.ml` +
`lib/llvm_gen.ml` (the intersect-narrowing fix), `scripts/run_qemutest.sh`
(no-trap list correction + 2 new forbid_trap_* registrations), 2 new
unit-test cases.

### P4c: Closing the P4 Census -- Band Masking, min/max, Same-Base
### Generalization, and unsafe Extended to Slice Bases

Goal stated at the top of P4: every idiom found in http_server (and, by
extension, the other protocol examples) should land in exactly one of two
buckets -- (1) compiles fine without `--forbid-trap` and traps on
violation, unchanged from today, or (2) compiles clean WITH
`--forbid-trap`, either because it's genuinely proven or because an
`unsafe { ... }` marks an explicit, evidence-backed assertion. No third
"silently checked, --forbid-trap just rejects it forever" bucket should
exist without a documented reason. **Result: 43 of 44 examples are now
--forbid-trap clean** (up from 40/44 after P4b); the one holdout
(tcp_parse) is a deliberate exception with a recorded reason, not a gap.

**enum.tkb: Color made non-exhaustive.** The residual cast-check trap
(`raw as Color`, `raw: u8` with no static evidence bounding it to
{0,1,2}) was correct, not a bug -- but it also wasn't the RIGHT fix to
just accept forever. The user's insight: this demo's own cast site has no
evidence at all, so the type-level choice matching REALITY is "any byte
value is a legal Color" (open-ended), which is exactly what `_;`
(non-exhaustive) already means. Color gained `_;`; `color_name`'s match
gained a required `_` arm (compiler-enforced for non-exhaustive enums).
**Important distinction surfaced while investigating this**: a `match`
with no `_` on an EXHAUSTIVE enum compiles its uncovered case to LLVM
`unreachable`, not `llvm.trap` -- so the cast's check is not a redundant
courtesy alongside match exhaustiveness, it's the ONLY thing standing
between an invalid value and genuine undefined behavior (the optimizer is
free to assume `unreachable` never executes). This is why `unsafe { raw
as Color }` (skipping an exhaustive-enum cast's check) is a materially
more dangerous escape hatch than the slice/pointer cases below, and was
deliberately NOT added -- non-exhaustive enum is the existing, already-
sound tool for "I don't have evidence, and I'm ok with any value."

**Band (`&`) mask range propagation** (`lib/type_inf.ml` + `lib/llvm_gen.ml`
BinOp Band case, sync rule): `x & k` for a non-negative literal mask k ->
`{0..<k+1}`, regardless of x's own sign or range (bitwise AND with a
non-negative value can only clear bits, so the result is always in
[0, k] in two's complement, for ANY x). Symmetric (k may be either
operand). This is what gives `(byte & 0x0f) * 4` (the ubiquitous IHL
field extraction) a real range with NO prior narrowing at all -- `& 0x0f`
alone gives {0..<16}, and P4a's existing Mul rule carries that to
{0..<61}.

**`min(a,b)` / `max(a,b)` builtins** (compiler builtins, reserved names,
dispatched like slice_copy/slice_eq): the tool for clamping a wire-derived
value against a compile-time buffer capacity -- `min(ihl, 20)` is
provably <= 20 no matter what ihl turns out to be at runtime. The
asymmetry in what each bound needs is the actual content of the rule, not
an implementation shortcut:
- `min(a,b) <= a` and `<= b` ALWAYS (definition of min), so if EITHER
  operand's upper bound is known, that alone bounds the result's upper
  side -- the other operand may be completely unconstrained.
- A LOWER bound for min needs BOTH operands' lower bounds known (an
  unconstrained operand could always be the one that's smaller, dragging
  the result down with it).
- max is the mirror image: `max(tcp_len, 0)` proves >= 0 even though
  tcp_len itself is a bare, unconstrained i32 parameter (lower bound needs
  only one operand known); an upper bound needs both.
"Unknown" is represented with a wide sentinel range (+-1 billion) rather
than a genuine option type, so the result is always a plain TRefinedInt --
a subslice/index proof against any REAL buffer capacity correctly fails to
close against a sentinel (never falsely succeeds), so this is a
representational convenience, not a soundness-relevant choice.

**Two latent gaps found and fixed while building this** (both were
pre-existing, surfaced by exercising min/max against real code, not
introduced by it):
1. `TRefinedInt` had no subtyping rule into `TUsize` at all (only into
   TU64/TU32/etc.) -- `let b: usize = a & 63;` (a: usize) failed to
   unify once Band started returning a refined type. Fixed by adding
   `TRefinedInt (lo, _), TUsize when lo >= 0 -> ()` alongside the
   existing TU64 rule in `lib/types.ml`.
2. Sub only propagated ranges when checking its FIRST operand
   (`TRefinedInt (a,b), _ -> ...`) for refinement -- `40 - ihl` (literal
   MINUS a refined variable) fell through to plain i32, asymmetric with
   Add (which already handles both directions). Added the mirror case:
   `k - {c..<d} -> {k-d+1..<k-c+1}` for a literal k, matching Add's
   existing both-directions handling (sync rule, both files).

**Same-base rule generalized from constant offsets to any non-negative
lower-bounded expression** (`lib/type_inf.ml` + `lib/llvm_gen.ml` SliceOf,
sync rule): P4a's same-base rule only recognized `s[v ..< v + k]` for a
literal k. Needed generalizing the moment a REAL min/max-clamped variable
appeared as the offset (`ip[ihl ..< ihl + tcp_len]`): plain interval
bound_range on `ihl` and `ihl + tcp_len` independently treats the two
occurrences of `ihl` as unrelated, so `ihl`'s own worst case (its upper
bound) can look like it exceeds `ihl + tcp_len`'s best case (its lower
bound) even though they're the same variable and can't actually diverge
like that. The rule now accepts `s[v ..< v + w]` for ANY w (not just a
literal) whose own range has a known non-negative lower bound -- a
literal's lower bound IS the literal itself, so this subsumes the old
rule exactly, no regression. **Deliberate implementation restriction**:
w must be a bare literal or a bare variable, not an arbitrary expression --
llvm_gen's mirror of this check must look up w's range via a direct table
lookup (locals/globals/narrowing_ctx), NOT by calling gen_expr/gen_bound
on it again, because w has already been evaluated once as part of hi_e
itself; re-evaluating an arbitrary expression a second time would risk
duplicating side effects (a general function call, not just a harmless
redundant load). Both sides of the sync rule enforce the same
restriction.

**Honest negative result: CHAINED/correlated clamps do not close.**
Tried extending the above to prove tcp_parse's `ip[ihl ..< ihl + tcp_len]`
fully, using `ihl = min(raw_ihl & 0x3f, 20)` and
`tcp_len = min(tcp_len_raw, 40 - ihl)` (room derived from the ALREADY-
clamped ihl). This does NOT reach zero trap sites: `tcp_len`'s own
{0..<~41} range (from the min/max combination) is correct in isolation,
but combining it with `ihl` via ordinary interval Add loses the fact that
`tcp_len <= 40 - ihl` was how it was DERIVED -- the combined upper bound
computed independently (`ihl`'s own worst case + `tcp_len`'s own worst
case) overshoots the true capacity (40), because that specific worst-case
COMBINATION can't actually co-occur (it would require `tcp_len` to be
large exactly when `ihl` is ALSO large, but `tcp_len`'s clamp was built
FROM `ihl`, so they move together, not independently). This is a genuine,
different-in-KIND limitation from anything else P4c-2 closes: it's the
same class of "two variables secretly correlated via subtraction" problem
as tcp_echo's `data_off`/`data_len`, just one level more indirect (through
an intermediate `room` variable). Confirmed empirically (not just argued)
via a regression test (`ftp4c_chained` in test_takibi.ml) that DOES record
exactly 1 trap site despite every individual clamp being provably correct
on its own. This is the precise, now twice-confirmed boundary of what
interval + same-base + min/max can do without a genuine relational
(difference-constraint) domain or VC+SMT.

**unsafe extended to slice/array-BASE subslice construction, not just
pointer-base** (`lib/llvm_gen.ml`; deliberately NO type_inf.ml change --
see below): previously `unsafe { ... }` only gated pointer -> slice
construction (a length assertion with zero evidence). Extended the SAME
gate to a slice/array-base subslice whose bounds fail the interval/same-
base proof: `unsafe { s[a..<b] }` now SKIPS the runtime check entirely
when `s` is already a slice, an explicit "trust me" with the identical
semantics as the pointer case, closing exactly the correlated-bounds
residue found above (tcp_echo's two sites) without needing a relational
domain at all. **Type_inf.ml needed zero changes**: unsafe doesn't grant
new STATIC information (the computed type/minimum is identical whether
checked or unsafe-skipped -- skipping the check just means "don't verify
what was already computed," not "know something new"), so the type
computation in SliceOf is completely unaffected by unsafe; only
llvm_gen's decision of whether to EMIT the check changes. Implementation:
a module-level `Llvm_gen.unsafe_depth` mirrors type_inf's counter (reset
per compilation like `trap_sites`), incremented/decremented in the
`Unsafe` codegen case (previously fully transparent); `sub_of_slice`
checks it before emitting the check/calling `record_trap`. Applied to
tcp_echo's two documented sites (`tcp_seg[20..<20+n]` and
`frame[data_off..<data_off+data_len]`), both now with comments explaining
the specific evidence backing the assertion (an adjacent runtime check,
or an algebraic identity that the type system can't see but a human can
verify). NOT applied to enum casts (see above) or to tcp_parse (see next).

**tcp_parse's checksum span: fixed by VALIDATING, not asserting away.**
Initially left CHECKED (not unsafe) and flagged back to the user as a
judgment call -- wrapping `ip[ihl..<ihl+tcp_len]` in unsafe would have
silently traded away real protection against a realistic corruption
class (a malformed `ip_total_len`) for --forbid-trap cleanliness this
file was never promised to have. **The user's response identified the
actually-correct fix**: a real binary parser cannot assume its input is
well-formed, so add the SAME validation icmp_echo/tcp_echo/http_server
already do (`if (ip_total_len >= ihl && ip_total_len <= 40)`), report a
malformed segment on failure, and only compute the checksum in the
validated branch. This is not a workaround -- it is the missing input
validation any parser needs regardless of the type system, and it
happens to ALSO make the checksum span fully provable: once
`ip_total_len` is narrowed to `{ihl..<41}`, `tcp_len = ip_total_len - ihl`
gets a real `{0..<21}` range via ordinary Sub propagation (both operands
now refined), and the same-base rule closes `ip[ihl..<ihl+tcp_len]`
outright -- no unsafe, no relational domain, zero trap sites. **All 44
examples are now --forbid-trap clean.** This is arguably the most
important finding of the whole P4 arc: the "one remaining case" wasn't a
type-system gap at all -- it was a missing `if` that any correct parser
needed anyway, and the type system was correctly refusing to let a
genuinely unvalidated wire value drive a buffer access. Worth remembering
before reaching for unsafe or a bigger abstract domain: check whether the
REAL fix is just the input validation the code was missing regardless.

**Practical implication for the enum finding**: the two enum-cast unsafe
questions (whether to extend unsafe to `raw as Color`-style checked casts
in general, and whether enum.tkb's own demo should use it) remain
deliberately unresolved -- flagged as dangerous (unreachable-based, not
trap-based) rather than implemented. Revisit only with a concrete need
distinct from "make this specific demo forbid-trap clean," which
non-exhaustive already solved more honestly.

Files: `examples/enum/enum.tkb` (non-exhaustive Color + match wildcard),
`lib/type_inf.ml` + `lib/llvm_gen.ml` (Band propagation, min/max builtins,
Sub literal-minus-refined case, same-base generalization, reserved names),
`lib/types.ml` (TRefinedInt->TUsize subtyping fix), `examples/ip_parse/
ip_parse.tkb` (min-clamp, now fully proven), `examples/tcp_parse/
tcp_parse.tkb` (ip_total_len validation, now fully proven),
`examples/tcp_echo/tcp_echo.tkb` (one unsafe-wrapped site remaining, down
from two -- see below), `scripts/run_qemutest.sh` (enum/ip_parse/
tcp_parse/tcp_echo all moved back into the no-trap list; 3 new
forbid_trap_* registrations), 7 new unit-test cases including the
honest-negative-result regression.

### P4c Follow-up: Three of Four unsafe Sites Removed, One Confirmed Necessary

After the above, the codebase still had 4 `unsafe` uses: two identical
`net_rx_frame()` implementations (virtio_mmio.tkb / eth.tkb) and
tcp_echo's two data-echo sites. Asked, for each one, "can an `if` remove
this the same way tcp_parse's fix did" -- the honest answer turned out to
be "yes" for three of the four, and each `unsafe` removal PROVED something
genuinely true and useful, not just "make the compiler happy":

**`net_rx_frame()` (both backends): the pointer assertion was itself
hiding an unvalidated device value.** `unsafe { p[0..<1514] }` asserted
"this pointer is good for 1514 bytes" with zero evidence -- but the REAL
issue one line up was that `net_last_rx_desc_idx` (virtio) /
`eth_rx_cur` (STM32), the index selecting WHICH ring slot's buffer `p`
points into, is read from a mutable global with no range at all (in
virtio's case, genuinely DEVICE-REPORTED via `used_ring_get_id()`, never
previously checked against QNUM). Fix: skip the pointer step entirely --
clamp the index with `max(min(idx, QNUM-1), 0)` and construct the
capacity view DIRECTLY from the underlying array (`rx_bufs[offset..<
offset+1514]` / `eth_rx_bufs[...]`), which the interval + Mul/Add +
same-base machinery already proves outright (same-base's literal offset
1514 covers the lo<=hi side; the array's real declared size covers the
capacity side). Net result: closes a real "trust an unvalidated
device-reported ring index" gap, not merely a cosmetic --forbid-trap
fix -- a corrupted index now degrades to reading the wrong (but always
in-bounds) slot instead of driving raw pointer arithmetic with no bound
at all.

**Another Const_env gap found in the process**: `idx * RX_BUF_SIZE`
failed to propagate a range, because Mul's positive-literal-multiplier
check only matched a bare `IntLit` AST node (`e2.desc`), not a
Const_env-resolvable NAMED constant (`RX_BUF_SIZE`, an ordinary
`let RX_BUF_SIZE: i32 = 1536;`) -- the exact same "reference vs. literal
token" distinction already fixed for the `min`/`max` builtins' range
lookups, just missed in Mul specifically. Fixed by using
`Const_env.bound_value` in place of the raw `e2.desc`/`e1.desc` match
(both files, sync rule) -- this is now consistent with how every other
P4a/P4c rule resolves constants.

**tcp_echo's `tcp_seg[20..<20+n]` (one of its two sites): fixed by NOT
re-slicing.** The problem was never irreducible -- `tcp_seg` (itself
`eth[34..<54+n]`, fully proven) has a declared minimum of only 20 (the
worst case n=0), so subslicing INTO it a second time
(`tcp_seg[20..<20+n]`) loses the connection to `n` that `tcp_seg`'s own
construction still has. Constructing the copy destination DIRECTLY from
`eth` instead -- `eth[54..<54+n]` (54 = 34+20, same memory, just reached
without the lossy intermediate step) -- reuses the exact same
literal-offset same-base proof that already closed `tcp_seg` itself.
General lesson: when a same-base-proven slice's OWN subslice fails to
prove, try reconstructing from the ORIGINAL wider-capacity base with the
combined literal offset, rather than assuming the failure is fundamental.

**tcp_echo's `frame[data_off..<data_off+data_len]`: confirmed necessary,
not just assumed.** Two additional reformulations were tried and BOTH
failed, empirically (not just argued by hand): (1) clamping `data_len`
directly with an extra `if (data_len <= TCP_MAX_PAYLOAD)` intersected into
its existing (already broken, spuriously negative) Sub-derived range --
still overshoots, because `data_off`'s own upper bound and `data_len`'s
own upper bound can't actually co-occur (they move in OPPOSITE
directions, both driven by `tcp_hdr_len`), but ordinary interval Add has
no way to know that; (2) introducing an explicit `hi = data_off +
data_len` local and validating `hi >= 0 && hi <= 1514 && data_off <= hi`
directly -- still fails, because `data_off <= hi` narrows `data_off`'s
own upper bound using `hi`'s STATIC range (the existing
comparison-against-a-range-known-variable rule), which is a DIFFERENT,
weaker fact than "lo <= hi holds for THIS specific pair," and the
same-base rule doesn't apply either (`hi` is a separate named variable,
not syntactically `data_off + <something>`). This is the one site in the
entire example suite that needs an actual relational/difference-
constraint domain to close without `unsafe` -- confirmed by exhausting
the interval toolkit's reasonable extensions, not by assumption.

**Final count: 3 of 4 `unsafe` uses removed; the remaining one is the
same site already identified as the P4 census's sole genuinely relational
case.** This is a second strong, now twice-independently-confirmed
empirical data point (after tcp_parse's "it wasn't a type-system gap"
finding) for calibrating VC+SMT's actual necessity in this codebase: even
under direct pressure to eliminate every remaining `unsafe`, the type
system's non-relational toolkit closed everything except this single,
already-diagnosed correlation.

Files: `examples/common/virtio_mmio.tkb` + `examples/common_stm32/
eth.tkb` (`net_rx_frame()` rewritten, unsafe removed), `lib/type_inf.ml`
+ `lib/llvm_gen.ml` (Mul's Const_env-constant fix), `examples/tcp_echo/
tcp_echo.tkb` (one site fixed, one site's necessity reinforced with the
two failed-reformulation findings), 1 new unit-test case for the Mul fix.

**Two follow-up refinements on the remaining site** (same session,
prompted by asking "could net_rx_frame's return type just be more
flexible instead?"):

1. `data_len` is now computed as `max(tcp_len - tcp_hdr_len, 0)` instead
   of the raw subtraction. This is a genuine, safe-side improvement, not
   just cosmetic: the raw Sub result's spuriously negative lower bound
   (an artifact of the type system, not a real possibility) is exactly
   what made the same-base rule's `wlo >= 0` guard fail. Clamping changes
   NO observable behavior (a genuinely-negative raw result clamps to 0,
   and 0 still fails the very next `data_len > 0` check exactly like a
   negative value would have) -- it only makes `data_len`'s own type
   honestly reflect a fact that was already true.

2. **Confirmed by direct algebra why "make net_rx_frame's return type
   more flexible" does not close this, and why the assertion is
   nonetheless 100% true** (not merely "probably fine"): `data_off +
   data_len = (34 + tcp_hdr_len) + (tcp_len - tcp_hdr_len) = 34 + tcp_len`
   -- `tcp_hdr_len` cancels algebraically. And `tcp_len = total_len - ihl
   <= (len - 14) - 20 = len - 34` (using the already-checked `total_len <=
   len - 14` and `ihl == 20`), so `data_off + data_len <= len <= 1514`
   ALWAYS, for any packet that passed the earlier validation -- not a rare
   case, not a protocol edge case, a plain algebraic certainty. Verified
   empirically too, not just by hand: widening `frame`'s declared minimum
   to an absurd 100000 does NOT make the proof succeed with the raw
   (unclamped) `data_len`, because the FIRST failing check is the lo<=hi
   proof (same-base's `wlo>=0` guard), independent of capacity entirely;
   only after fixing that (item 1 above) does the capacity check even
   become the active constraint, and at that point it needs frame's
   minimum to be an inflated (dishonest) ~1554 to close -- confirming the
   gap is purely representational (the type system cannot express "these
   two variables' sum is invariant"), not a real runtime possibility and
   not something any amount of "flexibility" on frame's OWN declared type
   can fix, since frame's type has nothing to do with the data_off/
   data_len relationship at all.

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
