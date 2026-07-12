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
                     -g emits DWARF debug info -- see the `profile-qemu` skill for the full profiling workflow.
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
                     shared with common_stm32/nvic.tkb, see examples/common_stm32/CLAUDE.md)
    timer.tkb     -- extern fn timer stubs, setup_task_stack, timer_init (depends on gic.tkb),
                     scheduler_init/_disable/_rearm_tick (uniform names shared with
                     common_stm32/scheduler.tkb, see examples/common_stm32/CLAUDE.md)
    rtc.tkb       -- PL031 RTC register access (see examples/common_qemu/CLAUDE.md)
    virtio_mmio.tkb -- net_init/net_rx_acquire/net_rx_frame/net_transmit/net_rx_release/net_read_mac
                     (uniform API shared with common_stm32/eth.tkb, see examples/common_stm32/CLAUDE.md)
    netconfig.tkb -- OUR_IP (QEMU-side static IP for arp_reply/icmp_echo/tcp_echo),
                     HTTP_SERVER_IP (http_server's own IP, see examples/common_stm32/CLAUDE.md's "Network config" entry)
    stm32_stub.tkb -- no-op stand-ins for STM32-only symbols a shared example's dead
                     QEMU-side code still references (see examples/common_stm32/CLAUDE.md)
    semihosting_asm.S -- ARM semihosting file-I/O stubs (semihosting_open/write/close/read),
                     used by examples/fatfs to dump its in-memory disk image to a host file
                     for mtools to verify
  common_stm32/   -- STM32F746G-DISCOVERY (Cortex-M7) HAL, mirroring common_qemu's
                     function names/signatures so every example .tkb file is a single
                     file shared by both targets -- see examples/common_stm32/CLAUDE.md
                     for the full bring-up/scheduler/Ethernet design
    startup.S     -- Reset_Handler, vector table, PendSV_Handler, weak
                     SysTick/ETH/pendsv_dispatch stubs; calls only `main`. Flash-execution
                     only -- used solely by examples/http_server/kernel_stm32.elf's rule now
                     (see examples/common_stm32/CLAUDE.md's "STM32 Hardware Test Harness: RAM Execution" entry for why every
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
                     scheduler_init/_disable/_rearm_tick (see examples/common_stm32/CLAUDE.md)
    sem_asm.S     -- atomic semaphore: sem_wait/sem_post (ldrex/strex/dmb)
    eth.tkb       -- net_init/net_rx_acquire/net_rx_frame/net_transmit/net_rx_release/net_read_mac
                     (real Ethernet MAC/PHY/DMA driver, see examples/common_stm32/CLAUDE.md)
    eth_sdmmc_regs.tkb -- RCC_AHB1ENR/RCC_APB2ENR/GPIOC_MODER/GPIOC_OSPEEDR, split out of
                     eth.tkb and sdmmc.tkb (issue #97 follow-up) once http_server_sdcard.tkb
                     became the first program to need both HALs and exposed the duplicate --
                     see HISTORY.md
    netconfig.tkb -- OUR_MAC/OUR_IP (STM32 board's fixed network identity),
                     HTTP_SERVER_IP (same value as OUR_IP here, see examples/common_stm32/CLAUDE.md's "Network config" entry)
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
                     DMA region -- see examples/common_stm32/CLAUDE.md's "STM32 Hardware Test Harness: RAM Execution" entry.
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
  bring-up bug worth knowing about" paragraph in examples/common_stm32/CLAUDE.md's STM32 Ethernet entry -- found only via live
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
- **STM32 Ethernet driver details** (unified driver API, network config, the DMA-ordering hardware bug, TX interrupt completion) -- see `examples/common_stm32/CLAUDE.md`.

## QEMU Bare-Metal (AArch64)

QEMU/AArch64 bare-metal HAL reference (machine/CPU, PL011 UART and PL031
RTC register addresses, semihosting exit, GICv2, ARM Generic Timer) now
lives in **`examples/common_qemu/CLAUDE.md`** -- Claude Code loads that
file automatically whenever a file under `examples/common_qemu/` is read,
so it costs nothing in sessions that never touch QEMU-specific code.

## STM32F746G-DISCOVERY Bare-Metal (Cortex-M7)

STM32 Cortex-M7 bring-up (devcontainer/USB setup, build model,
USART1/RTC/NVIC details), the SysTick+PendSV preemptive scheduler, the
Ethernet MAC/PHY/DMA driver, and the RAM-execution hardware test harness
now live in **`examples/common_stm32/CLAUDE.md`** -- Claude Code loads
that file automatically whenever a file under `examples/common_stm32/`
is read.

## virtio-net Examples (examples/net_echo, examples/arp_reply, examples/icmp_echo)

QEMU-only stepping stones toward the TCP/IP stack goal (raw frame echo,
ARP reply, ICMP echo) built on the same virtqueue/DMA/IRQ plumbing.
Implementation details (legacy virtio-mmio, vring layout, endianness
handling, test harness) now live in **`examples/common_qemu/CLAUDE.md`**.

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

DWARF debug-info emission and the gdbstub-based sampling profiler --
including the finding that this technique only works for CPU-bound code,
not network/interrupt-driven I/O -- now live in the **`profile-qemu`**
skill. Invoke that skill rather than reading the details here.

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
