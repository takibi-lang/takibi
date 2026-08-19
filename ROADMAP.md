# Takibi roadmap

This file is a mid-term plan for the project's stated ultimate goal: a
practical, monolithic, Linux-syscall-ABI-compatible Unix-like kernel written in
Takibi, whose runtime-error surface is lifted to compile time (see `README.md`
and `AGENTS.md`'s "Design Principle: Detect Errors at Compile Time").

It is a *plan*, not a contract. `AGENTS.md`'s YAGNI principle still governs what
actually gets built: the milestones below describe direction and dependency
order so that work already driven by a real requirement is done in a sensible
sequence, not a license to build ahead of demand. Where a milestone is
deliberately speculative, it says so.

Written 2026-08-19 against the 91 open GitHub issues at that date. The previous
snapshot was written 2026-08-05 against 52 open issues. The increase is not 39
undifferentiated regressions: the intervening kernel work closed its old latent
defects, brought up QEMU, expanded the process/VM/filesystem model, and exposed
more precise compiler, allocator, and proof-boundary debts while doing so.
`HISTORY.md` remains the engineering log; `kernel/README.md` remains the
description of what the kernel actually does today.

**This is the one file in the repository where enumerating issue numbers is the
point** (see `AGENTS.md`'s "Issue Numbers Do Not Belong in Tracked Files"). It
is a dated snapshot, refreshed occasionally and wholesale rather than
maintained incrementally: being visibly out of date here is expected and
harmless. Live status -- what is in progress, what is blocked, and who is on it
-- lives on the [project board](https://github.com/orgs/takibi-lang/projects/2),
not here.

## Baseline at the time of writing

| Measure | Value |
|---|---|
| Open GitHub issues | 91 |
| `kernel/` Takibi source | 22,962 lines, built with `--forbid-trap` |
| `kernel/arch/arm64` assembly/includes | 1,095 lines, including generated offsets and test payloads |
| Explicit `unsafe { }` sites in `kernel/` | 203, after raw-pointer/MMIO boundaries were made explicit |
| Linux syscalls | 29 Implemented, 10 Partial, 5 Unsupported-by-design (`kernel/SYSCALLS.md`) |
| Hardware-independent kernel integration | QEMU/AArch64 with ext2, BusyBox, process, UART, ARP/ICMP/TCP, and debug-build lanes |
| Real-hardware authority | one physical RPi5; no CI yet |

Two counts need care. Assembly lines now include generated ABI material and
deliberate fixture payloads, so a future trusted-base metric must distinguish
handwritten production assembly from generated and test-only code. Likewise,
the rise in `unsafe` sites from the previous snapshot is primarily the result
of making previously implicit raw-pointer and MMIO trust explicit (#218,
#315, #316), not evidence that the kernel became less safe. Issue #236 should
replace both raw counts with a categorized proof-boundary inventory.

The biggest baseline change is QEMU. Issue #237 landed a maintained AArch64
kernel target, and `kernelcheck-qemu`, `kernelcheck-shell-qemu`, and the DWARF
lane now exercise substantial kernel behavior without SWD or physical storage.
Real hardware remains authoritative for cache, DMA, interrupt timing, and true
concurrency, but ordinary kernel work no longer has to wait for it.

## What changed since the previous snapshot

The previous roadmap's immediate correctness milestone is complete:

- #219 initialized forked-child demand-stack metadata.
- #223 saved FP/SIMD state on Current-EL IRQ entry.
- #224 deduplicated primary/secondary CPU initialization.

Its assembly-reduction chain also landed: #225 added external symbol addresses,
#226 added the closed system-register/barrier/TLBI intrinsic set and lifted
`timer.S`/`mmu.S`, and #227 generated the vector-table/exception-entry shape
from `.tkb`. The remaining assembly is no longer accurately described by the
old serial #225 -> #226 -> #227 plan.

Kernel capability advanced at the same time. The kernel now has an interactive
BusyBox ash UART path, blocking input, a real ext2-root executable path, larger
and nested process trees, per-process address spaces, demand-grown page tables,
private fork COW, single-indirect ext2 reads, and directory enumeration. The
old milestones that described these as future work must not remain as if none
of them happened.

## Issue inventory

The 91 open issues are better read as themes than as one priority queue. The
project board had 75 Backlog, 5 Ready, and 11 In progress open items at this
snapshot; most In progress items belonged to one intrusive-pool investigation
and should converge as one milestone rather than masquerading as ten parallel
product priorities.

| Axis | Issues | Roadmap treatment |
|---|---|---|
| A. Known correctness and test-trust defects | #361 #362 #331 #333 #334 | M0: fix before relying on nearby machinery |
| B. Allocator/resource-limit debt | #257 #344 #348 #349 #350 #351 #353 #354 #355 #356 | M1: finish a minimum production-ready slice, park optional generality |
| C. QEMU, CI, and debugging | #56 #149 #290 #300 #338 #339 #341 | M2: turn the QEMU port into the default development safety net |
| D. Proof boundary and kernel safety | #236 #171 #203 #298 #308 #342 #343 | M3: the project's central thesis, driven by concrete kernel risks |
| E. User-visible kernel capability | #204 #220 #270 #281 #283 #285 #287 | M4: resume a bounded product milestone after stabilization |
| F. Filesystem and scalability | #182 #208 #250 #252 | caller-driven follow-ups, not one pre-committed subsystem rewrite |
| G. SMP and concurrency | #17 #222 #261 #274 #299 | M5: a coherent future milestone with real dependencies |
| H. Deeper proof/language research | #13 #109 #131 #132 #200 #201 #216 #267 #282 #297 | keep concrete motivators, do not run all as active research tracks |
| I. Portability and long-range infrastructure | #50 #85 #95 #122 #123 #124 | deferred by explicit triggers |

The inventory is intentionally not exhaustive issue-by-issue. Diagnostics,
ergonomics, and older language requests remain useful backlog, but listing each
one in a milestone would confuse issue existence with a commitment to schedule
it.

## The engine this roadmap is built around

The project's demonstrated working pattern is a loop:

1. A concrete kernel requirement exercises real behavior.
2. QEMU, Linux-native, or hardware tests expose a failure or unprovable access.
3. The smallest suitable type-system, ownership, or diagnostic improvement
   moves that failure toward compile time.
4. The kernel adopts the improvement at the real call site, and the regression
   enters the cheapest faithful test tier.

QEMU makes this loop substantially cheaper, but does not change the tier rule:
pure algorithms belong in `linux_user/`, hardware-independent kernel behavior
belongs in QEMU, and cache/DMA/interrupt/concurrency claims stay on real
hardware. The roadmap therefore does not split "kernel features" and
"language research" into independent tracks that stop feeding each other.

## M0: restore confidence in the checking machinery

Immediate. These are known correctness or test-isolation defects, not optional
cleanup.

- **#362** -- `struct align(N)` does not raise embedded alignment, and the
  compiler's DataLayout and OCaml `sizeof` implementations disagree. A layout
  proof is not meaningful while two compiler paths compute different answers.
- **#361** -- intrusive-pool address validation derives its bounds from mutable
  chunk-header fields that the validation is meant to defend. Derive the
  monomorphized constants instead of trusting corruptible copies.
- **#331** -- `SHUFFLE_TESTS` found six cross-test ordering failures, including
  target-triple state leaks. Tests must not validate whichever target happened
  to run before them.
- **#333/#334** -- make module-scoped checker state exception-safe and remove
  non-exhaustive syntactic type-shape handling where new AST constructors can
  silently escape a pass.

Done when: the layout implementations agree by construction or by a checked
single source of truth; pool validation no longer trusts its own mutable
header; randomized test order is green across repeated runs; and the identified
checker-state/type-shape gaps have regression tests.

## M1: finish one production-ready count-unbounded allocator

The current allocator work is valuable but at risk of becoming an open-ended
comparison with every facility in SLUB, UMA, and `pool_cache(9)`. Issue #344's
intrusive design needs a bounded closing bar before it replaces real kernel
pools.

Required for the first production adoption:

1. **#361** -- validation must not trust mutable layout metadata.
2. **#356** -- choose and enforce one payload initialization/reuse contract.
3. **#355** -- provide an invariant probe that catches free-chain and
   partial-list corruption in `linux_user/`.
4. Adopt the primitive in exactly one current fixed-capacity kernel consumer,
   selected from #257, and exercise exhaustion/growth/reuse in QEMU plus the
   applicable hardware lane.
5. Continue #257 consumer by consumer only after that first adoption is stable.

The following are not automatically part of the closing bar:

- #349's off-page headers;
- #350's multi-page chunks;
- #353's O(1) address-to-owner lookup;
- #354's configurable reclaim policy.

Promote one only when a current consumer, measured cost, or correctness
requirement needs it. A comparison with a mature general-purpose allocator is
useful evidence, but is not by itself a present Takibi requirement.

**#351 synchronization is a dependency of multi-context adoption, not of the
single-context first adoption.** Complete it before the allocator is reachable
from multiple cores or interrupt/process contexts. Do not pull atomics, SMP,
and general lock-invariant research into M1 solely to make the primitive
hypothetically universal.

Done when: one count-unbounded pool implementation has a uniform object
contract, checked invariants, corruption regression tests, and at least one
real kernel consumer with no guessed object-count ceiling.

## M2: make QEMU the continuous development safety net

Issue #237 made hardware-independent kernel execution possible. This milestone
turns that capability into the ordinary way regressions are prevented and
debugged.

1. **#56** -- run `kernelcheck-qemu` in CI. This is the highest-leverage
   remaining consequence of the QEMU port.
2. **#338** -- extract only the pure USB configuration-descriptor parser and
   execute its exact-end/truncation cases in `linux_user/`; keep the kernel
   implementation as the single source of truth.
3. **#290** -- build kernel-aware QEMU/RPi5 debugging around the existing
   gdbstub, DWARF build, crash snapshot, process trace, and page-table state.
4. **#339/#300** -- improve structured hardware initialization failures and
   Takibi enum debug metadata where the debugger work demonstrates a concrete
   visibility gap.
5. Re-scope **#149**. QEMU already provides GDB without JTAG; the remaining
   request should state whether it means an in-kernel debugger on hardware,
   postmortem state without a probe, or another concrete target.

Coverage tooling (#341) is useful only after identifying the exact branch or
module question it should answer; it is not a prerequisite for CI.

Done when: every commit can run the maintained QEMU kernel suite in CI, the USB
parser regression runs at the Linux-native tier, and documented debugger
workflows can inspect a failed process and its address-space/crash state on
QEMU without JTAG.

## M3: define and shrink the trusted kernel boundary

This is the project's central safety milestone, not speculative infrastructure.
The current code has accumulated effective techniques -- refined indices,
checked slices, mode-distinct user ranges, references, indexed owners, explicit
`unsafe`, interrupt effects, and DMA builtins -- but no single precise statement
of what their composition proves.

1. **#236** -- document the trusted base and proof boundaries first. Classify
   statically rejected operations, runtime-checked operations, explicit trusted
   boundaries, target-lowering assumptions, and properties outside the
   language. Categorize `unsafe` and handwritten assembly instead of optimizing
   a raw count.
2. **#343** -- audit real pool/reference call sites for references that outlive
   a free or reuse. The existence of a real growable heap invalidated #15's old
   premise that dangling pointers were only hypothetical. Add the smallest
   lifetime/authority rule justified by an actual failing shape; do not design
   a general lifetime calculus in advance.
3. **#342** -- design nullability around the actual remaining sentinel-pointer
   sites and closed variants. Decide whether ordinary references/pointers are
   non-null by default only after the audit establishes the migration shape.
4. **#203** -- make "no uninitialized kernel memory reaches userspace" a static
   property of syscall output buffers. This remains the strongest bounded
   proof-research candidate: it has a concrete security payoff, existing
   `user_zero_fill` sites, and a plausible initialized-state design without
   requiring an SMT solver.
5. **#171/#298** -- close concrete DMA ownership/cache-line and interrupt-effect
   gaps before new concurrent or driver consumers depend on them.

Issue #308's `ProcessRecord` invariant memo is a useful source of concrete
examples, but not a request to build a general invariant language. Likewise,
#200, #201, #216, #267, #282, and #297 stay as research records until one is the
smallest solution to a current kernel requirement. Do not run them all in
parallel as if every plausible proof direction were scheduled work.

Done when: the repository can state exactly what a successful `--forbid-trap`
kernel build does and does not guarantee; each trusted escape category has a
rationale; present heap references have been audited for dangling use; and one
additional high-value kernel property is enforced statically at its real
boundary.

## M4: resume a visible kernel capability

Stabilization and proof work must keep feeding a kernel that does something
recognizably useful. Choose one bounded external milestone at a time.

### M4a: serve real root-filesystem content

- **#285** -- serve SD-card/rootfs demo assets through BusyBox httpd, using the
  ext2, shell, and HTTP paths that already exist.
- **#281/#283** -- coalesce/type block transfers only where the real workload
  demonstrates an iteration or boundary problem.
- **#270/#287** -- run BusyBox `init` as PID 1 and add shebang execution when
  the selected userspace tree actually requires those semantics.

This is the smaller near-term milestone and should be preferred before opening
a new session-lifecycle front.

### M4b: log in over the network

- **#204** -- extend `readv`/`writev` to connected TCP and inetd-mode file
  descriptors when the traced service requires them.
- **#220** -- run one BusyBox telnet service/session through the existing
  clone/exec/exit/wait4 machinery.

The old roadmap's "a kernel a human can log into" milestone is half complete:
a human can already use BusyBox ash over UART. The remaining headline is a
network login, not the process-model foundation that has already landed.

Done when: M4a serves a real asset from the maintained root filesystem on QEMU
and RPi5; then M4b reaches and uses a BusyBox ash prompt over a network session.
Do not silently turn either into full POSIX service management.

## Filesystem growth stays caller-driven

Issue #182's original umbrella now mixes completed and unrequested work.
Single-indirect regular-file reads and directory enumeration have landed;
multiple block groups, write-side indirect allocation, nested directory
mutation, double/triple indirection, and additional syscalls remain distinct
possible requirements. Re-scope #182 around the next real rootfs image that
fails, and split only the concrete closing bar it supplies.

Similarly, **#208's block buffer cache needs a measured workload**, not merely
the observation that uncached metadata reads are inefficient. Design it when
M4 or a reproducible benchmark shows the cost or when write ordering requires a
cache contract. The cache introduces dirty-state, eviction, ownership, and
eventual synchronization obligations; those are not free architectural
preparation.

## M5: real SMP

Deliberately later, but not vague. SMP is one coherent milestone whose open
dependencies should not leak piecemeal into unrelated work:

1. **#222** -- make scheduler/execution state explicitly per-core.
2. **#17** -- provide the required closed atomic operations.
3. **#261/#351** -- establish synchronization and typed guard authority for
   page, MMU, allocator, and shared kernel state.
4. **#274/#299** -- make network frame disposition and atomic publication
   explicit where concurrent receivers demonstrate the need.
5. Run independent EL0 processes on all four RPi5 cores and retain
   real-hardware preemption/concurrency evidence.

Issue #202's user-range TOCTOU question becomes urgent here: a validated range
cannot be assumed stable across concurrent address-space mutation without an
epoch, lock, pin, or equivalent authority. Resolve it as part of the actual SMP
design, not as solver research in isolation.

Done when: independent EL0 processes run on four RPi5 cores, the shared-state
access paths are rejected without their required authority, and real-hardware
tests exercise actual overlap rather than sequential secondary-core bring-up.

## Deferred by explicit triggers

These are directions, not scheduled milestones.

- **Third architecture (#50/#85):** revisit when a concrete board or platform
  is selected and maintained. Do not build generic portability layers without
  that caller.
- **True separate compilation (#95):** revisit when `kernel/` build latency is
  an actual complaint or source size/build measurements demonstrate the current
  whole-program path is obstructing work. The old rough 20,000-line trigger has
  been crossed, but line count alone has not established pain; measure before
  scheduling an architecture change.
- **Solver-backed proof obligations (#13/#109/#200/#201):** begin only when a
  current, high-value property cannot be expressed by the established refined,
  indexed-owner, typestate, or explicit-narrowing techniques. Start with one
  property and one acceptance test, not a general solver integration program.
- **General lock/heap invariant logic (#132):** retain its stated rule: start
  from one real API that cannot be expressed with current narrow contracts.

## Issue hygiene to apply with the refresh

The roadmap records recommendations; issue/board changes are separate actions.

**Re-scope or close stale umbrellas**

- **#15** -- its remaining subjects have been split into #342 and #343, while
  user-address-space typing substantially landed elsewhere. Close it if it no
  longer owns an unsplit acceptance criterion.
- **#26** -- its growable-pool primitive landed; #344/#257 now describe the
  remaining count ceiling and adoption work. Its open state should not imply
  the original primitive is absent.
- **#182** -- mark completed single-indirect read and directory-enumeration
  slices, then state the next caller-driven filesystem requirement.
- **#149** -- separate already-working QEMU gdbstub use from any remaining
  no-JTAG hardware debugger requirement.
- **#5** -- close unless a present kernel call site needs general inline
  assembly. The closed intrinsic set from #226 deliberately avoids reopening
  arbitrary register/clobber obligations in `.tkb`.
- **#90/#200** -- retain one relational-bounds issue and treat #13 as the
  solver umbrella rather than maintaining duplicate active requests.

**Project-board shape**

- Keep at most one allocator umbrella and its immediate correctness blockers In
  progress; optional allocator generalizations return to Backlog.
- Make M0 items Ready/In progress before new compiler ergonomics.
- Promote #56 and #236: they convert the two largest recent advances -- QEMU
  and explicit trust boundaries -- into durable project infrastructure.
- Keep M4a as the next product-facing Ready milestone; keep M4b queued behind
  it rather than treating every BusyBox extension as simultaneous work.

The division of labor remains: the board answers "where is this now", this file
answers "why in this order". Neither should try to answer the other's question.

## Relationship to YAGNI

`AGENTS.md`'s YAGNI principle remains a durable project stance.

- **M0 is mandatory correctness work.** Known compiler/layout/test-isolation
  defects undermine evidence from everything built on them.
- **M1 is bounded debt repayment.** A production consumer and explicit closing
  bar justify the allocator; optional allocator generality does not inherit
  that justification.
- **M2 is exploitation of an already-landed capability.** CI and debugger use
  make QEMU pay for itself; they are not a second emulator project.
- **M3 is the project's stated purpose.** Compile-time proof boundaries are not
  optional future-proofing, but each new mechanism must still start from a real
  kernel property.
- **M4 is current product work.** It keeps the proof loop grounded in actual
  userspace and device behavior.
- **M5 and the deferred section are not commitments to start.** They preserve
  dependency order and explicit re-evaluation triggers without authorizing
  speculative implementation.

When a milestone here conflicts with a concrete requirement in front of the
project, the concrete requirement wins and this dated snapshot gets refreshed.
