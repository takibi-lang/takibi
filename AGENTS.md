# takibi

Takibi is a self-made language compiler written in OCaml 5.4.0. It generates
native machine code through an LLVM 19 backend.

The project's ultimate goal is to demonstrate that runtime errors in a
monolithic Unix-like kernel can be lifted into compile-time errors using
refinement types, affine or linear ownership, and eventually SMT-backed proof
obligations. Kernel memory corruption is often silent and security-relevant,
so compile-time proof is the product goal rather than an optional hardening
layer.

`SPEC.md` is authoritative for current language syntax and semantics.
`HISTORY.md` records past engineering decisions and investigations. Do not
turn this file back into an engineering log.

## Maintained scope

The standalone kernel under `kernel/` is the primary product surface. New
kernel features, fixes, fixtures, and target code belong there.

`linux_user/` is maintained for fast native Linux/AMD64 programs whose verdict
is independent of real timing, interrupts, caches, MMIO, and concurrency. It is
appropriate for executable compiler or language tests and pure algorithms.

The `examples/` tree contains historical STM32 and RPi5 code. We occasionally
test only its STM32 side with `make -f examples/Makefile allcheck`. Do not add
features or parity updates there unless the user explicitly requests a change
to a historical artifact; its nested `AGENTS.md` contains the detailed policy.

Do not expand a kernel task into compiler, root build-system, or other
non-`kernel/` and non-`linux_user/` work without a separate concrete
requirement and explicit user direction.

## Always-on project rules

- Detect errors at compile time. A compiler-detected invalid, dangerously
  ambiguous, or invariant-breaking construct is an error by default, not a
  warning used for gradual migration.
- Do not record a class of defect as permanently beyond compile-time checking.
  Re-examine each new instance on its own merits, even when a superficially
  similar one was previously judged out of reach.
- Not every prevention has to become a compile-time error. Ask what a
  build-time check under `scripts/` would catch and what it would miss; ship
  that when it catches the instance that actually occurred, and pursue the
  language-level version once its misses are themselves observed.
- When readability suffers from a language limitation rather than a one-off,
  propose extending the syntax before extracting a shared helper. Helpers
  accumulate divergent variants and stop being shared.
- Embedded production code must not retain traps or panics. Never use raw
  pointers or `unsafe` merely to bypass a checked access.
- Follow YAGNI. Implement present requirements, not plausible future
  infrastructure. If a request appears speculative, explain the tradeoff and
  ask before building the more general design.
- All tracked text and all GitHub text must be English ASCII. `make langcheck`
  enforces the repository side.
- Preserve unrelated user changes in a dirty worktree.
- Durable current behavior belongs in maintained documentation or scoped
  guidance; historical rationale belongs in `HISTORY.md`.
- Do not store durable project guidance in tool-specific memory.

## Shared physical hardware

The STM32 and Raspberry Pi 5 boards are shared laboratory equipment that the
maintainer also uses outside any agent session. Notify the maintainer and get
agreement before running anything that drives them, every time. A past
statement that a board was available is not standing permission for a later
command. The Raspberry Pi 3B is free to use without asking.

Treat any target whose name contains `allcheck`, `hwcheck`, or `kernelcheck`
as hardware-touching, because those aggregates reach the hardware lanes even
when the change under test is unrelated. `make allbuild` and the
`*build`/`langcheck`/`linuxcheck`/`*-qemu` targets execute no hardware and are
always safe. Knowing this rule is not the same as remembering it while typing
a convenient aggregate target: prefer the specific lane.

## Concurrent agents and the working tree

More than one agent, plus the maintainer, may work in this repository at the
same time. Interleaved commits by another author, and rebases that change the
hashes of commits already made locally, are expected rather than incidents.
Re-check `git status` and `git log` before relying on an earlier build or test
result, and do not treat recent local commits as exclusively yours when
considering a destructive git operation.

## Required routing

Read the applicable nested guidance before editing these trees:

- `lib/AGENTS.md` for compiler synchronization, diagnostics, and target
  limitations.
- `kernel/AGENTS.md` for maintained kernel implementation rules.
- `kernel/arch/arm64/AGENTS.md` for AArch64 exception and return invariants.
- `examples/AGENTS.md` for historical artifacts.

Use these cross-agent skills when the task matches. Codex reads the canonical
entrypoint under `.agents/skills/`; Claude Code has a matching entrypoint under
`.claude/skills/` that routes to the same instructions.

- `write-takibi`: before adding or substantially changing maintained `.tkb`
  code, including refinement, unsafe, bounds, variants, or trap questions.
- `add-takibi-test`: before adding, moving, or choosing a compiler,
  `linux_user`, QEMU, or hardware test.
- `debug-kernel`: before diagnosing a kernel hang, crash, boot failure,
  exception, intermittent failure, QEMU failure, or RPi5 hardware failure.
- `profile-qemu`: for QEMU/AArch64 PC-sampling or hot-spot measurement.
- `github-workflow`: for GitHub issue operations, Found-by selection, and
  issue-closing commits.

If UART remains responsive during a kernel failure, use DDB before adding
prints to scheduler, exception, IRQ, VM, or process paths. QEMU cannot validate
physical cache coherence, real interrupt timing, or hardware concurrency.

## Git and GitHub safety boundary

Agents stage and commit each completed unit without waiting to be asked, but
must never run `git push`, merge remotely, or publish commits. The human
maintainer owns that gate. Use `gh` for GitHub operations; do not use GitHub
connectors or MCP tools.

Use the identity of the agent making the commit, applied only to the individual
`git commit` invocation. Never change repository or global Git identity:

- Codex: `OpenAI Codex <codex-agent@takibi.invalid>`
- Claude Code: `Anthropic Claude Code <claude-code-agent@takibi.invalid>`
- GitHub Copilot CLI: `GitHub Copilot CLI <copilot-cli-agent@takibi.invalid>`

Every GitHub issue has a `Found-by:` field. A commit that closes an issue has a
`Found-by:` trailer. Also record one for a defect found and fixed within a
single session. Use `github-workflow` for the allowed values and procedure.

Do not put live status such as "tracked in" or "completed by" issue references
in tracked files. `HISTORY.md` may record stable past events and `ROADMAP.md`
may enumerate its dated plan; current documentation must be correct without
GitHub access.

## Takibi implementation summary

New maintained `.tkb` work starts with refinement types and `--forbid-trap`.
Use refined bounds or explicit local narrowing for checked indexing; a
remaining bounds check means the proof is incomplete. A genuinely unknown
hardware or protocol bring-up may use the explicit baseline-then-harden
exception described by `write-takibi`.

Fallible operations return closed variants rather than integer or boolean
sentinels. Use `must_use variant` when ignoring the result must be rejected.
Callers match every outcome explicitly.

When language behavior changes, update `SPEC.md` and all affected maintained
callers in the same change. Use `add-takibi-test` to choose the correct test
tier.

## Testing and builds

Use the root Makefile for maintained surfaces:

```bash
make build              # compiler only
make test               # compiler unit tests
make langcheck          # repository policy and ASCII checks
make linuxbuild         # build native executable tests
make linuxcheck         # build and run native executable tests
make kernelbuild        # build QEMU and RPi5 kernels
make kernelcheck-qemu   # run maintained QEMU integration tests
make kernelcheck-rpi5   # run maintained RPi5 hardware tests
make kernelcheck        # run all maintained kernel tests
make allbuild           # build every target without hardware execution
make allcheck           # run maintained checks, including RPi5 hardware
make clean
```

Run `make allbuild` before the first commit of a compiler-affecting change. It
is the build-level proof that callers in different trees still compile; do not
replace it with a regex survey.

A build-level negative control must prove independently that the command exited
nonzero and that output contains the expected diagnostic. Prefer an in-process
compiler rejection test when the build system is not itself under test.

Detailed test-tier rules live in `add-takibi-test`. Detailed kernel commands
live in `kernel/README.md` and the relevant debugging skill. The Makefiles are
authoritative for the current target graph.

## Repository map

- `lib/`: compiler library. See `lib/AGENTS.md`.
- `bin/`: the `takibi` CLI; its usage string is the authoritative flag list.
- `test/`: Alcotest compiler tests.
- `kernel/`: maintained standalone kernel. See `kernel/AGENTS.md`.
- `linux_user/`: maintained native executable tests.
- `examples/`: historical artifacts. See `examples/AGENTS.md`.
- `scripts/`: build checks and test or hardware runners.
- `docs/`: durable current technical knowledge.
- `img/`: project images.

`docs/BUILD_CHECKS.md` is the complete build-check inventory.
`scripts/check_agents_paths.py` verifies that paths named here exist and that
the inventory names every `scripts/check_*.py` file.

## Working conventions

- Prefer idiomatic OCaml and `Map.Make(String)` over `Hashtbl`.
- Do not add the `base` package; it causes friction with LLVM bindings.
- Explain Takibi and OCaml changes in terms useful to an OCaml beginner.
- Write a leading comment for a new source file; keep directory maps coarse.
- Never let a generator's only source for hand-written content be the file it
  is about to overwrite. Once that file is gitignored or removed by `make
  clean`, the fallback path becomes the sole source and can emit a placeholder
  silently. Split such a file into a tracked hand-written part that includes a
  generated part holding only the derivable content, and add a build-time check
  that the generated output is not degenerate.
- When a settled design decision or root-cause conclusion belongs to an
  existing GitHub issue, record an English ASCII summary using
  `github-workflow`. Do not guess or open an unrelated issue.

## Toolchain

The repository uses OCaml 5.4.0, dune, menhir, LLVM 19 OCaml bindings,
`llvm-mc-19`, `ld.lld-19`, `qemu-system-aarch64`, and `gdb-multiarch`.
Stock host GDB is not an AArch64 substitute in this environment.
