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

The TCP/IP stack + bare-metal HTTP server was the first waypoint on the way there, and is
already implemented and running on QEMU/AArch64 and STM32F746G-DISCOVERY -- see the target
sections below. It exists to prove takibi can express real, nontrivial systems code at all; the
harder, ongoing work is proving that code's runtime-error surface can be pushed to compile time,
which the `--forbid-trap` refinement-type work and the Takibi Core ownership slices are the
first concrete steps toward, on the way to expressing Unix-like kernel constructs (schedulers,
virtual memory, drivers, syscall boundaries) with the same discipline.

**Looking for the current language syntax/grammar (types, statements, expressions)?
See `SPEC.md`.** This file is the engineering log -- design rationale, bugs found
and fixed, and the history behind each decision.

## GitHub Issue Policy

GitHub issue titles, issue bodies, and issue comments must be written in English
using ASCII characters only. Do not post Japanese or other non-ASCII text to
GitHub issues. This applies to all agent surfaces and all GitHub access paths,
including `gh issue create`, `gh issue comment`, MCP tools, connectors, and
GitHub web/API operations.

## Git Workflow: Agents Commit, Humans Push

Coding agents working in this repo (Claude Code, Codex, etc.) should stage and
commit their own work as each task/change is completed, without waiting to be
asked -- this is a standing authorization, not a one-off. Commit at a natural
unit boundary (one milestone, one bug fix, one doc update), with a message
that follows this repo's existing commit-message style.

**Agents must never run `git push`.** Pushing to the remote is the human's
own step, always. This split exists so the human retains a manual review/gate
point before anything leaves the local repo, while still getting the benefit
of a clean, incremental commit history without having to ask for each one.
`.claude/settings.json` enforces the push half of this at the permission
level (`git push` is denied); the commit half is enforced by this convention,
not a technical control, since agents legitimately need to run `git commit`
for all kinds of work.

### Commit Identity for Coding Agents

Every coding agent must identify itself in both the author and committer fields
of each commit it creates. Use these identities:

- Codex: `OpenAI Codex <codex-agent@takibi.invalid>`
- Claude Code: `Anthropic Claude Code <claude-code-agent@takibi.invalid>`

Apply the identity only to the individual `git commit` invocation, for example
by setting `GIT_AUTHOR_NAME`, `GIT_AUTHOR_EMAIL`, `GIT_COMMITTER_NAME`, and
`GIT_COMMITTER_EMAIL` in that command's environment. **Do not set or change
repository-local or global `git config user.name` / `user.email`**, because the
same working tree may also be used by the human maintainer or another agent.
Human-authored commits continue to use the human's normal Git configuration.
If an agent other than those listed above creates a commit, it must use a
stable identity that clearly names the agent and must not impersonate either a
human or another agent.

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
- Refined-type bounds (`{lo..<hi as base}`) may use literal integers or earlier
  `const` names with bare integer literal initializers, e.g.
  `{0..<MAX_CONNS as usize}`. Ordinary global `let` declarations are deliberately
  not type-level constants, even when their initializer is a literal. Only a bare
  `for`-loop counter over a literal/`const` range, an `if`-narrowed value, a
  literal/`const` assigned directly to an explicitly refined-typed local, or a
  refined bound written with literals/`const` names reliably carries a provable
  range across a function-call argument boundary.

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

## Design Principle: Return a Variant, Not an Int Sentinel, for Fallible Operations

New functions with more than one possible outcome (success/failure, or several distinct
statuses) return a closed `variant` (see `SPEC.md`'s "Closed Variants and Existential Owners"),
not a plain `i32`/`bool` sentinel. This is a durable rule for this project, not a one-off
preference, adopted after GitHub issue #150's investigation of `fat12.tkb`'s pre-existing `-1`
sentinel convention.

- **Why**: a plain `i32` return (`0` on success, `-1` on failure, or several magic values
  layered onto the same int) puts the burden of correct interpretation entirely on the call
  site's own `if`/comparison code, with nothing stopping a caller from checking the wrong
  condition, comparing against the wrong sentinel, or dropping the result on the floor
  entirely. A `variant` return forces a `match` to name every outcome explicitly, so the
  compiler rejects a call site that only handles one arm. Concrete precedent:
  `examples/common/fat12.tkb`'s `FatIoResult`/`FatFormatStatus`,
  `examples/common_rpi3/usb_msc.tkb` and `examples/common_stm32/sdmmc.tkb`'s `DiskIoResult`,
  and `examples/kvs_server/kvs_server.tkb`'s `KvsPutResult` -- all replaced an existing
  `i32` 0/1/-1-style sentinel with a named variant plus a `match` at every call site.
- **A plain success/failure result gets `variant Foo { Ok; Err(i32); }`** (see `FatIoResult`);
  a status with more than two meaningfully distinct outcomes gets one case per outcome (see
  `FatFormatStatus`'s `IoError`/`NotFormatted`/`Formatted`, or `KvsPutResult`'s
  `Inserted`/`Overwrote`/`TableFull`) rather than layering extra magic values onto one `i32`.
  A result whose success case carries data (e.g. `sd_cmd3`'s RCA) gets its own
  value-or-error variant (`SdCmd3Result`) rather than overloading a negative int as both "the
  value" and "an error code."
- **A "found or not found" search/lookup result is a different shape from a status code, but
  is not automatically exempt from this rule either.** `fat_find_entry`/`kvs_find` (return the
  found index, or a sentinel meaning "absent") answer "does X exist and where," not "did the
  operation succeed" -- they were deliberately left alone during the first pass of issue #150's
  conversion, on the theory that this was a separate judgment call. A later pass in the same
  issue revisited that and converted them anyway (`FatFindResult`/`KvsFindResult`, each
  `{ Found(<index type>); NotFound; }`), since the actual goal is driving this pattern to zero,
  not stopping at status-shaped returns -- a search result being a different shape is a reason
  to design its variant differently (an `Option`-like two-case shape instead of `Ok`/`Err`), not
  a reason to leave it as a bare sentinel indefinitely.
- **This does not by itself stop a caller from ignoring the result.** An ordinary
  (`unrestricted`-kind) variant can still be bound and never matched, or a call's result never
  bound at all -- only `linear` forces consumption on every path, and a `linear` "must-check"
  status with no backing resource to justify the linearity is open design work, not yet settled
  (see GitHub issue #150). This rule upgrades "handled the wrong arm" from silent to a compile
  error; it does not upgrade "ignored the result entirely" from silent to a compile error.
- **Retrofitting an existing `i32`-returning function is a case-by-case call, not an
  automatic requirement -- but default to doing it when a concrete pass is already underway.**
  Converting a function already in the codebase touches every call site, which can span several
  files -- weigh the blast radius against the benefit for that specific function. In practice,
  once this rule motivated an actual cleanup pass (issue #150), the right default turned out to
  be converting every genuinely convertible case found along the way (including the "different
  shape" search results above), not stopping at the first cluster and leaving the rest as an
  unfinished carve-out -- reserve "leave it for now" for cases with a real reason (a shared
  multi-file interface contract needing a coordinated change, code sitting next to this
  project's one hand-justified `unsafe` site, a `!{interrupt}`-rooted handler, or a genuine HAL/
  RTOS-channel boundary that would need a redesign of the boundary itself, not just the function).
- **A raw wire/boundary int that still has to be decoded** (e.g. a value crossing an RTOS
  channel hardcoded to `i32` payloads, like `kvs_server_sdcard_rtos.tkb`'s `KvsSdStatus`) can
  use `match` directly against integer literals (see SPEC.md's "Match on Primitive Types",
  GitHub issue #151) instead of an `if`/`else if` chain of equality comparisons -- prefer this
  over hand-writing the comparisons, and reach for it before inventing a throwaway parallel
  `enum` purely to get `match`'s exhaustiveness/duplicate-arm checking.

## Language Specification

**See `SPEC.md` for the current language specification** (types, syntax,
statements, expressions, and semantics as they exist today). This file
(`AGENTS.md`) is the engineering log: design rationale, bugs found and
fixed, and the chronological "why" behind each decision. When a language
feature changes, update `SPEC.md` directly rather than letting the
description drift between the two files.

## Build Commands

```bash
make build          # build the compiler (takibi) only (= dune build)
make test           # run unit tests
make qemutest       # run QEMU plus host-side integration tests (build and verify automatically)
make stm32build     # cross-compile every ported example for STM32F746G-DISCOVERY (no hardware needed)
make check          # run langcheck + test + stm32build + qemutest together
make hwcheck-stm32        # like stm32build, but also loads into RAM + UART-diffs against real STM32 hardware
make hwcheck-stm32-net    # real-Ethernet hardware tests (needs the board's Ethernet port wired to this host)
make stress-stm32-kvs-server-sdcard-rtos  # opt-in STM32 KVS concurrency stress test (not in allcheck)
make hwcheck-rpi3   # opt-in Raspberry Pi 3B JTAG hardware integration test (not in allcheck, see examples/common_rpi3/AGENTS.md)
make hwcheck-rpi3-net     # RPi3 real-Ethernet hardware tests (needs the board's Ethernet port -- behind its USB host stack, see examples/common_rpi3/AGENTS.md -- wired to this host)
make perfcheck      # real-hardware profiler smoke tests
make allcheck       # clean/build, then QEMU + STM32 + RPi3 lanes in parallel
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
  const_env.ml    -- parser-time table of explicit primitive-integer `const` declarations,
                     used to resolve named array sizes/refined bounds like [T; QUEUE_SIZE]
  lexer.mll       -- ocamllex (includes hex literals, & token, as keyword, ^ token, -> token, void keyword)
  parser.mly      -- Menhir (includes pointer types, array types, function pointer types, prefix * / & / unary -, as cast)
  types.ml        -- internal type (ty) + HM-style inference output types + StringMap
  type_inf.ml     -- HM-style inference core plus refinement, effect, ownership,
                     static-index, privacy, and authority-region checks
  type_layout.ml  -- struct/enum layout table (fields, packed, align) backing sizeof/offsetof (issue #40)
  typechecker.ml  -- external wrapper (called from main.ml)
  llvm_gen.ml     -- LLVM IR generation and object file output
  use_resolver.ml -- resolves `use "path/to/file.tkb";` into the flat file list (issue #55)
bin/
  main.ml         -- CLI (`takibi <file1.tkb> [file2.tkb ...] [-o out.o] [--target <triple>] [--cpu <cpu>] [--features <features>] [-g] [--forbid-trap] [--version]`)
                     Multiple .tkb files are concatenated (flat global namespace) before compilation.
                     -g emits full DWARF debug info. QEMU/GDB source-level regression coverage lives in
                     examples/dwarf_debug and scripts/run_qemutest.sh; the PC-sampling profiler is a
                     separate use of the same gdbstub plumbing.
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
    http_server_common.tkb -- shared ARP/IPv4/TCP state machine for the HTTP
                     examples; response generation is supplied by callbacks in
                     the including example
    http_sdcard_server.tkb -- shared SD-card-backed HTTP response generator,
                     including path-to-8.3 mapping, content type selection, and
                     multi-segment file streaming over the common TCP core
    fat12.tkb     -- FAT12 filesystem core (issue #61/#98): fat_format/fat_open/fat_read/
                     fat_write/fat_close over mem_block_read/mem_block_write, which callers
                     (fatfs.tkb's in-memory `disk`, fatfs_sdcard.tkb's/http_server_sdcard.tkb's
                     real SDMMC1 adapter) supply. FatFile is now a linear indexed runtime owner
                     with per-open cursor/size/mode state; HISTORY.md's issue #97 entry records
                     the older affine-opaque singleton stage it replaced.
    rtos.tkb      -- Simple RTOS (issue #66) task-facing API: cpu_id() (examples/percpu),
                     address-indexed KLock/KGuard/klock/kunlock, the copy-rendezvous
                     Chan helpers, and rtos_task_add/rtos_start/task_self
                     scheduling glue generalized from the fixed-task examples. Chan internals
                     are private and initialized through constructors; ownership-bearing
                     rendezvous in rtos_demo uses a concrete stable owner slot and
                     stable_replace rather than a generic zero-copy channel. Scheduler
                     bookkeeping (SchedState) is private with refined field types, so
                     every task-table access is a proven array access (2026-07-17 RTOS
                     audit, see HISTORY.md). Used by both
                     QEMU RTOS examples and STM32 RAM RTOS examples such as
                     rtos_fatfs_sdcard/http_server_sdcard_rtos -- see HISTORY.md's RTOS entries.
                     task_yield() intentionally remains unimplemented until a real caller
                     needs voluntary switching.
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
                     shared with common_stm32/nvic.tkb, see examples/common_stm32/AGENTS.md)
    timer.tkb     -- extern fn timer stubs, setup_task_stack, timer_init (depends on gic.tkb),
                     scheduler_init/_disable/_rearm_tick (uniform names shared with
                     common_stm32/scheduler.tkb, see examples/common_stm32/AGENTS.md)
    rtc.tkb       -- PL031 RTC register access (see examples/common_qemu/AGENTS.md)
    virtio_mmio.tkb -- net_init/net_rx_wait/net_rx_acquire/net_rx_len/net_rx_frame/
                     net_transmit/net_tx_complete/net_rx_release/net_read_mac
                     (uniform API shared with common_stm32/eth.tkb, see examples/common_stm32/AGENTS.md)
    netconfig.tkb -- OUR_IP (QEMU-side static IP for arp_reply/icmp_echo/tcp_echo),
                     HTTP_SERVER_IP (http_server's own IP, see examples/common_stm32/AGENTS.md's "Network config" entry)
    stm32_stub.tkb -- no-op stand-ins for STM32-only symbols a shared example's dead
                     QEMU-side code still references (see examples/common_stm32/AGENTS.md)
    semihosting_asm.S -- ARM semihosting file-I/O stubs (semihosting_open/write/close/read),
                     used by examples/fatfs to dump its in-memory disk image to a host file
                     for mtools to verify
  common_stm32/   -- STM32F746G-DISCOVERY (Cortex-M7) HAL, mirroring common_qemu's
                     function names/signatures so every example .tkb file is a single
                     file shared by both targets -- see examples/common_stm32/AGENTS.md
                     for the full bring-up/scheduler/Ethernet design
    startup.S     -- Reset_Handler, vector table, PendSV_Handler, weak
                     SysTick/ETH/pendsv_dispatch stubs; calls only `main`. Flash-execution
                     only -- used solely by examples/http_server/kernel_stm32.elf's rule now
                     (see examples/common_stm32/AGENTS.md's "STM32 Hardware Test Harness: RAM Execution" entry for why every
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
                     scheduler_init/_disable/_rearm_tick (see examples/common_stm32/AGENTS.md)
    sem_asm.S     -- atomic semaphore: sem_wait/sem_post (ldrex/strex/dmb)
    eth.tkb       -- net_init/net_rx_acquire/net_rx_frame/net_transmit/net_rx_release/net_read_mac
                     (real Ethernet MAC/PHY/DMA driver, see examples/common_stm32/AGENTS.md)
    eth_sdmmc_regs.tkb -- RCC_AHB1ENR/RCC_APB2ENR/GPIOC_MODER/GPIOC_OSPEEDR, split out of
                     eth.tkb and sdmmc.tkb (issue #97 follow-up) once http_server_sdcard.tkb
                     became the first program to need both HALs and exposed the duplicate --
                     see HISTORY.md
    netconfig.tkb -- OUR_MAC/OUR_IP (STM32 board's fixed network identity),
                     HTTP_SERVER_IP (same value as OUR_IP here, see examples/common_stm32/AGENTS.md's "Network config" entry)
    sdmmc.tkb     -- disk_initialize/disk_status/disk_read/disk_write (real SDMMC1 microSD
                     driver, DMA+interrupt both directions, issue #62)
    semihosting_stub.S -- no-op stand-ins for examples/fatfs's semihosting extern fns on
                     this target (no ARM semihosting on real hardware)
  common_rpi3/    -- Raspberry Pi 3B (BCM2837) bare-metal HAL, JTAG-injection-only
                     bring-up (issue #140), 63 top-level examples ported (all
                     except fatfs: rtc/timer, real interrupts, the preemptive
                     scheduler group, and net_echo through kvs_server over a
                     from-scratch USB host stack) -- see its AGENTS.md.
    startup.S     -- core-0-only gate, exception vector table + rpi3_irq_entry,
                     HCR_EL2.IMO routing, inherited-interrupt quiescing, stack/BSS
                     zeroing, calls mmu_init() then main(), halts on return
    intc.tkb      -- BCM2837 2-level interrupt controller driver (QA7 ARM-local +
                     legacy VC armctrl): irq_uart_rx_setup/unmask, rpi3_irq_dispatch
    rtc.tkb / timer_asm.S -- rtc_* HAL on the ARM Generic Timer's free-running
                     counter (this board has no real RTC peripheral) -- seconds-
                     since-boot, not wall-clock; see AGENTS.md's "RTC" entry
    mmu.S         -- minimal EL2 identity-map MMU setup (2-level, 4KB granule):
                     fixes LLVM-synthesized unaligned-store faults that occur
                     whenever the stage 1 MMU is off (Device memory semantics).
                     Both D-/I-cache are ON (re-enabled for ldaxr/stlxr
                     correctness, see AGENTS.md's "MMU and caches" entry) --
                     JTAG's load_image and this board's own DWC2 controller both
                     bypass the CPU cache, so anything DMA'd needs explicit
                     maintenance instead (dma_prepare_tx/dma_prepare_rx/
                     dma_finish_rx, real AArch64 lowering since issue #146;
                     startup.S's own dcache_invalidate_all handles the
                     whole-cache case at boot)
    link.ld       -- load address 0x200000 (deliberately distinct from jtag_stub.ld's)
    uart.tkb      -- UART0 (PL011) driver, GPIO14/15 ALT0 pinmux + pull disable
    print.tkb     -- isize/usize uart_print/uart_println overloads (AArch64
                     64-bit, byte-for-byte copy of common_qemu/print.tkb)
    jtag_stub.S / jtag_stub.ld -- standalone spin-loop image flashed as the SD
                     card's kernel8.img, giving JTAG a clean non-Linux catch point
    mailbox.tkb   -- VideoCore mailbox property interface (issue #144): must
                     power on the USB power domain before any DWC2 register does
                     anything; also the bus-address-translation reference point
                     (0xC0000000 alias) DWC2's own DMA reuses
    usb_dwc2.tkb  -- DesignWare Hi-Speed USB2 OTG host controller driver: core/
                     host-port bring-up, control/bulk host-channel transfers,
                     descriptor parsing, per-endpoint DATA0/DATA1 toggle tracking
    usb_hub.tkb   -- minimal USB 2.0 chapter-11 hub-class driver (port power/
                     reset/status only) to reach the LAN9514's internal ports
    lan9514.tkb   -- SMSC LAN9514 vendor register protocol (no memory-mapped
                     registers -- everything is a USB vendor control transfer),
                     MAC assignment (no EEPROM on this board), PHY link bring-up
    eth.tkb       -- net_init/net_rx_*/net_transmit HAL matching common_stm32/
                     eth.tkb's and common_qemu/virtio_mmio.tkb's API exactly, so
                     net_echo.tkb and siblings run unmodified against it; a single
                     synchronous RX/TX buffer pair, not a real DMA descriptor ring
                     (USB bulk transfers here are request/response, not async)
    netconfig.tkb -- OUR_MAC (locally-administered)/OUR_IP (192.168.20.2, this
                     board's own dedicated point-to-point NIC subnet)
  <name>/         -- each directory: see the leading comment in <name>.tkb for a description.
                     Every example is now a single file compiled for both targets -- no
                     `<name>_stm32.tkb` exists anywhere in this repo (see the STM32 section
                     below for how the hardest cases, irq/preempt/semaphore/condvar/watchdog/
                     msgqueue, got there too).
scripts/
  run_qemutest.sh -- integration test script: host-side checks plus QEMU tests
                     (FIFO sync and timing verification included)
  run_hwtest_ram.sh -- STM32 hardware integration test script (make hwcheck-stm32): RAM execution
                     over the debug port, no Flash write -- see "STM32 Hardware Test
                     Harness: RAM Execution" below. Supersedes the deleted run_hwtest.sh.
  run_hwtest_net_ram.sh -- STM32 real-Ethernet hardware tests (make hwcheck-stm32-net): same RAM
                     execution as run_hwtest_ram.sh, over a genuinely cacheable AXI SRAM1
                     DMA region -- see examples/common_stm32/AGENTS.md's "STM32 Hardware Test Harness: RAM Execution" entry.
                     Supersedes the deleted run_hwtest_net.sh.
  provision_http_server_sdcard.sh -- writes a real mtools-built FAT12 image onto
                     http_server_sdcard's SD card via OpenOCD + the real SDMMC1 driver, no
                     human involved; shared by make hwcheck-stm32-net,
                     make stm32-http-server-sdcard, and
                     make stm32-http-server-sdcard-rtos
                     (issue #97, see HISTORY.md)
  run_hwtest_rpi3.sh -- RPi3 hardware integration test script (make hwcheck-rpi3): JTAG
                     injection, UART capture/diff -- see examples/common_rpi3/AGENTS.md.
  run_hwtest_rpi3_net.sh -- RPi3 real-Ethernet hardware tests (make hwcheck-rpi3-net), over
                     the USB host stack examples/common_rpi3/AGENTS.md's "USB host stack"
                     section covers -- same eth_*_test.py raw-socket scripts STM32 already
                     uses, parameterized by ETH_TEST_SUBNET/ETH_TEST_MAC for this board's
                     own point-to-point NIC/address.
test/
  test_takibi.ml  -- Alcotest unit tests for parser / type_inf
```

## Important Design Notes

Detailed design rationale, per-feature file-change checklists, and the
"why" behind each decision (bugs found, approaches rejected, verification
steps) now live in **HISTORY.md**, not here -- moved out on 2026-07-08 to
keep this file under agent context budgets (it had grown past
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
- **Language-level known limitations** (function overloading, the flat top-level namespace, `isize`, scoped refinement-type inference, `sizeof`/`offsetof` restrictions, `use` file dependencies) -- see `SPEC.md`'s dedicated sections (Function Pointers/extern fn/Overloading, Refined Integer Types, Types) and its own "Known Limitations (Language-Level)" list for current behavior; see `HISTORY.md` for the design investigations behind each.
- **DMA/device memory-barrier builtins are implemented** -- the STM32 Ethernet DMA bring-up needed a `dsb` instruction between a
  descriptor-ring write and the "poll demand" register kick, because `*io` volatile writes alone don't guarantee the
  CPU's write buffer has retired before a subsequent register write reaches the DMA engine (see the "Hardware
  bring-up bug worth knowing about" paragraph in examples/common_stm32/AGENTS.md's STM32 Ethernet entry -- found only via live
  openocd/gdb-multiarch debugging on real hardware, not something the compiler flagged). The original handwritten
  `extern fn eth_dsb()`/`eth_asm.S` workaround has been removed. `dma_publish()`, `dma_consume()`, and
  `device_fence()` now lower per target and are placed inside the STM32 and virtio driver ownership transitions.
  The cache-aware `dma_prepare_tx`/`dma_prepare_rx`/`dma_finish_rx` operations maintain Cortex-M7 cache lines,
  so application examples do not manually select barriers. The RX/TX API now uses indexed linear owners plus
  authority-derived region ties to reject use-after-release, double-release, and early release while TX DMA is
  still in flight without changing the source-level barrier semantics.
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
- **STM32 Ethernet driver details** (unified driver API, network config, the DMA-ordering hardware bug, TX interrupt completion) -- see `examples/common_stm32/AGENTS.md`.
- **RISC-V has no `dma_prepare_tx`/`dma_prepare_rx`/`dma_finish_rx` lowering yet** -- these now raise a compile
  error on RISC-V targets rather than silently falling back to a bare barrier (issue #146). AArch64 previously
  had the same silent-fallback gap (found during Raspberry Pi 3B USB host stack bring-up, issue #140/#144, once
  its D-cache was turned back on for `ldaxr`/`stlxr` reasons and its DWC2 controller/VideoCore mailbox needed real
  cache maintenance around DMA hand-offs) and now gets a real `dc cvac`/`dc civac`/`dc ivac` VA-range-loop
  lowering in `lib/llvm_gen.ml`, matching the real Cortex-M7 `DCCMVAC`/`DCIMVAC` the STM32 backend already had --
  `examples/common_rpi3/mailbox.tkb`/`usb_dwc2.tkb` call the standard builtins directly now, same as STM32's
  `eth.tkb`, with no hand-written cache-range assembly stub needed on this target anymore. RISC-V's own real
  lowering (gated on the Zicbom extension's `cbo.clean`/`cbo.flush`/`cbo.inval`) is deferred until an actual
  RISC-V target exists in this project to verify it against, rather than shipping unverified speculative codegen.

## QEMU Bare-Metal (AArch64)

QEMU/AArch64 bare-metal HAL reference (machine/CPU, PL011 UART and PL031
RTC register addresses, semihosting exit, GICv2, ARM Generic Timer) now
lives in **`examples/common_qemu/AGENTS.md`** -- Coding agents that support
nested guidance should load that file for work under `examples/common_qemu/`.

## STM32F746G-DISCOVERY Bare-Metal (Cortex-M7)

STM32 Cortex-M7 bring-up (devcontainer/USB setup, build model,
USART1/RTC/NVIC details), the SysTick+PendSV preemptive scheduler, the
Ethernet MAC/PHY/DMA driver, and the RAM-execution hardware test harness
now live in **`examples/common_stm32/AGENTS.md`** -- Coding agents that support nested guidance should load that file for work under `examples/common_stm32/`.

## Raspberry Pi 3B Bare-Metal (BCM2837, JTAG-only bring-up, issue #140)

Raspberry Pi 3B bring-up (JTAG/UART devcontainer USB setup, the
JTAG-injection RAM-load model and why it differs from STM32's `reset
halt`, the spin-stub image, the `sudo`-makes-JTAG-worse gotcha specific
to this devcontainer, UART0/GPIO pinmux details) now lives in
**`examples/common_rpi3/AGENTS.md`** -- Coding agents that support
nested guidance should load that file for work under
`examples/common_rpi3/`.

## virtio-net Examples (examples/net_echo, examples/arp_reply, examples/icmp_echo)

QEMU-only stepping stones toward the TCP/IP stack goal (raw frame echo,
ARP reply, ICMP echo) built on the same virtqueue/DMA/IRQ plumbing.
Implementation details (legacy virtio-mmio, vring layout, endianness
handling, test harness) now live in **`examples/common_qemu/AGENTS.md`**.

## TCP/IP Example Progression (examples/inet_checksum, ip_parse, icmp_echo, tcp_parse, tcp_echo, http_server)

The design rationale for how these examples were incrementally built
-- why IPv4/ICMP was split into 3 small steps, why TCP is one
incrementally-grown example rather than one-per-stage, the TCP
options/SLIRP/ARP bugs found while wiring up a real browser client
for `http_server` -- now lives in `HISTORY.md`. See
`examples/common_qemu/AGENTS.md` for the virtio-net plumbing these
examples share, and each example's own header comment for a
one-line description of what it does.

## Debug Info and Execution Profiling (QEMU)

`-g` emits full DWARF intended to be useful in real `gdb-multiarch`
sessions, not just to satisfy `llvm-dwarfdump`. The live QEMU/GDB
regression fixture is `examples/dwarf_debug/dwarf_debug.tkb`, with
normalized expected output in `examples/dwarf_debug/dwarf_debug.gdb.expected`
and the harness in `scripts/run_qemutest.sh`.

The same QEMU gdbstub plumbing is also used by the sampling profilers for
HTTP/TCP experiments. That technique is useful for CPU-bound code, but it
is a poor fit for network/interrupt-driven I/O where idle wait time can
dominate samples.

For the real STM32 HTTP+SD+RTOS and KVS+SD+RTOS demos,
`takibi --profile-functions` emits a fixed DWT `CYCCNT` profiler table plus
a fixed call-path table. `make profile-stm32-http-server-sdcard-rtos`
provisions the SD card, warms the server, profiles a measured `/ICON.PNG`
fetch, dumps the tables through OpenOCD, and writes a FlameGraph-compatible
folded stack file under `_build/takibi_profile/http_server_sdcard_rtos/`.
`make profile-stm32-kvs-server-sdcard-rtos` profiles a KVS PUT plus its
eventual SD write-back; set `TAKIBI_PROFILE_LOAD=stress` to drive it with `scripts/kvs_stress.py`
(defaulting to concurrency 4 and a fixed key, the practical STM32 stress
profile setting). The numbers are inclusive wall-clock cycles, so blocking
paths such as `cond_wait`, `kvs_sd_request_recv`, and `net_rx_wait` are
expected to include wait time.

## Instructions for Coding Agents

- **Do not create git commits.** Only do so when the user explicitly requests it.
- Prefer idiomatic OCaml style. Use `Map.Make(String)` over `Hashtbl`.
- Do not use the `base` package (it causes friction at the boundary with LLVM bindings).
- The user is an OCaml beginner, so explain the reason for code changes from the perspective of "why write it this way."
- **Do not save durable project guidance to tool-specific memory stores.** Consolidate project-specific information in `AGENTS.md` so it can be shared across agent environments.
- **All text in this repository must be ASCII-only.** Never write Japanese or any other non-ASCII characters in source files, comments, documentation, or any other file. `make langcheck` enforces this and will fail if non-ASCII characters are found.
- **Follow YAGNI (see "Design Principle: YAGNI" above).** Do not design or implement functionality beyond what the current, concrete task needs. If a request seems to call for more than that, flag the tradeoff and ask before building it.
- **New `.tkb` code under `examples/`: get the whole milestone working without refinement types/`--forbid-trap` first, commit each working piece as a baseline, then turn `--forbid-trap` on once the milestone is done and fix only what it flags** (see "Development Process: Prove New `.tkb` Code Without `--forbid-trap` First, Then Turn It On" above -- e.g. `fatfs` + its real SD card integration are one milestone; don't harden `fatfs` alone partway through). Do not skip straight to a `--forbid-trap`-clean version, and do not "fix" a flagged site by switching it to a raw pointer.
- **Proactively write English summaries of chat decisions/design rationale to the relevant GitHub issue.** The chat itself is in Japanese, but this repository's issues must stay English-only -- `gh` now has write access (`gh issue comment` / `gh issue create`, see `.claude/settings.json` and `.codex/hooks.json`), and tool-specific hooks (`.claude/hooks/gh-issue-ascii-only.sh` and `.codex/hooks/gh-issue-ascii-only.sh`) guard those two commands against non-ASCII text, so the summary must already be in English before the command is run. This takes over a task the user previously did by hand (translating chat discussion and posting it to issues themselves) -- do it without being asked, once a decision, design tradeoff, or root-cause conclusion has actually been reached in the conversation, not after every message. Infer the target issue from context (a number mentioned in the recent chat, a commit message, `git log`); if none is evident, ask rather than guessing or opening a new issue unprompted.

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
                         register errors it raises. Needed by the live DWARF/GDB regression,
                         QEMU-based sampling profilers, and STM32 hardware debugging via
                         openocd's gdbstub.)
openocd, stlink-tools   (for STM32F746G-DISCOVERY: openocd for SWD debug/register inspection,
                         `st-flash`/`st-info` (stlink-tools) for flashing -- see "STM32F746G-
                         DISCOVERY Bare-Metal" above. Requires USB passthrough set up in
                         .devcontainer/devcontainer.json; `make hwcheck-stm32` needs the real board
                         connected, everything else (including `make check`'s `stm32build`)
                         does not.)
```
