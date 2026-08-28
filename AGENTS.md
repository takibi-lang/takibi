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

## Maintenance Scope: `kernel/` and `linux_user/`

**All new feature/product implementation work is restricted to `kernel/`.**
The standalone Unix-like kernel is the active product surface.  New kernel
features, bug fixes, fixtures, and target-specific code belong under
`kernel/`.

**`linux_user/` is a second, narrower actively-maintained surface**: fast,
host-native (x86_64-pc-linux-gnu, no QEMU/hardware) compiled-and-executed
tests for compiler/language features and algorithms whose correctness does
not depend on real hardware timing, interrupts, cache behavior, or
concurrency.  It exists specifically for iterating on new type-system
features (e.g. prototyping a data structure) before -- or independent of --
integrating them into `kernel/`.  See "Where Should a New Test Go?" below
for the exact criterion and `make linuxbuild`/`make linuxcheck` under
"Build Commands".  Add to it freely when a test satisfies that criterion;
its whole point is to be cheap to grow.

The `examples/` tree is historical heritage.  It records the language and
bare-metal milestones that led to the standalone kernel and to `linux_user/`.
It is not a target for new feature work: do not add features to it, port new
`kernel/` behavior into it, refactor it, or update it merely to keep parity
with `kernel/`.  It is, however, checked regularly (`make -f examples/Makefile
allcheck`, roughly daily): every covered artifact, including the historical
RPi5 set, is built, and the QEMU and STM32 runtime lanes are kept green. A
genuine regression found that way (e.g. a compiler bug that breaks existing,
unchanged example behavior) should be fixed, not left to bit-rot silently.
Historical RPi5 hardware execution is opt-in
(`hwcheck-rpi5`/`hwcheck-rpi5-net`) and is not part of this routine guarantee;
current RPi5 hardware behavior is maintained under `kernel/`. This is distinct
from an example build/test failure caused by an *intentional* kernel-only or
`linux_user/`-only change (e.g. deliberately renaming a shared concept that
only `kernel/` still uses) -- that kind of failure does not justify modifying
`examples/`; report the historical incompatibility instead. Modify an
example's own `.tkb`/build files only when the user explicitly asks for that
exact historical artifact to be changed. A test being extracted (copied or
moved) into `linux_user/` is exactly such an explicit ask; see the extraction
note below.

**Copy, don't blindly move, when extracting an example into `linux_user/`.**
Some examples exist *only* for QEMU/host coverage (`linux_user/linux_hello` is
one that was moved outright, not copied) and can be moved once ported. Many others
(anything in `examples/Makefile`'s `EXAMPLES` list) are also independently
cross-compiled for STM32 (`stm32build`) and exercised on real RPi3/RPi5
hardware (`hwcheck-rpi3`/`hwcheck-rpi5`, see `scripts/run_hwtest_rpi5.sh`).
Removing one of those from `examples/` would silently drop real-hardware
regression coverage that has nothing to do with `linux_user/`'s purpose --
check each candidate's hardware-test scripts before removing anything, and
default to copying (leaving the original in place) whenever unsure.

Repository-level governance documents such as this file may still be updated
when needed to describe or enforce the maintenance policy.  Do not expand a
kernel task into compiler, root build-system, or other non-`kernel/`/
non-`linux_user/` work without a separate concrete requirement and explicit
user direction.

## Where Should a New Test Go?

Three tiers exist, and a new test should be justified into the tier that
positively fits it -- not dropped into whichever tier is left over after
ruling out the others, which is how `examples/` grew into something slow
enough that people stopped running it casually (see its own header comment
in `examples/Makefile`'s history, and HISTORY.md, for that trajectory).

1. **`test/test_takibi.ml`** (Alcotest, `make test`) -- fastest.  In-process:
   does this compile/type-check/get rejected correctly, and (sometimes) does
   the generated LLVM IR have the expected shape.  Never executes the
   compiled program.  Use this for pure syntax/type-system questions: "does
   this refined-type narrowing survive an early return", "is this construct
   even parseable", "does this ownership rule reject the unsound case".
   **When more than one case fails, Alcotest's own terminal reporter
   prints only the FIRST failure's detail box**, not a truncation bug --
   `make test` already routes through `scripts/list_dune_test_failures.sh`
   for exactly this reason, so a plain `make test` shows every failure, not
   just one. Only reach for the script directly if you bypass `make test`
   (a bare `dune test`, or `dune exec test/test_takibi.exe` to target a
   specific case) and still want every failure listed.
2. **`linux_user/`** (`make linuxbuild`/`make linuxcheck`) -- compiles AND
   *executes* a small host-native x86_64 program, diffing real stdout
   against `<name>.expected`.  Still cheap (no QEMU/hardware), but catches
   what (1) structurally cannot: is the runtime BEHAVIOR correct (does this
   algorithm/data structure actually compute the right answer, not just
   typecheck).
3. **`kernel/` on RPi5 + QEMU** (`make kernelcheck`) / **`examples/`'s
   QEMU+real-hardware lanes** -- the expensive, fully-faithful tier: real
   MMIO, real interrupts, real cache/memory-ordering behavior, real
   concurrency/timing.

### Build-Level Negative Controls Must Prove the Build Ran

A negative control performed through `make` or another build command must
assert both facts independently:

1. the build command exited nonzero; and
2. its output contains the specific expected diagnostic.

Never treat absence or presence of a grepped message alone as the verdict. A
stale depfile, missing prerequisite, unavailable tool, or unrelated recipe
failure can prevent the compiler from running at all, making an output-only
check falsely confirm or reject the condition under test. Prefer an in-process
`expect_type_error` test when the property does not require the build system.
When a build-level control is necessary, capture the exit status before
inspecting output and fail the control if the command unexpectedly succeeds or
if it fails for a different reason.

**The litmus test for tier 2 (`linux_user/`) is positive, not residual:**

> Would this exact test's pass/fail verdict be identical if run on real
> hardware and if run as a native Linux/AMD64 process?

If yes, it belongs in `linux_user/` -- e.g. a queue's push/pop ordering, a
generation-counter wraparound, a checksum/parser's correctness, a refined-type
proof's compile-time acceptance backed by a runtime check of the computed
value. If the answer depends on real timing, interrupt latency, cache
coherency, or actual concurrent execution, it belongs in tier 3 -- even
though tier 3 is slower and more inconvenient, downgrading such a test to
`linux_user/` for convenience produces a test that reliably passes without
ever being able to catch the bug it exists to catch, which is worse than not
having the test at all.  Do not place a test in `linux_user/` merely because
it doesn't obviously fit tiers 1 or 3; justify it against the question above.

## GitHub Issue Policy

GitHub issue titles, issue bodies, and issue comments must be written in English
using ASCII characters only. Do not post Japanese or other non-ASCII text to
GitHub issues. This applies to all agent surfaces and all GitHub access paths,
including `gh issue create`, `gh issue comment`, MCP tools, connectors, and
GitHub web/API operations.

Use the `gh` CLI for every GitHub operation. Do not use GitHub connectors or
MCP GitHub tools: this environment is intentionally configured only for `gh`.

### Issue Numbers Do Not Belong in Tracked Files

**Status lives on the [project board](https://github.com/orgs/takibi-lang/projects/2),
not in checked-in documentation.** Do not add "tracked in #N", "completed by
#N", or a list of open follow-up issues to a file in this repository. Describe
the behavior or the reason instead, and let the board carry who/when/how far.

The rule exists because that kind of reference rots silently and at a rate
nothing in the build catches. Concrete incident (2026-08-05): `kernel/README.md`
and `kernel/SYSCALLS.md` both stated that `ppoll` "never actually blocks
regardless of the caller's timeout" and pointed at the open issue tracking real
blocking semantics -- one day after that issue was closed and the UART blocking
path shipped. Two files were describing the kernel's behavior incorrectly
because a pointer to external state was embedded in prose. `SYSCALLS.md` even
carried an explicit same-commit maintenance rule at the time, and it still
happened; this is a structural problem, not a discipline problem.

Two deliberate exceptions:

- **`HISTORY.md`** is the engineering log. It records what happened, is written
  in the past tense, and is never updated to track current state, so an issue
  number there is a stable historical fact rather than a live pointer.
- **`ROADMAP.md`** is a dated, point-in-time plan and is the one file where
  enumerating open issues is the whole purpose. It is refreshed occasionally,
  wholesale, rather than maintained incrementally -- being out of date there is
  visible and expected, not misleading.

Everything else -- `README.md` files, `SYSCALLS.md`, `SPEC.md`, source
comments -- should read correctly with no GitHub access at all. A source
comment naming an issue for a design rationale that has already been settled is
acceptable where it genuinely explains why the code looks the way it does; a
comment naming an issue as future work is not.

### Record How a Defect Was Found

**Every GitHub issue carries a `Found-by:` field, and every commit that closes
an issue carries a `Found-by:` trailer.** It names how the problem was
discovered, using one of these values, optionally followed by free text:

| Value | Meaning |
| --- | --- |
| `type-error` | the Takibi compiler's type checker rejected it |
| `compiler-lint` | a compiler lint or a `scripts/check_*.py` build check flagged it |
| `runtime-check` | a compiler-emitted runtime check or kernel assertion fired |
| `test` | a dune, QEMU-lane, or hardware test failed |
| `qemu` | found while debugging under QEMU (gdb, boot logs) |
| `hardware` | found on a real board (bring-up, bisect, SWD) |
| `review` | found by reading code, by an audit, or reported by the maintainer |
| `design` | not a defect at all: a design, research, or refactoring task |

```
Found-by: hardware -- RPi5 SWD register read after a two-hour boot-log bisect
```

The free text is the right place for what the discovery cost, which is the part
nothing else in this repository ever records.

The rule exists because this one fact has a different decay rate from
everything around it. A defect's symptom, its fix, and the check that now
rejects it can all be re-derived later from the issue tracker, from `git log`,
and from `test/test_takibi.ml` -- which already carries roughly 500 negative
tests, many of them naming the issue they came from. Whether the type checker
caught it or whether it took three hours on a board cannot be re-derived from
any of those, and it is the fact that says what the language is actually worth.
Measured on 2026-08-26: of the last 400 commits, 144 named an issue, and
subjects such as "three cheap ones from this session's own audit" are the
visible edge of defects that were found, fixed, and never written down as
anything a later reader could classify.

Note the interaction with "Issue Numbers Do Not Belong in Tracked Files" above.
`Found-by:` is deliberately *not* a new tracked document keyed by issue number;
that shape is what the ppoll incident of 2026-08-05 warns against. It lives in
GitHub issues and in commit messages, and its durable home in this repository is
`HISTORY.md`, which is already the sanctioned exception: past tense, never
updated to track current state.

`scripts/hooks/found-by-policy.sh` enforces this, and is wired into
`.claude/hooks/found-by-required.sh`, `.codex/hooks/found-by-required.sh`, and
`.githooks/commit-msg` (activate that one per clone with
`git config core.hooksPath .githooks`).

**One case is convention only.** A defect found and fixed inside a single
session, with no issue ever filed, is exactly the case most worth recording and
the one no trigger can detect -- the commit that fixes it looks like any other
commit. Add the `Found-by:` trailer to it anyway.

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
- GitHub Copilot CLI: `GitHub Copilot CLI <copilot-cli-agent@takibi.invalid>`

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

### Diagnostic Policy: Errors by Default, Warnings by Exception

**A compiler diagnostic that identifies a construct the programmer should fix is a
compile error by default, not a warning.** Takibi's compiler, language specification,
kernel, and maintained tests live in one repository and are migrated together. Unlike
using `-Werror` with an independently-versioned external compiler, there is no need to
leave a correct rule non-fatal merely to absorb warning-set drift across repository or
release boundaries.

- If the compiler can determine that a construct is invalid, dangerously ambiguous,
  redundant at a trust boundary, or contrary to a maintained project invariant, reject
  it. This includes mechanically-fixable cases such as ambiguous operator grouping or
  an `unsafe` scope that contains no operation requiring `unsafe`.
- Do not introduce a warning as a compatibility or gradual-migration mechanism for
  `kernel/` or `linux_user/`; update the compiler and every affected in-repository caller
  in the same change. If experimental bring-up genuinely needs a permissive mode, make
  that an explicit option with a documented purpose and boundary, as `--forbid-trap`
  does, rather than an always-ignorable warning.
- A warning is an exception reserved for information where the compiler cannot
  establish that the program is wrong and rejecting it would exclude a legitimate,
  presently-needed program. Every new warning needs an explicit rationale for why it
  cannot be an error, plus repo-wide validation showing its expected signal and noise.
- Prefer no diagnostic over a warning whose false-positive behavior is not understood.
  First make the analysis precise enough to support a reliable error, or keep it behind
  an explicit investigative/debug option.

## Development Process: Write `.tkb` Code Under `--forbid-trap` From the Start

**New `.tkb` work is written and compiled with refinement types and `--forbid-trap` enabled
from the first commit.** This is the current default, changed from this project's earlier
default -- write it fully working WITHOUT refinement types and WITHOUT `--forbid-trap` first,
commit that as a known-good baseline, and only THEN turn `--forbid-trap` on as one later,
separate hardening pass -- which had been the rule since the `fatfs` example (GitHub issue
#61) and its SD card integration (issue #62). Confirmed with the user 2026-07-23 after several
consecutive hardening passes (issues #135, #140, and most recently #145's RPi3
USB-Mass-Storage group) each flagged progressively fewer trap sites, with the RPi3 pass
flagging zero: the project's refinement-type idioms are now established enough that the old
two-phase separation no longer earns its cost for code that follows them. See `HISTORY.md`'s
dated entries for issues #61, #62, #135, #140, and #145 for the historical evidence this
decision rests on -- that record stays as-is; it documents what was true when it was written,
not a claim about current process.

- **Default: write refined parameter/loop-bound types and idiomatic checked array/slice
  indexing from the start** (`{lo..<hi as base}`, `for i: usize in 0..<n`), the same "finished
  form" described above ("Code with remaining bounds checks = code whose type annotations are
  still insufficient"), and add `--forbid-trap` to the file's Makefile rule in the same commit
  that introduces the code. When a bound genuinely depends on runtime state the type system
  cannot see (e.g. an allocator's own bookkeeping invariant), use explicit if-condition
  narrowing (`if (v >= lo && v < hi) { ... }`) right at the point of use instead of a raw
  pointer. **Do not reach for raw pointers/`unsafe` merely to route around a bounds check that
  checked/refined indexing would have needed instead** -- that silently reintroduces exactly
  the unproven-access risk `--forbid-trap` exists to catch. Raw pointers stay reserved for
  cases that need them regardless of this process (a byte-oriented hardware/block-device
  boundary, a struct-overlay cast onto a raw buffer, a NUL-terminated scan whose length isn't
  known up front) -- never as a shortcut around this default.
- **Exception: a milestone whose hardware/protocol behavior is not yet understood may still
  use the old prove-first-then-harden process, as a deliberate, explicitly-flagged judgment
  call, not a silent default.** Forcing refined types onto code whose data flow or wire format
  you don't yet know tangles "is the logic right" together with "is the proof right" while
  both are still unknown -- exactly the situation the original two-phase process was designed
  for. Concretely: a genuinely new peripheral this project has never driven before, a
  first-of-its-kind DMA/cache interaction, or a new board port's earliest bring-up steps. Ask
  before assuming this exception applies if it's unclear whether a task is "an established
  pattern applied again" or "genuinely unknown hardware behavior."
  - While deliberately using this exception: write plain, idiomatic checked indexing and
    ordinary unrefined parameter types; commit the unrefined milestone as its own known-good
    baseline once it demonstrably works (verified by integration tests actually exercising the
    code, not by the compiler); then turn `--forbid-trap` on for the *whole* milestone in one
    later pass and fix only what it flags, at its root (a refined type or if-narrowing, never
    a raw-pointer swap) -- not piecemeal after each intermediate piece. This baseline-then-
    hardened-pass diff is deliberately preserved in history, not squashed away: it is the
    concrete evidence for why `--forbid-trap` earns its keep when it is used this way.
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
- **Use `must_use variant` when ignoring the whole result must be a compile error.** This
  checker-only policy, added by GitHub issue #150, requires the value to be matched, returned,
  or transferred on every path without pretending a status owns a linear runtime resource.
  `FatIoResult` and `CheckedUsize` use it. An ordinary unrestricted `variant` remains droppable
  and is appropriate for state/data packages that do not represent a must-check operation.
- **Retrofitting an existing `i32`-returning function is a case-by-case call, not an
  automatic requirement -- but default to doing it when a concrete pass is already underway.**
  Converting a function already in the codebase touches every call site, which can span several
  files -- weigh the blast radius against the benefit for that specific function. In practice,
  once this rule motivated an actual cleanup pass (issue #150), the right default turned out to
  be converting every genuinely convertible case found along the way (including the "different
  shape" search results above), not stopping at the first cluster and leaving the rest as an
  unfinished carve-out -- reserve "leave it for now" for cases with a real reason (a shared
  multi-file interface contract needing a coordinated change, code sitting next to a
  hand-justified `unsafe` site whose trust rationale the conversion would disturb, a
  `!{interrupt}`-rooted handler, or a genuine HAL/RTOS-channel boundary that would need a
  redesign of the boundary itself, not just the function).
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

The root `Makefile` covers the compiler, `kernel/`, and `linux_user/` --
the maintained product + fast-test surface. Everything under `examples/`
(frozen, historical, see "Maintenance Scope: `kernel/` and `linux_user/`"
above) lives in its own `examples/Makefile` instead, so a plain `make
<target>` at the repo root can never accidentally run an examples-only
check against `kernel/` work. Always invoke it explicitly from the repo
root -- never `cd examples` first:

```bash
make build              # build the compiler (takibi) only (= dune build)
make test               # run unit tests
make langcheck          # repo-wide ASCII-only check (kernel/ + examples/ + linux_user/ + compiler)
make kernelbuild-rpi5   # build kernel/build/rpi5/kernel.elf (no hardware needed)
make kernelbuild-qemu   # build kernel/build/qemu/kernel.elf (no hardware needed)
make kernelbuild-qemu-debug  # build kernel/build/qemu/kernel-debug.elf with DWARF info (no hardware needed)
make kernelbuild        # build every maintained kernel target (currently rpi5 + qemu)
make trustedbasecheck   # print unsafe/asm/forbid-trap-line counts (scripts/measure_trusted_base.py; depends on kernelbuild)
make kernelcheck-rpi5   # build and run the RPi5 hardware integration suite (needs real hardware)
make kernelcheck-qemu   # build and run the QEMU/AArch64 integration suite (no hardware needed)
make kernelcheck-shell-qemu # PTY smoke test for the interactive QEMU ash path (no hardware needed)
make kernelcheck-qemu-debug  # run the same QEMU suite against the DWARF build (no hardware needed)
make kernelcheck-alloc-rollback-qemu # GDB empties the page allocator for ONE acquisition inside scheduled_process_alloc, then checks the kernel's own end-of-run accounting says every pooled record and page came back (issue #414; no hardware needed)
make kernelcheck        # build and test every maintained kernel target (needs real RPi5 hardware for the rpi5 half)
make kernelsh-qemu      # boot QEMU and attach the current terminal to the ash UART
make kernelsh-rpi5      # load RPi5 over SWD and attach the Debug Probe UART to the ash shell
make linuxbuild         # build linux_user/'s host-native Linux/AMD64 tests (no QEMU/hardware needed)
make linuxcheck         # build and run linux_user/'s tests, diffing stdout against each .expected
make allbuild           # langcheck + test + linuxbuild + kernelbuild + every examples/ target, BUILD ONLY -- no execution/hardware step, so it needs no confirmation and nothing to wait on; the cheapest way to check "did this change break anything ANYWHERE in the repo"
make allcheck           # langcheck + test + linuxcheck + kernelcheck together (needs real RPi5 hardware for the last one)
make clean              # remove dune build artifacts, kernel/ link outputs, and linux_user/ build outputs
```

**Run `make allbuild` proactively, not just at the end.** It touches no
hardware and executes nothing, so it needs no confirmation and there is
no reason to save it for last. In particular:

- Before believing any change to `lib/*.ml` (a new type-checker rule, a
  codegen change, anything affecting how `.tkb` source compiles) is
  complete, run it -- `kernel/` alone is not the whole repo.
  `examples/` and `linux_user/` are separate trees with their own
  Makefiles and are easy to forget; a change validated only against
  `kernel/` can still break dozens of files elsewhere (this happened in
  the issue #316 session: a repo-wide `*io`/`unsafe` policy change was
  migrated and committed against `kernel/` only, and `examples/`'s ~410
  more sites were found only after the fact, by a human running `make
  allcheck` post-push). Run `make allbuild` BEFORE the first commit of
  such a change, not as a final check afterward.
- Prefer it over hand-rolled `grep`/regex surveys of "which files need
  updating" for a repo-wide change. A regex-based survey only finds the
  shapes it was written to look for; `make allbuild` finds everything
  that fails to compile, including shapes the survey's author did not
  anticipate (the same #316 session missed a struct-literal
  initializer's `*io` fields entirely -- a shape no grep pattern in use
  at the time matched -- until `make allbuild` caught it).

Examples-only targets (STM32/RPi3/QEMU milestones) all require
the `-f examples/Makefile` flag:

```bash
make -f examples/Makefile qemutest       # run QEMU plus host-side integration tests (build and verify automatically)
make -f examples/Makefile stm32build     # cross-compile every ported example for STM32F746G-DISCOVERY (no hardware needed)
make -f examples/Makefile check          # run langcheck + test + stm32build + qemutest together
make -f examples/Makefile hwcheck-stm32        # like stm32build, but also loads into RAM + UART-diffs against real STM32 hardware
make -f examples/Makefile hwcheck-stm32-net    # real-Ethernet hardware tests (needs the board's Ethernet port wired to this host)
make -f examples/Makefile stress-stm32-kvs-server-sdcard-rtos  # opt-in STM32 KVS concurrency stress test (not in allcheck)
make -f examples/Makefile hwcheck-rpi3   # opt-in Raspberry Pi 3B JTAG hardware integration test (not in allcheck, see examples/common_rpi3/AGENTS.md)
make -f examples/Makefile hwcheck-rpi3-net     # RPi3 real-Ethernet hardware tests (needs the board's Ethernet port -- behind its USB host stack, see examples/common_rpi3/AGENTS.md -- wired to this host)
make -f examples/Makefile hwcheck-rpi5   # opt-in RPi5 SWD + RP1-UART suite for the historical RPi5 example milestones (not kernel/ -- see kernelcheck-rpi5 above for that); reformats the attached USB drive, not in allcheck
make -f examples/Makefile hwcheck-rpi5-net     # RPi5 real-Ethernet tests for the same example milestones, including USB-backed HTTP/KVS persistence; reformats the attached USB drive
make -f examples/Makefile perfcheck      # real-hardware profiler smoke tests (not in allcheck -- shares phy_init's occasional link-negotiation flakiness with hwcheck-stm32-net, but adds no functional coverage beyond it)
make -f examples/Makefile allcheck       # build all examples targets (including RPi5), then run QEMU + STM32 lanes
make -f examples/Makefile clean          # remove examples/ build artifacts
```

**Parallel by default** (both `Makefile` and `examples/Makefile` set their own
`MAKEFLAGS += -j$(shell nproc)`): every `.tkb` example is an independent build, so
`make -f examples/Makefile check`/`stm32build`/etc. fan out across all cores with no flag
needed, same for `make kernelbuild`/`kernelcheck`. Pass `-j1` explicitly
(`make -j1 kernelcheck`, `make -f examples/Makefile -j1 check`) to force serial execution
back, e.g. when a build error's parallel-interleaved output needs to be read one recipe at a
time.
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
same reason). `$(TAKIBI)`'s rule in the root `Makefile` is now the ONLY place in the repo that
invokes `dune build` -- if a future change reintroduces a second, independent `dune
build`/`dune test` invocation anywhere in a `make -j` graph (rather than depending on
`$(TAKIBI)`/`build` like everything else does), expect this same class of flake to come back.
This is also why `examples/Makefile`'s own `build`/`test`/`$(TAKIBI)` targets don't call `dune`
themselves: they forward to `make -f Makefile build`/`test` in the root Makefile instead, so the
invariant holds even though the two Makefiles are separate `make` invocations.

**This predicted flake actually recurred (2026-08-13, `allcheck` output-locking attempt)**: a fix
for `allcheck`'s interleaved/garbled terminal output split its single `$(MAKE) langcheck test
linuxcheck kernelcheck` call into four separate recursive `$(MAKE) <target>` invocations (one per
lane), each piped through `scripts/run_line_locked.sh` for output locking. That looked harmless --
still one `allcheck` target, still parallel -- but each `$(MAKE) <target>` now starts its own
independent `make` process with its own dependency graph, so `$(TAKIBI)`'s "runs at most once"
guarantee (which depends on all four lanes sharing ONE graph) no longer held: up to four genuinely
concurrent `dune build` invocations raced on `_build/.lock`, and instead of the usual fast
non-deterministic failure, this manifested as a hard hang (`dune build` processes stuck at 0% CPU
for 15-29+ minutes, twice, both requiring a manual kill). **Fix that keeps the invariant**: don't
change `allcheck`'s call shape at all; instead make the leaf targets (`langcheck`, `test`,
`linuxcheck`) route their own recipe's underlying command (not a new `$(MAKE)` call) through the
shared output lock, e.g. `test: build` / `@bash scripts/run_line_locked.sh "$(LOCK)" dune test` --
`build` stays a normal prerequisite in the one shared graph, only the leaf command's output gets
locked. Lesson for output-interleaving fixes generally: locking output and preserving a shared
`make` dependency graph are two different problems: fix the first by wrapping the *underlying
command* in a recipe, never by adding a *new recursive `$(MAKE)` call* around it.

## Kernel Debugging: Use UART DDB First

The maintained kernel has a resumable, interrupt-safe UART debugger intended
for both humans and coding agents. When a QEMU or RPi5 failure leaves UART
alive, use DDB before adding temporary prints to scheduler, exception, or IRQ
paths. Start `make kernelsh-qemu` or `make kernelsh-rpi5`, then press Ctrl-T
followed by lowercase `b`. The host sends one finite serial BREAK; this is not
miniterm's indefinite Ctrl-T/Ctrl-B BREAK toggle. `make kernelcheck-ddb-qemu`
automates both real UART BREAK and software `brk` entry. The normal
`make kernelcheck-rpi5` suite verifies physical Debug Probe BREAK, inspection,
and resume after its ordinary workload.

The useful first-pass commands are:

- `regs`, `intr`, `sched`, and `current` -- saved CPU, interrupt-entry, and
  scheduler state;
- `ps` and `proc PID` -- the bounded process snapshot (`not captured` is not a
  claim that a PID does not exist when the snapshot says it was truncated);
- `vm` and `fds` -- the captured current process's address-space and bounded
  descriptor view;
- `trace` -- the older typed process-lifecycle tail;
- `events` -- the ftrace-inspired Takibi per-CPU diagnostic rings. Read each
  CPU independently; there is deliberately no claimed total order between
  CPUs. Treat `damaged` and `overwritten` as evidence loss, not as valid
  records. Fixed event ids are 16-bit and build-checked for collisions;
- `xk ADDRESS [COUNT]`, `xp PHYSICAL [COUNT]`, and
  `xu PID ADDRESS [COUNT]` -- fault-contained reads of managed ordinary RAM.
  They reject MMIO and non-RAM storage rather than performing a potentially
  state-changing "read";
- `oops` for the retained crash view and `continue` to resume through the
  compiler-defined saved exception frame.

DDB remains allocation-free, bounded, polling-only, and inside the interrupt
effect rules. Do not call ordinary logging, allocation, locks, sleeping,
filesystem, network, or scheduler operations from its call graph, and do not
add an effect exemption for debugger code. Memory/register mutation, general
expressions, and an in-kernel GDB remote protocol are intentionally absent
until a concrete debugging case justifies their separate safety costs.
Backtracing is also deferred: a plausible but incorrect AArch64 unwind is
worse evidence for an automated debugger than raw PC/LR plus structured
snapshots. `kernel/README.md` is the authoritative command and implementation
reference.

## Directory Layout

**This map is deliberately kept at directory granularity.** It used to carry a
line per file, and that list had silently gone stale: on 2026-08-26 it was
missing eight `lib/*.ml` files (including `monomorphize.ml` and
`value_facts.ml`), nine of the ten `scripts/check_*.py` files, `docs/`, and the
entire `kernel/` tree -- the primary development target. A reader using it as
an index would have concluded those did not exist, which is worse than having
no index. What an individual file does belongs in that file's own leading
comment, where it cannot drift away from the code it describes.

So: when you add a directory, add it here. When you add a file, write its
leading comment. `scripts/check_agents_paths.py` (run by `make langcheck`)
fails the build if this file names a path that no longer exists.

### The compiler

- `lib/` -- the compiler library: lexing/parsing, HM-style inference, and on
  top of it the refinement, effect, ownership, static-index, privacy, and
  authority-region checks, struct/enum layout, monomorphization, and LLVM IR
  generation. Two properties of this directory are load-bearing and invisible
  from a file listing. First, `type_inf.ml` and `llvm_gen.ml` independently
  re-derive several things (sizeof/offsetof, literal materialization, struct
  field indexing), so a change to one is usually a change to both --
  `scripts/check_compiler_sync_rules.py` encodes the pairs that must move
  together. Second, struct layout has three implementations
  (`type_layout.ml`, `llvm_gen.ml`'s own size computation, and LLVM's
  DataLayout); `Type_layout.check_against_codegen` fails the build when they
  diverge.
- `bin/main.ml` -- the `takibi` CLI. Its own usage string is the authoritative
  flag list; do not mirror it here. The flags that carry a project rule rather
  than a mechanism are `--forbid-trap` (see "Development Process: Write `.tkb`
  Code Under `--forbid-trap` From the Start"), `--forbid-unsafe`, `-g`, and
  `--emit-depfile` (see "Build Commands").
- `test/` -- Alcotest unit tests for the compiler, in a single
  `test_takibi.ml`. Roughly 500 of its cases are `expect_type_error` /
  `expect_codegen_error` negatives; see "Where Should a New Test Go?" for what
  belongs here versus in a runnable example. Use
  `scripts/list_dune_test_failures.sh`, not bare `dune test`, when more than
  one case fails.

### The targets

- `kernel/` -- the standalone kernel, and the primary development target. Its
  subdirectories follow Linux's names (`kernel/arch/`, `kernel/drivers/`,
  `kernel/fs/`, `kernel/init/`, `kernel/kernel/`, `kernel/lib/`, `kernel/mm/`,
  `kernel/net/`, `kernel/platform/`, `kernel/printk/`, `kernel/tests/`). It has
  its own documentation set, which is authoritative over anything said here:
  `kernel/README.md`, `SYSCALLS.md`, `MEMORY_MAP.md` (build-checked by
  `scripts/check_kernel_memory_map.py`), `RESOURCE_LIMITS.md`, and
  `RUNTIME_STATE.md`. See "Maintenance Scope: `kernel/` and `linux_user/`".
- `examples/` -- one directory per example, each a single `.tkb` file compiled
  unmodified for every target; read that file's leading comment for what it
  demonstrates. The four `common_*` HAL directories mirror each other's
  function names and signatures exactly, which is what lets a single example
  file build everywhere, and each has its own `AGENTS.md` carrying that
  target's bring-up detail:
  - `examples/common/` -- platform-agnostic logic with no MMIO or assembly dependency.
  - `examples/common_qemu/` -- QEMU/AArch64 virt (`examples/common_qemu/AGENTS.md`).
  - `examples/common_stm32/` -- STM32F746G-DISCOVERY, Cortex-M7
    (`examples/common_stm32/AGENTS.md`).
  - `examples/common_rpi3/` -- Raspberry Pi 3B, BCM2837, JTAG-only bring-up, including a
    from-scratch USB host stack (`examples/common_rpi3/AGENTS.md`).
  - `examples/common_rpi5/` -- Raspberry Pi 5, BCM2712, RP1 PCIe/UART/xHCI, SMP, EL0/EL1
    (`examples/common_rpi5/AGENTS.md`).

  Where a file inside these exists only to resolve a cross-target name
  collision or a shared-file dependency (`gic_regs.tkb`, `stm32_stub.tkb`,
  `uart_irq_stub.tkb`, `eth_sdmmc_regs.tkb`, `semihosting_stub.S`), the reason
  is in that file's own header comment.
- `linux_user/` -- x86_64 Linux userspace, built and run through the root
  Makefile's `linuxbuild`/`linuxcheck`, not `examples/Makefile`. Deliberately
  self-contained: nothing here `use`s anything under `examples/`, and it keeps
  its own copies of the shared `examples/common/` sources under
  `linux_user/common/` rather than sharing them. See
  "Maintenance Scope" and "Where Should a New Test Go?", including the
  "copy, don't blindly move" rule for tests that also run on real hardware.

### Everything else

- `scripts/` -- build checks, test harnesses, and hardware runners, by naming
  convention: `check_*.py` are build-time checks (list below), `run_hwtest_*.sh`
  drive a real board for the matching `make hwcheck-*` target, `*_uart_dev.sh`
  resolve a probe's serial device by its stable `by-id` identity rather than by
  ttyACM number, `*_test.py` are host-side network/protocol test drivers,
  `check_suite_output.py` splits one batched UART stream into per-case fixture
  comparisons, and
  `profile_*` are the PC-sampling profiler's pieces. Which script a `make`
  target runs is in the Makefile, which is the thing that cannot go stale.
- `docs/` -- durable technical knowledge that outlives the session that
  produced it; see `docs/README.md` for what qualifies.
- `img/` -- project icons.

### Build checks

Each of these fails the build rather than warning. They are listed here because
being a complete list is the whole point of this one;
`scripts/check_agents_paths.py` enforces that completeness.

| Check | What it refuses to let through |
| --- | --- |
| `check_agents_paths.py` | a path named in `AGENTS.md` that no longer exists, or a `scripts/check_*.py` this file never names |
| `check_compiler_sync_rules.py` | a `sync rule` comment in `type_inf.ml` or `llvm_gen.ml` with no counterpart reference in its peer |
| `check_kernel_asm_invariants.py` | hand-written kernel assembly, disassembled from the built ELF, that breaks an EL0 entry/exit invariant (issues #229/#231) |
| `check_kernel_lib_limitations_header.py` | a `kernel/lib`, `kernel/kernel`, or `kernel/net` file with no "Current limitations" header |
| `check_diagnostic_event_ids.py` | duplicate or non-16-bit fixed diagnostic event ids |
| `check_flag_guarded_fields.py` | a read of an optional field `X` that did not consult its paired `has_X` first |
| `check_kernel_memory_map.py` | a build whose layout disagrees with `kernel/MEMORY_MAP.md` (`--update` rewrites the rows instead) |
| `check_kernel_log_expectations.py` | a host-side test driver waiting for a boot-log line the kernel no longer emits |
| `check_pool_release_paths.py` | a kernel pool with no path that gives a record back |
| `check_qemu_lane_ports.py` | two QEMU lanes claiming the same protocol and port |
| `check_raw_pos_fname.py` | a raw `Lexing.pos_fname` read outside the identity-preserving helpers |
| `check_stale_depfiles.py` | a generated kernel depfile naming a prerequisite that has been deleted |
| `check_user_payload_no_rw_globals.py` | a writable global in the flat EL0 payload, whose blob is mapped RX-only |

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

- **A literal-only `<<`/`>>` shift by an amount >= the operand's actual bit width could silently
  produce LLVM `poison` until issues #232 and #234's fixes; now a hard compile error.** `lib/
  llvm_gen.ml`'s `IntLit` codegen defaults a literal with no usable type hint to i32 width; `BinOp`
  used to drop its own `?expected_ty` entirely when evaluating its operands, so a literal buried
  inside a `BinOp` (e.g. `2 << 32` inside `let tcr: usize = 0x351b | (1 << 23) | (2 << 32);`)
  always fell back to that i32 guess even when the enclosing context was `usize` -- `shl i32 2, 32`
  is undefined (shift amount >= the operand's own bit width). Issue #232 fixed the specific
  wrong-width case by forwarding the current `BinOp` node's own hint into its operand recursion,
  restricted to i32-or-wider plain integer types (`TypeI32`/`TypeI64`/`TypeU32`/`TypeU64`/
  `TypeIsize`/`TypeUsize`). `i8`/`u8`/`i16`/`u16` are deliberately excluded from that forwarding:
  this compiler widens narrow *non-literal* operands (a loaded byte) to i32 for actual bitwise
  arithmetic elsewhere in the same lowering, and forwarding a narrow hint here would make a literal
  *sibling* materialize directly at i8/i16 instead of also being promoted -- found by an internal
  LLVM-IR-verifier rejection (`shl i32 %x, i16 8`, mismatched operand widths) while testing the
  first, unrestricted version of that fix. That exclusion left a residual gap: a literal-only shift
  feeding a narrow-typed context directly (e.g. `let x: u16 = SOME_LITERAL << 40;`) could still
  exhibit the original poison, since its base still materializes at i32.
  Issue #234 closes this at the codegen level with a genuine compile-time proof rather than another
  width-forwarding patch: right before `Shl`/`Shr` codegen, once `v1`'s width has already been
  resolved by the widening/hint logic above, a statically-known (literal) shift amount is checked
  against `integer_bitwidth (type_of v1)` -- the ACTUAL LLVM width the shift executes at, not the
  AST-level nominal type -- and rejected as a hard `Llvm_gen.Error` if out of `[0, width)`. This
  closes the narrow-context gap too (the i32-materialized base makes 40 >= 32 an error regardless
  of the nominal `u16` type). A genuine *runtime* shift amount (a variable, not a literal) is
  unchecked -- proving that in range needs real range-inference on the amount's own bounds, out of
  scope for #234. See HISTORY.md's issue #232 and #234 entries for the full diagnosis, the two
  real-hardware `kernel_mmu_activate()` writes (`TCR_EL1`, `TTBR0_EL1`) #232's bug silently
  corrupted before being caught by disassembly, and #234's verification.
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
- **EL0 fail-stop is intentional design, not a bug to route around.**
  `kernel/arch/arm64/kernel/exception_evidence.tkb`'s `el1_exception_evidence` (ordinary `.tkb` since
  issue #227 item 3; previously hand-written in `kernel/arch/arm64/boot/entry.S`) is the landing site
  for any EL0 synchronous exception `kernel/arch/arm64/kernel/user_entry.S`'s `el0_sync_entry` doesn't
  recognize as either a real SVC or its one other handled case, a translation fault from legitimate
  process-image stack growth (process_image_handle_data_abort, the real growable-stack mechanism
  that replaced the original single-page-stack limitation) -- a genuine hardware fault (bad
  instruction fetch, an unhandled data abort, an instruction that is UNDEFINED at the faulting EL)
  captures a fixed .bss CrashSnapshot and then parks in wfe forever. The UART oops report names
  ESR/FAR/ELR/SPSR, decoded data-abort access when applicable, live SP_EL0/TPIDR_EL0/TTBR0,
  process/parent/state/wait/image/root/ASID, the matching saved ExceptionFrame fields when a
  Lower-EL frame exists, and a bounded local process/scheduler trace. Current-EL vector faults
  explicitly report that no saved frame exists. valid is written last and sequence changes per
  capture, so a debugger can distinguish a retained crash from zeroed/stale storage. Capture is
  allocation-free and recursively faults only into a minimal UART fallback plus park. Use
  kernelcheck-oops-qemu for the deterministic EL0-BRK regression; GDB injects the instruction
  and reads the retained object only, while the kernel produces the diagnostic. For an interactive
  post-mortem, source _build/kernel-crash-snapshot-layout.gdb and then
  scripts/kernel_crash_snapshot.gdb in gdb-multiarch and run takibi-oops; it reads the
  compiler-generated snapshot layout rather than duplicating the ExceptionFrame ABI.
  **Known gap, not yet triggered by any current
  scenario:** `process_image_clone_vm_begin()` (the fork/clone path, as opposed to
  `process_image_map_current()`) never initializes root 1's demand-stack metadata
  (`process_image_stack_growth_active[1]`/`process_image_stack_lowest_l3[1]`), so a forked child
  that grows its stack past what the parent had already faulted in before the fork would hit this
  fail-stop path instead of growing (see HISTORY.md's issue #209 entry).
- **Every `eret` that returns to EL0 must mask `DAIF.I` before its last `msr ELR_EL1`/`msr SPSR_EL1`,
  with nothing but more `msr`s in between.** An interrupt taken between those two writes (or after
  them but before the `eret`) makes the hardware overwrite both with the interrupting context's own
  values; the `eret` then returns to the wrong place with the wrong PSTATE. This is exactly issue
  #229 (HISTORY.md, 2026-08-06): `.Lsyscall_dispatch` unmasking `DAIF.I` for the syscall-handling
  window (issue #187) turned every ordinary syscall return into this race, intermittently (~25-40%
  of boots) dropping EL0 into kernel `.text`. There are six `eret`s in this codebase today, all
  masked: three via `EXC_CONTEXT_RESTORE` itself (`kernel/arch/arm64/kernel/exception_context.inc`,
  used by `el1_current_irq_entry`/`el0_irq_entry`/`.Ldata_abort`), and `el0_context_resume`/
  `run_initial_user` (`kernel/arch/arm64/kernel/user_entry.S`) directly, each one instruction
  earlier than its own first `ELR_EL1`/`SPSR_EL1`/`SP_EL0` write for the same reason `EXC_CONTEXT_
  RESTORE` does. `el2_drop_to_el1`'s `eret` (`kernel/arch/arm64/boot/entry.S`) is the seventh and
  is not exposed to this: it is a one-time cold-boot EL2->EL1 drop that runs before any interrupt
  source is ever unmasked, and it sets `DAIF` masked directly in the `SPSR_EL2` value it writes.
  When adding a new `eret` site, mask `DAIF.I` first (or route through `EXC_CONTEXT_RESTORE` if the
  frame shape matches) before assuming this is handled. `scripts/check_kernel_asm_invariants.py`
  (run automatically by `make kernelbuild-rpi5`) disassembles the linked `kernel.elf` and fails the
  build if any `eret` that writes `ELR_EL1` lacks a preceding `msr DAIFSet` in the same function --
  a real, automated, zero-hardware regression guard for this exact bug, not just a reviewer
  reminder. A permanent EL0-side probe (deliberately branching into kernel `.text` as the kernel's
  own final action) was tried first and reverted: building a "safety" mechanism out of MORE
  hand-written assembly grows the exact unverified-by-the-compiler surface this whole entry is
  about, and the first version of that probe was itself nearly shipped with a wrong address
  computation (a PC-relative `adr` inside code that gets copied to a different execution address)
  found only by re-deriving the encoding by hand and cross-checking against real hardware --
  precisely the review burden a static, external, .S/.tkb-free check avoids growing further. This
  is not something the compiler enforces at the language level, since `entry.S`/`user_entry.S` remain
  hand-written assembly outside the `.tkb` type system's reach for everything except the fail-stop
  evidence capture, the vector table, and the two Current-EL-SPx/Lower-EL-AArch64 IRQ entry points
  (see ROADMAP.md's M4/#227 for the actual structural fix: declaring the exception frame and vector
  table in `.tkb` too -- issue #227 item 3, moving `el1_exception_evidence` to ordinary `.tkb`, and
  item 2, declaring the vector table itself as `kernel/arch/arm64/kernel/vector_table.tkb`'s
  `vector_table { N => target; ... }`, are both done). **Item 1 (declaring the exception frame and
  generating save/restore) has a working prototype slice, not the full item**: `kernel/arch/arm64/
  kernel/exception_frame.tkb`'s `struct packed ExceptionFrame` (a closed AArch64 register-name field
  set, `x0`..`x30`/`sp_el0`/`elr_el1`/`spsr_el1`/`q0`..`q31`/`fpsr`/`fpcr`) plus `exception_entry el1_
  current_irq_entry { ... }` / `exception_entry el0_irq_entry { ... }` now generate those two entries'
  full save/[before]/dispatch/restore/`eret` sequences (`lib/llvm_gen.ml`'s `gen_exception_entry`,
  same raw-module-asm technique as the vector table -- turned out `naked` was never needed for this,
  contrary to the original worry about spilling registers before any calling convention exists).
  **Both gaps the first prototype slice left open have follow-up work, one closed and one
  re-scoped, not left as-is**: (1) `dispatch`/`before` are now checked against their REAL signature
  (`fn(usize) -> usize` / `fn()`), not just existence -- a second `type_inf.ml` pass runs after `fenv`
  is built specifically for this (the earlier per-item validation pass runs before `fenv` exists).
  (2) Of the three standalone-restore call sites originally named together (`.Ldata_abort`/
  `el0_context_resume`/`run_initial_user` in `user_entry.S`), only `el0_context_resume` actually fits a
  declarative "restore a saved frame" pattern -- `run_initial_user` constructs a synthetic resume state
  directly from raw entry/stack arguments (never a full saved frame), and `.Ldata_abort` is inline
  control flow inside `el0_sync_entry`'s own larger dispatch body, not a standalone entry point; neither
  is expressible this way without a different design each would need on its own. A new `exception_restore
  name { frame: FrameStruct; }` declaration now generates `el0_context_resume` specifically (just the
  restore-frame/`eret` half, entered with the frame address already in `x0`). **Refactoring the restore
  codegen to be shared between `exception_entry` and `exception_restore` surfaced a real ordering bug
  before it ever reached hardware**: `el0_context_resume` MUST mask `DAIF.I` before switching `sp` to the
  resumed frame's stack (it is reached via the syscall path, which unmasks `DAIF.I` deliberately, so an
  interrupt in that window would build its own frame below the wrong stack), while `exception_entry`'s
  own generated code safely does it in the OPPOSITE order (mask AFTER the switch) because `DAIF.I` is
  already masked for its entire IRQ-handler body -- the two call sites are not symmetric, and a naively
  shared "always mask first" or "mask wherever" helper would have gotten one of them wrong. Caught by
  reading `el0_context_resume`'s own existing comment closely while wiring the refactor up, not by a
  hardware failure. See HISTORY.md's issue #227 item 1 entries (the original prototype and this
  follow-up) for the full design and verification (real-hardware `kernelcheck-rpi5`, including the
  `fpsimd` view for the q0-q31/FPSR-survives-a-real-interrupt property, and `syscall`/`child_exec` for
  `el0_context_resume`'s own corrected ordering).
  **(3) 2026-08-13, issue #286: the frame's OFFSET constants are no longer hand-maintained either.**
  `bin/main.ml`'s `--emit-exception-frame-offsets <StructName>` flag calls the compiler's own
  `Llvm_gen.exception_frame_offsets` -- the same function `exception_entry`/`exception_restore` codegen
  already uses -- and writes GAS `.equ` constants directly, generating `kernel/arch/arm64/kernel/
  exception_context_offsets.inc` (gitignored), which the hand-written, git-tracked `exception_context.inc`
  `.include`s. A prior version of this generation step lived in a separate Python script that
  independently re-parsed the struct's `.tkb` syntax and reimplemented the same layout algorithm; that
  duplication caused a real (if latent) bug before being replaced by this compiler flag. The
  SAVE/RESTORE macro BODIES in `exception_context.inc` remain hand-written -- that is what "prototype
  slice, not the full item" above still refers to -- but `scripts/verify_exception_frame.py` now checks
  those macros do byte-range-complete save/restore of every struct field (not just a fixed list), catching
  both a placeholder/empty macro body and a field silently left uncovered by a future struct edit. See
  HISTORY.md's 2026-08-13 entry for the full incident this hardening responds to.
- **The same D-cache-bypass gap applies to postmortem debugging over SWD, not just DMA/harness I/O --
  and is closed for CrashSnapshot itself.** `el1_exception_evidence` (now ordinary
  `.tkb`, `kernel/arch/arm64/kernel/exception_evidence.tkb`, moved off hand-written assembly by
  issue #226's `mrs_esr_el1`/`mrs_far_el1`/`mrs_elr_el1`/`mrs_spsr_el1` intrinsics) records those four
  registers, process context, saved-frame summary, bounded trace, and the trapped vector slot into a fixed
  `CrashSnapshot` global before parking in `wfe`, intended as a postmortem evidence block readable via
  `openocd` or scripts/kernel_crash_snapshot.gdb. Found during the issue
  #209 child-exec bring-up (2026-08-05, see HISTORY.md) that these reads could return a stale,
  earlier-boot value while the CPU's actual writes were still dirty in D-cache -- the block claimed
  `ESR=0, ELR=0` while the halted core's own `ESR_EL1`/`ELR_EL1` (read via `reg ESR_EL1` etc., from the
  debug context, not RAM) showed a real, different fault. Issue #227 item 3 closes this specific gap:
  the `.tkb` version calls `dma_prepare_tx` (a cache CLEAN/write-back, reused here purely for its
  cache-maintenance side effect, not as a DMA operation) on the block immediately after writing it, so
  the dirty line is flushed to memory before the `wfe` park. Verified on real RPi5 hardware
  (2026-08-06): a deliberately injected EL1 Data Abort (write through an unmapped `0xffff...` pointer)
  produced a `slot`/`esr_el1`/`far_el1`/`elr_el1`/`spsr_el1` block read over SWD with D-cache still
  enabled that exactly matched the injected fault (`far_el1` == the bad pointer, `elr_el1` == the
  faulting `str`'s own address from `llvm-objdump`, `esr_el1`'s EC/WnR/DFSC fields all consistent with
  a same-EL write-translation-fault) -- no staleness observed. **The general guidance still stands as a
  second, independent cross-check** (reading the parked core's live system registers directly via `reg
  ESR_EL1`/`ELR_EL1`/`SPSR_EL1` costs nothing and catches a *different* class of bug -- e.g. a future
  change that reintroduces an unflushed write path elsewhere), but the `CrashSnapshot` block
  itself is no longer known to go stale. A same-value-every-boot "coherence check" (e.g. diffing a
  static struct that is written identically on every run) still cannot detect staleness in general and
  must not be used to argue an unverified read is fresh.
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

## Debugging Techniques That Have Paid Off Here

Collected from real incidents in this tree, each of which cost hours the
first time. HISTORY.md has the full story behind each; this is the index
so it is findable while you are stuck rather than only afterwards.

**Re-read the evidence you already have before running another
experiment.** Issue #237's virtio work spent hours testing hypotheses and
found nothing; a fresh read of the SAME diagnostic output, with no new
run, found the bug in one pass. Ask what the data you already collected
would say if you had not already decided what it meant.

**Bisect a cheap proxy, not the expensive reproduction.** An
`examples/dwarf_debug` failure needed QEMU plus gdb to observe. What
actually changed was one number -- how many instructions the prologue
was -- so the bisection was "build the compiler at commit X and print
which source line the address eight instructions past the breakpoint
belongs to", three lines of Python, seconds per commit, culprit named in
one pass over seven candidates. An expensive reproduction usually sits
downstream of a cheap invariant.

**A fix that merely stops a perturbation-sensitive reproducer proves
nothing.** Issue #373 stopped reproducing when an unrelated compiler
change landed, and that was reported as a fix. It was not: the bug was
sensitive to memory layout, so ANY change of similar size silenced it.
Verify against the mechanism (a measurement, a canary, an invariant),
never against "the failing test stopped failing".

**When a network test flakes, suspect the harness's readiness assumption
before the protocol code.** Three flakes in this tree so far: one was
genuinely `tcp.tkb`, two were the host-side harness starting before the
kernel or the PHY was ready. Check what the runner waits for -- often
nothing -- before reading the stack.

**A value's accidental properties have readers you never declared -- grep
the SHAPE, not the name.** Three times in one week's work (issues #392,
#390, #399), changing what a value IS broke a consumer nobody had written
down:

| value | its stated meaning | the reader nobody declared |
|---|---|---|
| a process slot | index into the process table | `pid = slot + 1`, at about twenty sites |
| a page's last 128 bytes | the allocator's owner metadata | already the pool's own chunk header, for a one-page chunk |
| `intrusive_pool`'s `pool_tag` | an identity, compared for equality | an array index AND a bit position, in a `linux_user` checker |

Grepping the NAME finds none of them, because the dependency is
arithmetic. Grep for the shape instead -- `+ 1`, `- 1`, the value used as
`[index]`, `1 << value`, bare small literals where the value belongs --
before changing what a value means. And expect the fix to be "delete the
second reader's assumption", not "preserve the accidental property": all
three went that way. In all three it was a test that failed loudly, not a
careful reading, that found it.

**Instrument the OTHER side.** Issue #392's last stage looked exactly like
a lost SYN-ACK: the host peer sent 30 SYNs and saw nothing. Three
kernel-side hypotheses were refuted one probe each (IRQs masked? RX ring
starved? memory corrupted?) before the peer itself was made to print what
it received -- and it had received every SYN-ACK, byte-correct, just after
it had given up. The kernel was ten seconds late to `listen()`. When a
test has two sides, the side you are not changing is where the cheap
answer usually is.

**Measure an invariant before enforcing it, and prove the counter can
fire.** Issues #401 and #406 each replaced a picked constant with a
computed bound. Both landed first as a counter that ALLOWED the violation,
run over the whole boot suite; both then ran a deliberately-wrong bound to
confirm the counter was reached at all. Without that second run, "zero
violations" and "the code is unreachable" are the same observation. #406's
first run reported two violations, and both turned out to be the probe
forging a count to test the constant it was about to lose -- which is also
why the recording belongs at the real caller, not inside the primitive a
probe drives.

**Grep the whole repo before calling code dead.** A whole-program build
means callers live in other subtrees, and `examples/` and `linux_user/`
have their own Makefiles. `make allbuild` finds what a regex survey does
not: it compiles everything and reports every shape that broke, including
the ones nobody thought to look for.

## Debug Info and Execution Profiling (QEMU)

`-g` emits full DWARF intended to be useful in real `gdb-multiarch`
sessions, not just to satisfy `llvm-dwarfdump`. The historical live QEMU/GDB
fixture is `examples/dwarf_debug/dwarf_debug.tkb`, with normalized expected
output in `examples/dwarf_debug/dwarf_debug.gdb.expected` and the harness in
`scripts/run_qemutest.sh`. The maintained full-kernel regression is
`make kernelcheck-qemu-debug`: it compiles `kernel-debug.elf` with `-g`, then
runs the ordinary QEMU view and ash TCP suites with separate ports and
artifacts from the non-debug lane.

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

- Follow the repository-wide "Agents Commit, Humans Push" workflow above.
- Prefer idiomatic OCaml style. Use `Map.Make(String)` over `Hashtbl`.
- Do not use the `base` package (it causes friction at the boundary with LLVM bindings).
- The user is an OCaml beginner, so explain the reason for code changes from the perspective of "why write it this way."
- **Do not save durable project guidance to tool-specific memory stores.** Consolidate project-specific information in `AGENTS.md` so it can be shared across agent environments.
- **All text in this repository must be ASCII-only.** Never write Japanese or any other non-ASCII characters in source files, comments, documentation, or any other file. `make langcheck` enforces this and will fail if non-ASCII characters are found.
- **Follow YAGNI (see "Design Principle: YAGNI" above).** Do not design or implement functionality beyond what the current, concrete task needs. If a request seems to call for more than that, flag the tradeoff and ask before building it.
- **New `.tkb` code under `kernel/`: write it with refinement types and `--forbid-trap` enabled from the start** (see "Development Process: Write `.tkb` Code Under `--forbid-trap` From the Start" above). Only fall back to the old prove-first-then-harden process for a milestone whose hardware/protocol behavior is not yet understood (a genuinely new peripheral, a first-of-its-kind DMA/cache interaction, a new board's earliest bring-up) -- ask if it is unclear which situation applies. Never "fix" a flagged `--forbid-trap` site by switching it to a raw pointer. The historical `examples/` tree is changed only under the explicit exception in "Maintenance Scope: `kernel/` Only" above.
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
