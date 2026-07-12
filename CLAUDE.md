# takibi

A self-made language compiler written in OCaml 5.4.0. Generates native machine code via an LLVM 19 backend.

**The ultimate goal of this project is to demonstrate that runtime errors in a monolithic,
Unix-like kernel -- in the spirit of Linux or NetBSD -- can be lifted into compile-time errors,
by using type-system features C never had** (refinement types, affine/linear ownership, and
eventually SMT-backed proof obligations). This is motivated directly by kernel-space
experience: a userspace SEGV is recoverable (debug it, restart the process), but the
equivalent fault in monolithic kernel space usually does not trap at all -- it silently
corrupts memory and can become a security hole. A great deal of static-verification research
over the last decade has targeted userspace; this project's premise is that kernel space
needs it more, not less. Rust's ownership model was evaluated and judged insufficiently
suited to bare-metal kernel code for this purpose; extending a simpler base language (in the
spirit of ATS2's proof-driven style and its at-view mechanism, generalized past pointers to
arbitrary linear/affine resources) toward that stated goal was judged more tractable than
retrofitting it onto an existing systems language.

The TCP/IP stack + bare-metal HTTP server (Raspberry Pi 3 / RISC-V / STM32) was the first
waypoint on the way there, and is already implemented and running -- see the QEMU/AArch64 and
STM32F746G-DISCOVERY sections below. It exists to prove takibi can express real, nontrivial
systems code at all; the harder, ongoing work is proving that code's runtime-error surface can
be pushed to compile time, which the `--forbid-trap` refinement-type work below is the first
concrete step toward, on the way to expressing Unix-like kernel constructs (schedulers,
virtual memory, drivers, syscall boundaries) with the same discipline.

**Looking for the current language syntax/grammar (types, statements, expressions)?
See `SPEC.md`.** This file is the engineering log -- design rationale, bugs found
and fixed, and the history behind each decision.

## Design Principle: Detect Errors at Compile Time

**In embedded products, zero runtime exceptions and panics is a hard requirement.**
If a runtime trap occurs in a bare-metal environment running timers, UART, and a TCP/IP stack,
the system will silently break or run amok. Nothing is communicated to the user.

- **Detect errors at compile time.** The ultimate goal is to make any access that the type system cannot prove into a compile error.
- **`llvm.trap` is a transitional safety net.** The current array bounds check (`icmp uge` -> `llvm.trap`) aids debugging during development, but on AArch64 it translates to `brk #0` (Synchronous Abort) -- a runtime error that must never occur in production code.
- **The range type `{lo..<hi as base}` is the solution.** If `hi <= N` and `lo >= 0` can be proven at compile time, no `llvm.trap` code is generated at all.
- **When to use an unrefined integer vs `{lo..<hi as base}` is the programmer's responsibility**:
  - `i32` = unknown range (MMIO, external input, etc.) -> bounds check required
  - `{lo..<hi as base}` = value whose range and representation base the programmer knows -> check can be omitted
  - Using an unchecked value read from MMIO directly as an array index is a bug hotbed; a bounds check appearing on `i32` is **correct behavior**

**"Code with remaining bounds checks = code whose type annotations are still insufficient."**
The finished form of code is when index ranges are pinned at the type level using
`for i: usize in 0..<n` or `{lo..<hi as usize}` annotations.

## Development Process: Prove New `.tkb` Code Without `--forbid-trap` First, Then Turn It On

**New `.tkb` work is written and gets fully working WITHOUT refinement types and WITHOUT
`--forbid-trap` first, gets committed as that known-good baseline, and only THEN has
refinement types added and `--forbid-trap` turned on, as one later, separate step.** This is
a durable process rule (not a one-off preference), agreed between the user and Claude Code
while building the `fatfs` example (GitHub issue #61) and its follow-on SD card integration
(issue #62).

**The unit this applies to is a whole working MILESTONE, not necessarily one file in
isolation.** Concretely: `fatfs` (in-memory block device, issue #61) and the real SD/eMMC
driver it plugs into (issue #62) are being built as one such milestone -- refinement types
and `--forbid-trap` stay off across BOTH pieces, all the way through wiring the real SD card
in underneath `fatfs`'s FAT12 logic, not just for `fatfs` alone. Verification during this
whole span comes from integration tests actually exercising the code (QEMU + `mtools` for
`fatfs` alone, then a real SD-card-backed integration test once #62 lands), not from the
compiler. Only once the *whole* milestone (`fatfs` + real SD card, reading and writing an
actual card) is demonstrated working end to end does refinement-typing/`--forbid-trap` get
turned on, in one pass across everything the milestone touched -- not piecemeal after each
intermediate piece. Ask before assuming a smaller or larger milestone boundary than this if
it's ever unclear which pieces of a multi-issue effort are meant to land together before
hardening.

- **While `--forbid-trap` is deliberately off: write plain, idiomatic checked array/slice
  indexing** (`buf[i]`, not raw-pointer arithmetic) and ordinary unrefined parameter types
  (`u32`, `usize`, etc). A runtime trap check being silently inserted is fine and expected at
  this stage -- the goal is purely "does the logic work," verified by actually running it,
  not by making the compiler happy. **Do not reach for raw pointers/`unsafe` merely to route
  around a bounds check that checked array/slice indexing would have needed instead** -- that
  silently reintroduces exactly the unproven-access risk `--forbid-trap` exists to catch, and
  produces a file that trivially "passes" `--forbid-trap` without any of its sites ever having
  been examined. Raw pointers stay reserved for cases that need them regardless of this
  process (a byte-oriented hardware/block-device boundary, a struct-overlay cast onto a raw
  buffer, a NUL-terminated scan whose length isn't known up front) -- not as a shortcut
  through this step.
- **Each intermediate piece still gets committed as its own known-good baseline** once it
  demonstrably works (e.g. `fatfs` alone, verified via QEMU + `mtools`, before #62 exists)--
  this snapshot is the deliberate "before" side of a before/after comparison: it is expected
  to compile cleanly without `--forbid-trap` and to be flagged by it once eventually enabled,
  and that contrast is worth preserving in history, not squashed away -- it is the concrete
  evidence for why `--forbid-trap` (and the refinement-type system behind it) earns its keep,
  valuable for anyone auditing this project's approach later (including turning it into a
  paper). It does NOT mean turning `--forbid-trap` on for that piece yet if the milestone it
  belongs to isn't finished.
- **When the milestone is finished, turn `--forbid-trap` on and fix only what it flags.** Add
  `--forbid-trap` to each affected file's Makefile rule and recompile. Each flagged site gets
  fixed at its root: a refined parameter/loop-bound type (`{lo..<hi as base}`,
  `for i: usize in 0..<n`), or, when the bound genuinely depends on runtime state the type
  system cannot see (e.g. an allocator's own bookkeeping invariant), explicit if-condition
  narrowing (`if (v >= lo && v < hi) { ... }`) right at the point of use. Never "fix" a
  flagged site by swapping the checked access back to a raw pointer -- that defeats the
  entire point of running this step. This hardened version is committed separately from the
  unrefined baseline(s), so the diff **is** the demonstration of what `--forbid-trap` found.
- Refined-type bounds (`{lo..<hi as base}`) must be spelled as literal integers, the same
  restriction array sizes have (`examples/const_global/const_global.tkb`'s comment) --
  `{0..<TOTAL_SECTORS as usize}` referencing a named `usize` global is a syntax error, even
  when that global has a literal initializer. Only a bare `for`-loop counter over a literal
  range, an `if`-narrowed value, or a literal assigned directly to an explicitly
  refined-typed local reliably carries a provable range across a function-call argument
  boundary -- a global `let`'s own literal initializer does not, by itself, make *reads* of
  that global provably ranged at their use site.

## Design Principle: YAGNI (You Aren't Gonna Need It)

We do not design or build functionality before it is actually needed -- not just at the
implementation level, but at the design/planning level too. This is a durable stance for this
project's current prototype phase (expected to hold for years, not just this session), agreed
between the user and Claude Code, not a one-off preference to be renegotiated each time it comes
up.

- **"Needed" means driven by a real, present requirement**: an actual example that needs it, a
  real bug it fixes, a concrete request in front of us right now. A plausible future need is not
  a present need.
- **When a larger architectural goal would automatically subsume a smaller interim workaround,
  we skip the interim workaround.** Concrete precedent: after the GitHub issue #55 Part (A)
  Makefile migration (see HISTORY.md), a "build the app_main file alone, with no other files on
  the command line" convenience was identified as reachable via a stopgap (tiny per-target entry
  wrapper files that just `use` the right HAL and the shared logic file). It was deliberately
  NOT built: true separate compilation (issue #55's deferred Part B) would make it unnecessary,
  and building it now would be pure throwaway work discarded the moment Part B lands. See that
  HISTORY.md entry, and the outlook memo for Part B, for the reasoning this was checked against.
- **This does not excuse skipping foundational work current features actually depend on.** The
  refinement-type proof machinery is this project's stated core goal (see "Detect Errors at
  Compile Time" above), not speculative scope -- YAGNI applies to optional, deferrable
  convenience/architecture work, not to work the project's own stated purpose already requires.
- **If a request looks like it calls for infrastructure beyond what the current, concrete task
  needs, say so and ask before building it**, rather than defaulting to building the more
  general/future-proof version. The user has explicitly asked for this pushback as a safeguard
  against their own occasional over-ambitious asks -- treat a request that smells speculative as
  a prompt to flag the tradeoff, not as an instruction to quietly build the maximal version.

## Language Specification

**See `SPEC.md` for the current language specification** (types, syntax,
statements, expressions, and semantics as they exist today). This file
(`CLAUDE.md`) is the engineering log: design rationale, bugs found and
fixed, and the chronological "why" behind each decision. When a language
feature changes, update `SPEC.md` directly rather than letting the
description drift between the two files.

## Build Commands

```bash
make build          # build the compiler (takibi) only (= dune build)
make test           # run unit tests
make qemutest       # run QEMU integration tests (build all examples and verify automatically)
make stm32build     # cross-compile every ported example for STM32F746G-DISCOVERY (no hardware needed)
make check          # run langcheck + test + stm32build + qemutest together
make hwcheck        # like stm32build, but also loads into RAM + UART-diffs against real STM32 hardware
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
parallel compiles.

**History: order-only `| build`, then the false-pass bug it caused, now fixed for real.**
Originally every per-example object-file rule depended on the `build` target (`dune build`) as
an **order-only** prerequisite (`| build`, not a plain one) -- `build` is `.PHONY`, and a plain
(non-order-only) phony prerequisite makes every dependent target look permanently out-of-date,
which was silently forcing a full rebuild of all ~50 examples on every invocation before that
was fixed. Order-only prerequisites are still built when needed, but don't affect whether the
depending target itself is considered stale, so make's normal `.tkb`-timestamp-based
skip-if-unchanged logic worked correctly again -- **except** this also meant `make check`
without `make clean` first could give a FALSE PASS for a compiler change that altered
accept/reject behavior or codegen for an EXISTING, unchanged `.tkb` file: its `.o`/`.elf` from a
previous run (built with the OLDER compiler) was never recompiled, since only the `.tkb` file's
own timestamp was consulted, and `| build`'s order-only nature meant $(TAKIBI)'s own freshness
was invisible to that comparison. See "The Undetermined-For-Loop-Counter Case Is Now Also a
Compile Error" below for the concrete incident that surfaced this (a `-k check` run without
`make clean` reported zero failures; `make clean && make check` immediately found 16 affected
files it had silently missed).

**Fixed for real**: every per-example rule's prerequisite list now names `$(TAKIBI)` itself (the
real binary path, `_build/default/bin/main.exe`) as a **normal** (not order-only) prerequisite,
in place of the old `| build`. `$(TAKIBI)`'s own rule forces `dune build` to run on every `make`
invocation that reaches it (via a `FORCE`-based always-out-of-date prerequisite, the standard
make idiom for "always run this recipe"), but **dune's own incremental/content-addressed build
only touches `main.exe`'s mtime when the compiled output genuinely changes** -- confirmed
empirically before relying on it: repeated no-op `dune build` runs, a mtime-only `touch` of a
source file, and even a comment-only source edit all left `main.exe`'s mtime untouched; only a
change that actually alters compiled output (adding/removing/reverting a real binding) updates
it. This is exactly the property needed for the fix to be both safe (no perpetual "every example
always looks stale" regression -- confirmed by running the same target twice in a row with no
change and observing zero rebuild) and correct (a genuine compiler change now correctly cascades
into every example that depends on it, with no separate `make clean` step required -- confirmed
by making a real `bin/main.ml` edit, running `make examples/fibonacci/fibonacci.o` alone with NO
prior clean, and observing both `main.exe` and `fibonacci.o` get fresh mtimes; reverting the edit
and re-running triggers a second real rebuild the same way, and a third run with nothing changed
rebuilds neither). `build:` itself is now just `build: $(TAKIBI)`, an alias -- it no longer calls
`dune build` directly, so **every path in the Makefile that ever needs the compiler fresh now
funnels through this one target**.

**Known dune footgun found while wiring up `-j` (this is exactly why the above funnels through
one target)**: running `dune build` and `dune test` concurrently (e.g. two independent Make
recipes under `make -j`) can corrupt/race on `_build/.lock` ("Unexpected contents of build
directory global lock file"), non-deterministically failing or hanging unrelated recipes. Fixed
by making the `test` target depend on `build` (a normal prerequisite, ensuring `dune build`
always completes before `dune test` starts) and by making sure nothing else in the build graph
calls `dune exec`/`dune build`/`dune test` directly (see `scripts/run_qemutest.sh`'s
`run_compile_error_test`, which had its own independent `dune exec takibi --` call fixed for the
same reason). `$(TAKIBI)`'s rule is now the ONLY place that invokes `dune build` -- if a future
change reintroduces a second, independent `dune build`/`dune test` invocation anywhere in the
`make -j` graph (rather than depending on `$(TAKIBI)`/`build` like everything else does), expect
this same class of flake to come back.

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
  type_layout.ml  -- struct/enum layout table (fields, packed, align) backing sizeof/offsetof (issue #40)
  typechecker.ml  -- external wrapper (called from main.ml)
  llvm_gen.ml     -- LLVM IR generation and object file output
  use_resolver.ml -- resolves `use "path/to/file.tkb";` into the flat file list (issue #55)
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
  common/         -- platform-agnostic .tkb logic with no MMIO/assembly dependency at
                     all, reused byte-for-byte by both targets. Everything
                     target-specific (startup assembly, linker scripts, UART/GIC/timer/
                     network drivers) now lives in common_qemu/ or common_stm32/
                     instead -- see each's own entry below for why this split exists.
    runtime.tkb   -- high-level main wrapper around platform_init/app_main/platform_shutdown
    print.tkb     -- uart_print/uart_println overloaded core (bool + every signed/
                     unsigned width); common_qemu/print.tkb and common_stm32/print.tkb
                     each add only the isize/usize overloads at their own native width
    sync.tkb      -- extern fn sem_wait/sem_post, mutex_lock/unlock, cond_wait/signal
    netutil.tkb   -- bytes_eq/bytes_copy/read_u16be/write_u16be/read_u32be/write_u32be,
                     shared by every protocol example on both targets
    inet_checksum.tkb -- RFC 1071 Internet checksum (checksum_add/checksum_fold),
                     pure compute, no MMIO
    fat12.tkb     -- FAT12 filesystem core (issue #61/#98): fat_format/fat_open/fat_read/
                     fat_write/fat_close over mem_block_read/mem_block_write, which callers
                     (fatfs.tkb's in-memory `disk`, fatfs_sdcard.tkb's/http_server_sdcard.tkb's
                     real SDMMC1 adapter) supply. FatFile is an `affine opaque struct` --
                     see HISTORY.md's issue #97 follow-up entry
  common_qemu/    -- QEMU/AArch64-only HAL: startup assembly, linker script, and every
                     MMIO-backed driver (UART, GIC, timer, virtio-net). Split out from
                     common/ once enough of common/ turned out to be genuinely
                     platform-agnostic (see common/'s own entry above) that a single
                     flat directory no longer made the QEMU-only/shared boundary clear.
    startup.S     -- _start -> main, BSS zero-clear, AArch64 semihosting exit (shared by all examples)
    link.ld       -- linker script (load address 0x40000000) (shared by all examples)
    timer_asm.S   -- ARM Generic Timer stubs: read_cntfrq, set_cntp_tval, enable_cntp, disable_cntp, task_exit_stub
    sem_asm.S     -- atomic semaphore: sem_wait (ldaxr/stxr), sem_post (ldxr/stlxr)
    uart.tkb      -- uart_putc, uart_puts, uart_isr_getc (RX-interrupt byte read, no polling)
    uart_irq_stub.tkb -- no-op uart_set_rx_handler(): QEMU's GIC dispatch is registered
                     directly by echo/irq, so the uniform STM32 UART callback
                     -registration hook (see common_stm32/uart.tkb) has nothing to do here
    print.tkb     -- isize/usize uart_print/uart_println overloads at this target's
                     native 64-bit width (see common/print.tkb above)
    gic_regs.tkb  -- GicRegs struct + the `gic` global only, split out of gic.tkb
                     (GitHub issue #79 follow-up) so a shared file needing just the
                     type (irq.tkb/echo.tkb's dead-on-STM32 irq_dispatch) can `use`
                     it without also pulling in gic.tkb's functions -- see that
                     file's header comment for the cross-file duplicate-definition
                     bug this split fixes
    gic.tkb       -- `use`s gic_regs.tkb; gic_init, gic_enable_timer_ppi,
                     gic_enable_uart_spi, irq_uart_rx_setup/_unmask (uniform names
                     shared with common_stm32/nvic.tkb, see the STM32 section below)
    timer.tkb     -- extern fn timer stubs, setup_task_stack, timer_init (depends on gic.tkb),
                     scheduler_init/_disable/_rearm_tick (uniform names shared with
                     common_stm32/scheduler.tkb, see the STM32 section below)
    rtc.tkb       -- PL031 RTC register access (see "QEMU Bare-Metal" below)
    virtio_mmio.tkb -- net_init/net_rx_acquire/net_rx_frame/net_transmit/net_rx_release/net_read_mac
                     (uniform API shared with common_stm32/eth.tkb, see "STM32 Ethernet" above)
    netconfig.tkb -- OUR_IP (QEMU-side static IP for arp_reply/icmp_echo/tcp_echo),
                     HTTP_SERVER_IP (http_server's own IP, see "Network config" below)
    stm32_stub.tkb -- no-op stand-ins for STM32-only symbols a shared example's dead
                     QEMU-side code still references (see the STM32 section below)
    semihosting_asm.S -- ARM semihosting file-I/O stubs (semihosting_open/write/close/read),
                     used by examples/fatfs to dump its in-memory disk image to a host file
                     for mtools to verify
  common_stm32/   -- STM32F746G-DISCOVERY (Cortex-M7) HAL, mirroring common_qemu's
                     function names/signatures so every example .tkb file is a single
                     file shared by both targets -- see "STM32F746G-DISCOVERY Bare-Metal
                     (Cortex-M7)" below
    startup.S     -- Reset_Handler, vector table, PendSV_Handler, weak
                     SysTick/ETH/pendsv_dispatch stubs; calls only `main`. Flash-execution
                     only -- used solely by examples/http_server/kernel_stm32.elf's rule now
                     (see "STM32 Hardware Test Harness: RAM Execution" below for why every
                     other STM32 example runs from RAM instead, and why this file's AXI
                     SRAM1 MPU window is genuinely cacheable, not the non-cacheable window
                     an earlier version of this file configured)
    link_eth.ld   -- MEMORY {FLASH RAM} linker script (RAM = AXI SRAM, Ethernet DMA can
                     reach it; DTCM cannot). Used only by http_server's Flash build now --
                     see startup.S's entry just above
    startup_ram.S -- RAM-execution Reset_Handler/vector table (no Flash boot dependency;
                     VTOR self-relocation). Used by every STM32 example except
                     http_server's Flash build -- see "STM32 Hardware Test Harness: RAM
                     Execution" below
    link_ram.ld   -- MEMORY {RAM} linker script, AXI SRAM1 (0x20010000, 240K), no Flash
                     region at all -- pairs with startup_ram.S
    uart.tkb      -- uart_init, platform_init/platform_shutdown, ring-buffered
                     TX drained via DMA2 Stream7/Channel4 + completion interrupt
                     (uart_putc/uart_puts -- issue #101), USART1 RX ISR and
                     RX callback registration (PA9/PB7, AF7), uart_isr_getc
    rtc.tkb       -- rtc_init, rtc_is_running, rtc_read_seconds (real RTC peripheral, LSI)
    nvic.tkb      -- enable_usart1_irq, irq_uart_rx_setup/_unmask
    scheduler.tkb -- setup_task_stack, task_exit_stub, systick_init/_disable, pendsv_trigger,
                     scheduler_init/_disable/_rearm_tick (see the STM32 section below)
    sem_asm.S     -- atomic semaphore: sem_wait/sem_post (ldrex/strex/dmb)
    eth.tkb       -- net_init/net_rx_acquire/net_rx_frame/net_transmit/net_rx_release/net_read_mac
                     (real Ethernet MAC/PHY/DMA driver, see "STM32 Ethernet" above)
    eth_sdmmc_regs.tkb -- RCC_AHB1ENR/RCC_APB2ENR/GPIOC_MODER/GPIOC_OSPEEDR, split out of
                     eth.tkb and sdmmc.tkb (issue #97 follow-up) once http_server_sdcard.tkb
                     became the first program to need both HALs and exposed the duplicate --
                     see HISTORY.md
    netconfig.tkb -- OUR_MAC/OUR_IP (STM32 board's fixed network identity),
                     HTTP_SERVER_IP (same value as OUR_IP here, see "Network config" below)
    sdmmc.tkb     -- disk_initialize/disk_status/disk_read/disk_write (real SDMMC1 microSD
                     driver, DMA+interrupt both directions, issue #62)
    semihosting_stub.S -- no-op stand-ins for examples/fatfs's semihosting extern fns on
                     this target (no ARM semihosting on real hardware)
  <name>/         -- each directory: see the leading comment in <name>.tkb for a description.
                     Every example is now a single file compiled for both targets -- no
                     `<name>_stm32.tkb` exists anywhere in this repo (see the STM32 section
                     below for how the hardest cases, irq/preempt/semaphore/condvar/watchdog/
                     msgqueue, got there too).
scripts/
  run_qemutest.sh -- QEMU integration test script (FIFO sync and timing verification included)
  run_hwtest_ram.sh -- STM32 hardware integration test script (make hwcheck): RAM execution
                     over the debug port, no Flash write -- see "STM32 Hardware Test
                     Harness: RAM Execution" below. Supersedes the deleted run_hwtest.sh.
  run_hwtest_net_ram.sh -- STM32 real-Ethernet hardware tests (make hwcheck-net): same RAM
                     execution as run_hwtest_ram.sh, over a genuinely cacheable AXI SRAM1
                     DMA region -- see "STM32 Hardware Test Harness: RAM Execution" below.
                     Supersedes the deleted run_hwtest_net.sh.
  provision_http_server_sdcard.sh -- writes a real mtools-built FAT12 image onto
                     http_server_sdcard's SD card via OpenOCD + the real SDMMC1 driver, no
                     human involved; shared by make hwcheck-net and make stm32-http-server-sdcard
                     (issue #97, see HISTORY.md)
test/
  test_takibi.ml  -- Alcotest unit tests for parser / type_inf
```

## Important Design Notes

Detailed design rationale, per-feature file-change checklists, and the
"why" behind each decision (bugs found, approaches rejected, verification
steps) now live in **HISTORY.md**, not here -- moved out on 2026-07-08 to
keep this file under Claude Code's context budget (it had grown past
150k characters). Read HISTORY.md when you need to understand why
something is built the way it is, or which files a similar future change
should touch. When a change touches an area HISTORY.md documents, append
a new dated entry there rather than growing this file back to its old
size.

## Known Limitations / Deferred Design Decisions

- **`interrupt_wait`/`interrupt_notify` currently support ARM/AArch64 only.**
  They use the retained-event `wfe`/`sev` pair, which closes the
  check-then-sleep race. AMD64 and RISC-V code generation deliberately rejects
  these builtins until an equally race-free wake protocol (not a bare `hlt` or
  `wfi`) is designed with the interrupt controller/runtime.
- **Hardware bring-up waits still need bounded timeouts.** STM32 MDIO busy,
  MAC software reset, PHY reset/autonegotiation, and RTC initialization poll
  status bits during startup. These are not steady-state CPU-spin paths and
  generally have no useful completion IRQ, but a disconnected or failed device
  can currently block forever. Add a monotonic deadline and actionable error
  return before growing the driver set.
- **Platform lifecycle composition is intentionally minimal.** The shared
  high-level `main` calls `platform_init`, `app_main`, and `platform_shutdown`;
  QEMU hooks are empty and STM32 hooks currently own UART setup/drain. When a
  second always-on platform service needs lifecycle work, introduce an explicit
  platform runtime module that composes drivers rather than making UART depend
  on unrelated devices. Integer return values from `app_main` are currently
  ignored because both bare-metal exits use a fixed success status.
- **TX APIs are synchronous despite interrupt-driven completion.** Network TX
  sleeps rather than spins, but retains the caller until DMA completion. Fully
  asynchronous TX needs an affine `NetTxInFlight` handle (or equivalent buffer
  ownership token) before callers may safely reuse memory.
- **Function overloading uses exact parameter types.** Same-named functions are collected as overload sets and
  emitted under `_TK_<name>__<type-codes>` linkage names. Calls perform no implicit conversion or ranking. An
  unconstrained integer literal therefore makes an overloaded call an error; annotate it or use `as T`. Overloaded
  functions used as bare function-pointer values are rejected until an expected-type-based selector is added.
  `extern fn` is deliberately not overloadable because its unmangled symbol name is an external ABI contract.
  DWARF records the source name as `name` and the mangled symbol as `linkageName`, so source-level debuggers display
  the original overload name while `nm`/linkers see unique symbols.
- **Every top-level definition (`fn`, global `let`, `struct`, `opaque struct`, `enum`) shares ONE flat namespace,
  and any duplicate/cross-kind collision is a compile error (GitHub issue #79 follow-up)**: two functions with the
  identical name+parameter-signature (not a valid overload), two globals/structs/enums sharing a name, and any
  cross-kind collision (a `struct` and a `fn`, an `enum` and a global `let`, an `opaque struct` and a concrete
  `struct`, etc.) are all rejected, regardless of which file(s) they come from or which one is defined first.
  Implemented as one shared mechanism, `claim_toplevel_name` (a single pass over the whole program, run before
  `senv`/`eenv`/`fenv`/`genv` exist), not a separate ad-hoc check per kind -- deliberately consolidated after the
  third of what would have been five near-identical one-off checks. This closes a real gap found while auditing
  the `use`-based Makefile migration: two DIFFERENT files defining the same function signature used to compile
  silently (`llvm_gen.ml`'s Pass 1 `declare_func` only registers the first occurrence per key; Pass 2 `gen_func`
  then unconditionally appends a second, unreachable "entry" block onto that same llvalue for every later
  occurrence -- valid LLVM IR, so the verifier never complains), with whichever definition happened to come first
  in file-concatenation order silently winning and the other silently dead-coded. Found in practice:
  `examples/common_qemu/gic.tkb` and `examples/common_stm32/nvic.tkb` both defining
  `irq_uart_rx_setup`/`irq_uart_rx_unmask` under the same STM32 build of `examples/irq/irq.tkb`/`examples/echo/
  echo.tkb` (fixed by splitting the `GicRegs` struct out into `examples/common_qemu/gic_regs.tkb`, `use`d
  unconditionally, from `gic.tkb`'s actual functions, which only the QEMU build still needs) -- and separately,
  `examples/tcp_echo/tcp_echo.tkb`/`examples/http_server/http_server.tkb` redeclaring their own hardcoded
  `IP_TOTAL_LEN`/`TCP_*`/`ARP_*` offset constants, silently redundant with `examples/common/netutil.tkb`'s
  `offsetof`-based versions of the same names ever since issue #77's refactor added them there (fixed by deleting
  the redundant blocks). The struct/enum extension itself was purely latent -- no existing example had this
  collision. See HISTORY.md's issue #79 follow-up entries for the full investigation, including a comparison of
  how C (separate tag namespace), Rust (separate type/value namespaces), and Zig (one flat namespace per scope,
  types are ordinary compile-time values -- the closest existing analogue to takibi's own model here) each handle
  this, discussed with the user before implementing. LOCAL (function-body-scoped) namespacing is explicitly left
  open/undecided -- moot today since takibi has no local `struct`/`enum`/`fn` definitions, only local `let`; a
  real module/namespace system is likewise out of scope until actually needed.
- **Primitive UART decimal printing is overloaded.** `uart_print` and `uart_println` accept `bool` and every signed
  or unsigned primitive integer width, including `isize`/`usize`. Narrow types share 32-bit conversion cores and
  wide types share 64-bit cores; signed minimum values are converted through unsigned subtraction to avoid
  overflow. The old decimal-print helper names (`uart_print_int`, `uart_print_uint`, and their `println` variants)
  have been removed from the examples; use the overloaded entry points instead.
- **`isize` (signed pointer-sized integer) is implemented** -- it is the pointer-sized signed integer used for raw
  pointer arithmetic and pointer differences (`ptr - ptr` returns `isize`).
- **A scoped form of refinement-type inference is implemented (GitHub issue #72)**: a bare `x as <base>` cast (no
  explicit `{lo..<hi as base}` range) now infers the tightest refined type on its own whenever `x`'s range is
  already known (via if-narrowing, an exact-match refined parameter, Mul/Add/Sub propagation, etc.) and fits the
  target base -- e.g. `ihl as usize` behaves exactly like the old `ihl as {20..<21 as usize}` when `ihl` is already
  `{20..<21 as u16}`. This is deliberately NOT general "never write a refinement type again" inference (that
  problem is undecidable without SMT-scale machinery even in mature systems like Liquid Haskell/F*, which still
  require explicit boundary annotations) -- it only ever widens what an already-provable cast can skip restating.
  Function PARAMETER and RETURN types, and global `let` declarations, are function/module BOUNDARIES and still
  require an explicit annotation; this was a deliberate scope decision, not a gap (see HISTORY.md's issue #72
  entry for the audit of examples/'s actual annotation burden that motivated scoping it this way -- roughly half
  of every explicit refinement-type annotation across `examples/` turned out to be this exact "restate an
  already-known range across a base change" pattern, and the other half was boundary annotations inference
  can't help with regardless of implementation effort). A cast whose source range does NOT fit the target base
  (a genuine narrowing/truncating cast) is unaffected -- falls back to exactly today's plain-unrefined-target
  behavior, same as before this feature existed.
- **`sizeof(T)` cannot be used as an array size** (`[T; sizeof(Foo)]`) -- see HISTORY.md's "sizeof(T) Spans 4 Files"
  entry for why (parser-time vs. codegen-time resolution mismatch) and what combining them would require.
- **Lightweight `use "path/to/file.tkb";` file dependencies are implemented (GitHub issue #55)** -- a `.tkb` file
  can now declare, in source, which other files it needs; `bin/main.ml` resolves the transitive closure starting
  from the command-line entry file(s) (`lib/use_resolver.ml`) instead of requiring every needed file to be named
  explicitly. This directly targets the class of mistake that motivated it (see the historical incident below,
  from before this feature existed): a helper referencing a symbol from a file never `use`d is now caught the
  first time the referencing file is compiled at all, not only when some unrelated Makefile target's hand-curated
  file list happens to expose the gap. The ~40 existing Makefile rules now rely on `use` declarations inside each
  `.tkb` file for every dependency that has a single path valid on both targets (gic.tkb, sync.tkb,
  inet_checksum.tkb, netutil.tkb, virtio_mmio.tkb's own gic.tkb need, eth.tkb's own netutil.tkb/netconfig.tkb/
  nvic.tkb needs); Makefile recipes keep those files as prerequisites (for staleness tracking, since Make cannot
  see into a `.tkb` file's own `use` declarations) but no longer pass them on the takibi command line. Files with
  no single path valid for both targets (uart.tkb, print.tkb's per-target half, timer.tkb/scheduler.tkb, rtc.tkb,
  uart_irq_stub.tkb, netconfig.tkb) remain Makefile-curated, since a shared example file cannot `use` a
  target-specific path without breaking the other target. See HISTORY.md's issue #55 Makefile-migration entry for
  the full per-file reasoning. **What this deliberately is NOT**: real separate compilation (each
  `.tkb` compiled to its own object file, linked by `ld.lld`). Every file in the resolved closure is still
  concatenated into one flat AST and type-checked/codegen'd as a single whole-program unit, exactly as before --
  `use` only changes how the FILE LIST is computed, not the compilation model itself. See HISTORY.md's issue #55
  entries for the full design (why real separate compilation is a much larger, deliberately-deferred undertaking
  given this project's whole-program refinement-type proof machinery, and the outlook memo written for that
  issue).

  **Historical incident that first exposed the gap** (from before this feature existed, kept here for context):
  while removing `irq.tkb`'s `IS_QEMU` branch, a new helper function was first placed in `uart.tkb` (concatenated
  into literally every example) even though its body called `gic_init()`/`enable_usart1_irq()`, symbols that only
  exist in a handful of builds -- this silently broke unrelated examples like `start` with an "Undefined function"
  error, not caught until `make stm32build` was re-run over the whole example set. Ended up moving the functions
  into `gic.tkb`/`nvic.tkb` instead (already only included where those symbols exist) -- `use` would not have
  prevented the underlying design mistake (putting a GIC-specific helper in a file every example shares), only
  made the resulting undefined-symbol error appear immediately when `uart.tkb` itself was next compiled, rather
  than only when a later, unrelated Makefile target happened to expose it.
- **DMA/device memory-barrier builtins are implemented** -- the STM32 Ethernet DMA bring-up needed a `dsb` instruction between a
  descriptor-ring write and the "poll demand" register kick, because `*io` volatile writes alone don't guarantee the
  CPU's write buffer has retired before a subsequent register write reaches the DMA engine (see the "Hardware
  bring-up bug worth knowing about" paragraph under the STM32 Ethernet section below -- found only via live
  openocd/gdb-multiarch debugging on real hardware, not something the compiler flagged). The original handwritten
  `extern fn eth_dsb()`/`eth_asm.S` workaround has been removed. `dma_publish()`, `dma_consume()`, and
  `device_fence()` now lower per target and are placed inside the STM32 and virtio driver ownership transitions.
  The cache-aware `dma_prepare_tx`/`dma_prepare_rx`/`dma_finish_rx` operations maintain Cortex-M7 cache lines,
  so application examples do not manually select barriers. The RX API now uses an affine opaque CPU-ownership
  handle to reject use-after-release and double-release statically without changing the source-level barrier semantics.
- **QEMU (TCG mode, which is all this project uses -- no KVM) does not model caches as physically separate storage
  from RAM, so cache-coherency bugs are invisible there and can ONLY be found on real hardware.** Found again
  while bringing up `examples/fatfs` on the STM32 board: the hardware test harness injects/extracts the `disk`
  array's live RAM directly over the debug port with OpenOCD (`load_image`/`dump_image`), which -- like a real DMA
  engine -- bypasses the CPU's D-cache entirely; without an explicit `dma_finish_rx`/`dma_prepare_tx` around that
  boundary, the CPU could read stale cached data (or the debugger could dump stale un-flushed RAM) despite the
  exact same test passing cleanly under QEMU every time, because QEMU's single unified memory model has no cache
  to go stale in the first place. Same reasoning applies to any future genuinely concurrent hardware feature
  (multi-core, issue #6, still Backlog): a missing memory barrier or cache-maintenance op between cores can look
  perfectly correct in QEMU and fail only on real silicon, so that kind of work should get real-hardware
  integration testing early, not just as a final check once "everything already works in QEMU."
- **STM32 Ethernet: five examples are ported -- `net_echo`, `arp_reply`, `icmp_echo`, `tcp_echo`,
  and `http_server` all run on real hardware with real MAC/PHY/DMA, and are the *same source file* as
  their QEMU/virtio-net counterparts.** `examples/common_stm32/eth.tkb` is a from-scratch MAC/DMA-
  descriptor-ring driver + MDIO-based LAN8742A PHY init over RMII (RMII pins, PHY bring-up, and the DMA
  descriptor ring design are documented in that file's header comment). A sixth, `http_server_sdcard`
  (GitHub issue #97, see HISTORY.md for the full milestone), also uses `eth.tkb` but is STM32-only (no
  QEMU counterpart, since it also needs the real SD card).

  **Unified driver API**: `eth.tkb` and `examples/common_qemu/virtio_mmio.tkb` both expose the identical
  `net_init() -> i32` / `net_rx_wait()` / `net_rx_acquire() -> *NetRxCpuOwned` /
  `net_rx_len(borrow *NetRxCpuOwned) -> i32` /
  `net_rx_frame(borrow *NetRxCpuOwned) -> [u8; 1514..]` / `net_transmit(buf, len)` /
  `net_rx_release(*NetRxCpuOwned)` / `net_read_mac(mac_out)` functions -- mirroring how `uart.tkb`/`print.tkb` already
  share identical signatures across `examples/common/` and `examples/common_stm32/`. This means
  `examples/net_echo/net_echo.tkb` (and the other four) are a *single* file compiled against either
  backend depending on target, not a QEMU version plus a hand-maintained `_stm32.tkb` copy -- see that
  file's header comment. Descriptor rings, RX/TX buffers, and virtio's 10-byte `virtio_net_hdr` framing
  are all hidden inside each backend; application code never sees them. Both backends are interrupt-driven:
  STM32 vectors IRQ61 directly to `ETH_IRQHandler`, while virtio discovers its SPI from the MMIO slot and
  dispatches through GICv2. ISRs acknowledge, set `io` flags, and issue `interrupt_notify()`; normal
  context uses `interrupt_wait()` instead of spinning while idle. Used-ring/descriptor inspection,
  cache maintenance, affine-handle creation, and packet processing remain in normal context.

  **Network config**: `examples/common_stm32/netconfig.tkb` holds the board's MAC/IP as plain global
  constants (`OUR_MAC`/`OUR_IP`/`HTTP_SERVER_IP`, array-literal `{...}` initializers). MAC is a fixed
  `00:80:E1:00:00:00`, matching ST's own STM32CubeF7 LwIP example convention (hardcoded, not derived from
  the chip's unique ID -- see that file's comment for the tradeoff). IP is `192.168.10.2`, the same /24 as
  this devcontainer's point-to-point NIC (`enp4s0`, `192.168.10.1/24`), chosen so the board is reachable
  with zero host-side routing changes. `examples/common_qemu/netconfig.tkb` holds the QEMU-side counterpart:
  `OUR_IP` = `192.0.2.1` (RFC 5737 TEST-NET-1) for `arp_reply`/`icmp_echo`/`tcp_echo` (MAC is deliberately
  NOT in this file -- `net_read_mac()`'s virtio-net backend reads it from the device at runtime, nothing to
  share). `http_server.tkb` reads a third constant, `HTTP_SERVER_IP`, instead of `OUR_IP`: on the QEMU side
  this is `10.0.2.15` (SLIRP's fixed `-netdev user` guest address, needed for `hostfwd` to route a real
  browser's connection to the guest at all -- see that file's header comment), while on the STM32 side it's
  simply the same value as `OUR_IP` (no SLIRP-style constraint on real hardware). Both `netconfig.tkb` files
  define the same two variable names (`OUR_IP`, `HTTP_SERVER_IP`) for consistency, even though the STM32
  side's `HTTP_SERVER_IP` is a duplicate of its own `OUR_IP`. This lets every example's `app_main()` do a single
  unconditional `bytes_copy` from the constant it needs, with no runtime branch at all (see the STM32
  section below for `irq.tkb`'s GIC-vs-NVIC enable sequence, which eliminated its own runtime branch the
  same way -- a per-target pair of definitions behind one uniform name).

  All five are verified against a real point-to-point link via `scripts/eth_*_test.py` + `make hwcheck-net`
  (not part of `make check`/`make hwcheck` since it needs a real board wired directly to the test machine's
  NIC, plus `CAP_NET_RAW`). `make hwcheck-net` aggregates all such Ethernet hardware tests via
  `scripts/run_hwtest_net_ram.sh`, same PASS/FAIL-summary style as `scripts/run_hwtest_ram.sh` -- add new
  Ethernet examples there as they're ported (one `run_net_hw_test NAME ELF TEST_SCRIPT` line), rather than
  each getting its own separate `make` target.

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

  STM32 startup configures MPU region 0 for `0x20010000..<0x20020000` as Normal, non-cacheable,
  shareable memory before enabling the Cortex-M7 I-cache and D-cache. Ethernet images are linked at
  `0x20010000`; `link_eth.ld` asserts that their data plus stack remain inside this 64KB window so future
  growth cannot silently place DMA-visible globals in cacheable AXI SRAM. Descriptors remain padded/aligned
  to one 32-byte cache line and RX/TX ownership transitions retain explicit cache-maintenance builtins and
  barriers, keeping the driver contract valid if its placement strategy changes later.

  **Hardware bring-up bug worth knowing about**: the very first working version had every DMA descriptor field
  byte-for-byte correct (verified live via openocd/gdb-multiarch register+memory dumps) yet the TX descriptor's
  OWN bit would never clear -- the DMA engine simply never acted on it. Root cause: writing the descriptor
  fields (AXI SRAM) and then immediately poking the "poll demand" register (a different peripheral) has no
  ordering guarantee on Cortex-M7 -- `*io` writes in takibi are volatile (the compiler won't reorder/drop them)
  but that says nothing about the CPU's write buffer having actually retired the SRAM write before the very next
  store lands, so the DMA engine could race ahead and read a stale (OWN=0) descriptor. Confirmed by re-issuing
  the poll-demand write by hand through the debugger after enough time had passed for the earlier write to
  settle -- the descriptor completed instantly. Fixed originally with a handwritten `dsb`, now replaced by the
  compiler builtin `dma_publish()` between descriptor writes and poll-demand kicks. Completion paths use
  `dma_consume()` before CPU access to device-written descriptors/buffers. These calls stay inside driver APIs;
  volatile alone is not enough for DMA ownership transfer.

  TX interrupt-driven completion also requires `TDES0.IC` (bit 30) on every submitted descriptor. Enabling
  `DMAIER.TIE` alone is insufficient: without IC the DMA clears OWN after transmitting but emits no normal TX
  completion interrupt, leaving a flag-based waiter blocked forever. The waiter treats the interrupt as a wakeup
  and still verifies that OWN has cleared after acquiring the descriptor; the notification itself is not used as
  proof of ownership.

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

Real-hardware port, running alongside (not replacing) the QEMU/AArch64 build. Nearly every
example is now ported (55 as of this writing, per `Makefile`'s `STM32_RAM_ELFS` -- check
that variable directly rather than trusting this number, since it drifts as examples are
added; this project has a history of this exact count going stale), including
`net_echo`/`arp_reply`/`icmp_echo`/`tcp_echo`/
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
block-device majors were never added to the allowlist. `scripts/run_hwtest_ram.sh`'s
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
stm32build` links every ported example as a RAM-execution image (no hardware needed,
part of `make check`); `make hwcheck` additionally loads and verifies each one against
the real board over the debug port (not part of `make check` -- needs physical
hardware). The one exception is `examples/http_server`, which also gets a Flash-resident
build (`examples/http_server/kernel_stm32.elf`/`.bin`) so `make stm32-http-server` can
flash a demo unit that boots the HTTP server standalone from power-on with no debugger
attached -- see "STM32 Hardware Test Harness: RAM Execution" below for why RAM execution
is the default for everything else, and why even this one Flash build's AXI SRAM1 DMA
region is genuinely cacheable now, not the non-cacheable window an earlier version of
this project used.

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
(`examples/common_qemu/startup.S`'s `irq_entry`); STM32's is `USART1_IRQHandler()` (`irq`) or
`SysTick_Handler()` + `pendsv_dispatch(sp) -> sp` (the other five), vectored directly by
`examples/common_stm32/startup.S`'s hardware vector table. The fix: define **both**
platforms' entry points unconditionally in the one shared file (`examples/preempt/
preempt.tkb`'s header comment has the full reasoning) -- whichever one isn't relevant to
the target being built is simply dead code there, same idea as `OUR_MAC` sitting unused
in `net_echo`'s STM32 binary. Three small pieces of shared infrastructure make both
definitions actually *compile* on both targets:
- **`scheduler_init()`/`scheduler_disable()`/`scheduler_rearm_tick()`** (uniform names,
  real implementations in both `examples/common_qemu/timer.tkb` and `examples/common_stm32/
  scheduler.tkb`) hide the one genuine naming/arity mismatch found: STM32's
  `systick_init()` needs an explicit reload value `timer_init()` has no parameter for,
  and the ARM Generic Timer needs re-arming every tick where SysTick auto-reloads and
  doesn't. `app_main()` calls these three uniformly, no per-platform branch needed for any
  of it. (The `249999` reload value used to be duplicated at every STM32 example's call
  site; hoisting it into `scheduler_init()` removed that too.)
- **`examples/common_qemu/stm32_stub.tkb`** (QEMU-only): a no-op stand-in for
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
  implementations in `examples/common_qemu/gic.tkb` and `examples/common_stm32/nvic.tkb`
  (not `uart.tkb`, even though they're UART-interrupt related: `uart.tkb` is
  concatenated into *every* example's build, including ones that never touch GIC/NVIC
  at all, so a function defined there calling `gic_init()`/`enable_usart1_irq()` would
  fail to resolve on those other builds; `gic.tkb`/`nvic.tkb` are only ever included
  where those symbols already exist). `app_main()` calls both uniformly with no branch, and
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
startup.S`'s vector table, covering core exceptions through Ethernet IRQ61) -- no software
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

**Hardware test harness: Flash execution** (historical -- both hardware test targets have
since moved to RAM execution, see below; this describes the now-deleted `scripts/
run_hwtest.sh` and `scripts/run_hwtest_net.sh`, formerly `make hwcheck`'s and
`make hwcheck-net`'s implementations): flashed via `st-flash write` and captured UART output, diffing
against the *same* `.expected` files `run_qemutest.sh` already uses (`uart_puts`/
`uart_print_*` write identical bytes on either HAL). Two things had to be solved that
QEMU's semihosting-exit model doesn't need to deal with:
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

**Hardware test harness: RAM execution** (`scripts/run_hwtest_ram.sh` + `scripts/
run_hwtest_net_ram.sh`, `make hwcheck` + `make hwcheck-net`, current implementation for
both): every one of hwcheck's ~41 example binaries is well under Flash
Sector0's 32KB, so flashing all of them on every run used to erase/write that one physical
sector 41 times per run -- against a guaranteed minimum endurance of roughly 10,000 erase
cycles, only ~200 `make hwcheck` runs before Sector0's guaranteed lifetime is exhausted, a
real concern once hwcheck starts running frequently in CI (not yet, but planned). Migrated
to loading the linked ELF directly into AXI SRAM1 (0x20010000, 240K, NOT DTCM -- see below)
over the debug port via OpenOCD instead: `reset halt` (never `reset init`, which would
reprogram the clock tree away from the 16MHz HSI every `uart_init()` assumes), `load_image`
the ELF, then read the initial SP/PC out of word 0/word 1 of the image's own vector table
and poke them into the SP/PC debug registers by hand before resuming -- manually doing, once
per test, exactly what silicon does automatically when booting from Flash. No Flash write
happens anywhere in this path. See `examples/common_stm32/startup_ram.S`'s header comment
for the full mechanism (including why VTOR must be set in code, not by the harness) and
HISTORY.md's RAM-execution entry for the full design discussion (why AXI SRAM1 over DTCM,
why no explicit MPU region is needed, and the flash-endurance arithmetic).

**`hwcheck-net`'s 5 real-Ethernet examples migrated too, with one deliberate difference
from every other example: their DMA descriptor rings and packet buffers are genuinely
cacheable.** `link_ram.ld` gives them the same uniform AXI SRAM1 as everything else -- no
MPU non-cacheable window. This makes `examples/common_stm32/eth.tkb`'s existing
`dma_prepare_tx`/`dma_prepare_rx`/`dma_finish_rx` calls load-bearing for the first time --
previously the non-cacheable window meant those calls' cache clean/invalidate instructions
were architectural no-ops. Validated against real hardware over the wired point-to-point
link (`make hwcheck-net`, all 5 examples, including varying frame payload sizes 46-1486
bytes and a full TCP handshake/data-echo/close/reconnect cycle) before generalizing, not
just reasoned about from reading the driver -- see HISTORY.md's RAM-execution entries for
the full code-reading pass that preceded this and why it was judged safe in advance.

**Follow-up: `stm32build` itself (not just the hardware test targets) consolidated onto
RAM execution too, with one deliberate exception.** Every STM32 example except
`examples/http_server` dropped its Flash build entirely -- `stm32build` now IS what used
to be a separate `stm32build-ram` target, and there is no more `link.ld` (deleted) or
per-example Flash `kernel_stm32.elf`/`.bin` for anything but http_server. http_server kept
its own explicit Flash build rule (`examples/http_server/kernel_stm32.elf`/`.bin` -- NOT a
`stm32build` prerequisite; built on demand by `make stm32-http-server` and, since the
follow-up below, by `make hwcheck-net` too) specifically so a demo unit can boot the HTTP
server standalone from power-on with no debugger attached -- RAM execution cannot do this
at all, since AXI SRAM1 loses its contents the moment power is removed.
`examples/common_stm32/startup.S`'s AXI SRAM1 MPU window was changed the same way as the
RAM-execution path (non-cacheable window removed, relying on the same ARMv7-M default map)
so this one remaining Flash build uses the identical cache policy as everything else --
verified with a genuine `st-flash write` + `st-flash reset` (not the debugger
halt-and-poke `--connect-under-reset` sequence hwcheck-net's own validation used) followed
by the real HTTP test script, confirming the standalone, non-debugger-mediated boot path
specifically, not just the debugger-mediated one. See HISTORY.md's RAM-execution entries
for the full reasoning behind keeping exactly this one exception and nothing more.

**Follow-up: that Flash-boot verification turned into a permanent, automated test, not a
one-off manual check.** Once every other example moved off Flash entirely, http_server's
Flash build became the ONLY Flash-execution boot path anywhere in this repository -- and
a real hardware boot-vector fetch from address 0x0 (silicon reading SP/PC from Flash
directly) is a genuinely different code path from every hardware test elsewhere in this
project, all of which use OpenOCD's `reset halt` + debugger register poke instead. With
every other example's Flash build gone, nothing would have caught a regression specific
to that boot path (or to this Flash build's now-cacheable AXI SRAM1 MPU change) until
someone happened to run `make stm32-http-server` by hand. `scripts/run_hwtest_net_ram.sh`
now runs http_server TWICE: `http_server (stm32/ram)` (unchanged) and a new
`http_server (stm32/flash)`, which does a genuine `st-flash write` + `st-flash reset` of
`examples/http_server/kernel_stm32.bin` (the exact sequence `make stm32-http-server`
itself performs, `--connect-under-reset` included) before running the same
`eth_http_server_test.py`. `hwcheck-net`'s own prerequisites gained
`examples/http_server/kernel_stm32.bin` accordingly. Confirmed on real hardware: all
`hwcheck-net` tests pass at the time (6 then; more have been added since, e.g.
`http_server_sdcard`'s own RAM+Flash pair -- see HISTORY.md), adding only ~2s to the
suite's total runtime.

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
  (`virtio_net_find()` in `examples/common_qemu/virtio_mmio.tkb`). A lone
  `-device virtio-net-device` does NOT land on slot 0: empirically, under
  this devcontainer's QEMU 8.2.2, it landed on slot 31 (base `0x0a003e00`).
  The driver scans all 32 slots for `DeviceID == 1` (network), derives both
  its base address and GIC SPI, routes that SPI to CPU0, and acknowledges
  legacy queue interrupts inside the driver-owned IRQ dispatcher.
- **The vring uses typed views over one shared backing allocation.**
  `VirtqDesc`, `VirtqAvail`, `VirtqUsed`, and `VirtqUsedElem` describe the
  specification-defined layouts. Descriptor writes use `descs[i].field`,
  while `sizeof(VirtqDesc)` and `offsetof(..., ring)` locate the avail/used
  subregions without duplicating byte offsets. The used-ring views are `*io`
  so device-written fields remain volatile. The page-aligned byte arrays are
  still the owning storage because all three regions must share one legacy
  virtqueue allocation.
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
- **Used-ring reads must be `io`.** `used_idx_get` etc. read memory the device
  writes via DMA. An interrupt is only a notification, so normal context
  re-checks the used ring after `interrupt_wait()` wakes. Volatile access
  prevents LLVM from caching or hoisting these externally modified loads.
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
  in that order (`app_main()`'s `ok4 = ok3 and test_data_echo()` chain). Each
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
the bit pattern regardless of sign, not decimal `uart_print`) and harmless
for the modular arithmetic TCP sequence
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
approach as `print.tkb`'s unsigned decimal core, targeting a buffer). Needed
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
ordering reasoning as `read_until_quiet`'s `WAIT_FOR_DATA` case in `scripts/run_hwtest_ram.sh`.
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
- **Follow YAGNI (see "Design Principle: YAGNI" above).** Do not design or implement functionality beyond what the current, concrete task needs. If a request seems to call for more than that, flag the tradeoff and ask before building it.
- **New `.tkb` code under `examples/`: get the whole milestone working without refinement types/`--forbid-trap` first, commit each working piece as a baseline, then turn `--forbid-trap` on once the milestone is done and fix only what it flags** (see "Development Process: Prove New `.tkb` Code Without `--forbid-trap` First, Then Turn It On" above -- e.g. `fatfs` + its real SD card integration are one milestone; don't harden `fatfs` alone partway through). Do not skip straight to a `--forbid-trap`-clean version, and do not "fix" a flagged site by switching it to a raw pointer.
- **Proactively write English summaries of chat decisions/design rationale to the relevant GitHub issue.** The chat itself is in Japanese, but this repository's issues must stay English-only -- `gh` now has write access (`gh issue comment` / `gh issue create`, see `.claude/settings.json`), and a `PreToolUse` hook (`.claude/hooks/gh-issue-ascii-only.sh`) blocks any of those two commands whose text contains non-ASCII characters, so the summary must already be in English before the command is run. This takes over a task the user previously did by hand (translating chat discussion and posting it to issues themselves) -- do it without being asked, once a decision, design tradeoff, or root-cause conclusion has actually been reached in the conversation, not after every message. Infer the target issue from context (a number mentioned in the recent chat, a commit message, `git log`); if none is evident, ask rather than guessing or opening a new issue unprompted.

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
