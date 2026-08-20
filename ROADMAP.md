# Takibi roadmap

This file is a dated mid-term plan for the project's ultimate goal: a
practical, monolithic, Linux-syscall-ABI-compatible Unix-like kernel written in
Takibi, whose runtime-error surface is lifted to compile time. It is a plan,
not a contract. `AGENTS.md`'s YAGNI principle still decides what gets built:
the ordering below does not authorize speculative implementation.

Written 2026-08-20 against the 85 open GitHub issues at that date. The previous
snapshot was written one day earlier, but the priority has materially changed:
defining and measuring the trusted base now precedes further allocator,
language, and user-visible kernel expansion. Without that boundary, safety
claims require a reader to reconstruct the compiler and kernel from source and
cannot be evaluated, reviewed, or used as research evidence.

**This is the one tracked file where open issue numbers are intentionally
listed.** It is refreshed wholesale and is expected to become stale. Live
status belongs on the [project board](https://github.com/orgs/takibi-lang/projects/2);
`HISTORY.md` records what happened; `kernel/README.md` describes current
behavior.

## Baseline at the time of writing

| Measure | Value |
|---|---|
| Open GitHub issues | 85 |
| Kernel Takibi code built under `--forbid-trap` | 22,747 lines in 53 files (RPi5/QEMU union) |
| Explicit `unsafe { }` sites in `kernel/` | 203 |
| Raw-pointer casts in `kernel/` | 445 |
| Handwritten assembly currently counted by the metric | 861 lines |
| Linux syscalls | 29 Implemented, 10 Partial, 5 Unsupported-by-design (`kernel/SYSCALLS.md`) |
| Hardware-independent kernel execution | QEMU/AArch64 with ext2, BusyBox, processes, UART, ARP/ICMP/TCP, and debug lanes |
| Real-hardware authority | one physical RPi5; no unattended hardware CI |

`make trustedbasecheck` already makes these raw counts repeatable. They are not
yet a definition of the trusted base. In particular, a count does not explain
what is trusted, why it must be trusted, which property depends on it, or
whether a site is production, generated, or test-only. A rising `unsafe` count
can also mean that an implicit trust boundary was made explicit rather than
that the kernel became less safe. M0 turns these measurements into evidence
that has a precise interpretation.

The other major baseline change remains QEMU. Ordinary kernel work and external
evaluation no longer require SWD, physical storage, or an RPi5. Real hardware
continues to be authoritative for DMA, cache coherency, interrupt timing, and
true concurrency.

## Priority order

1. Define the trusted base and make its classification measurable.
2. Restore confidence in the compiler/test machinery used as evidence.
3. Finish and adopt the count-unbounded kernel resource primitive.
4. Preserve real kernel failures as reproducible compiler-safety evidence.
5. Make QEMU CI and a bounded PR policy the safe entry point for contributors.
6. Resume one visible kernel capability at a time, while retaining RPi5 parity.
7. Turn the accumulated evidence into a research artifact and seek expert
   collaboration before expanding formal machinery.

This order deliberately places claims and evidence before publicity. Talks,
papers, and sponsorship should report a boundary the repository can reproduce,
not a safety interpretation that exists only in the maintainer's head.

## The development and research loop

The project does not have independent "kernel feature" and "language research"
tracks. Its useful loop is:

1. A real kernel requirement exercises nontrivial behavior.
2. Linux-native, QEMU, or RPi5 testing exposes a failure or an unprovable
   operation.
3. The failure and the violated invariant are preserved before the fix erases
   the evidence.
4. The smallest suitable type, ownership, effect, or diagnostic improvement
   moves the failure toward compile time.
5. The real kernel call site adopts it and a regression enters the cheapest
   faithful test tier.
6. Trusted-base measurements show whether the guarantee grew or the failure
   was merely moved behind an escape hatch.

QEMU makes this loop cheaper but does not change the tier rule: pure behavior
belongs in `linux_user/`; hardware-independent kernel behavior belongs in QEMU;
DMA/cache/interrupt/concurrency claims stay on real hardware.

## M0: define and measure the trusted base

Immediate, and now the highest priority.

### M0a: write the claim before optimizing the count

Complete **#236** as a natural-language threat model and proof-boundary
document. It must distinguish:

- properties rejected statically by refinement, ownership, effects,
  exhaustiveness, and `must_use` checking;
- operations that remain runtime-checked;
- explicit trusted escapes such as `unsafe`, raw pointers, casts, MMIO, DMA,
  boot code, exception entry, context switching, and handwritten assembly;
- compiler and toolchain components trusted to implement those checks,
  including OCaml, Takibi's frontend and LLVM lowering, LLVM, and the linker;
- target and hardware assumptions that Takibi does not prove; and
- properties presently outside the language.

The document must state exactly what successful kernel builds with
`--forbid-trap` and `--forbid-unsafe` do and do not establish. It must not claim
a mechanized soundness theorem that the project does not have.

### M0b: make every trusted site classifiable

Extend `make trustedbasecheck` so the document's boundary is reproducible. At a
minimum, report and distinguish:

- production, generated, and fixture assembly;
- `unsafe` sites by rationale category;
- raw-pointer/cast, FFI/extern, MMIO, DMA, ABI, and target-lowering boundaries;
- the exact source set compiled under `--forbid-trap`;
- exemptions or files outside the checked set; and
- unclassified trusted sites.

Counts remain useful trends, but the primary regression condition is that a
new trusted site cannot appear without a category and local rationale.
Machine-readable output is desirable only if the same implementation also
produces a concise human-readable report; do not build a general metrics
platform.

Done when: a reviewer can start from one document and one `make` target, learn
what is claimed, reproduce the inventory supporting it, find every explicit
escape category, and see zero unexplained sites. This establishes an auditable
boundary, not complete compiler correctness.

## M1: repair evidence machinery that is already known to be unsound

Known compiler and test-isolation defects invalidate nearby evidence and stay
ahead of feature work:

- **#331** -- eliminate randomized test-order failures and target-state leaks.
- **#333** -- make module-scoped checker state exception-safe and audit the
  remaining mutable counters.
- **#334** -- prevent new AST type constructors from silently escaping
  monomorphization's syntactic type-shape handling.
- **#335/#337** -- add narrow consistency/watchdog checks where the concrete
  past failures justify them.

Issues #361 and #362 closed the previously immediate pool-validation and
layout-disagreement hazards. Keep their regressions as part of the evidence;
do not leave completed blockers in the active milestone.

Done when: repeated shuffled tests are green, identified mutable checker state
cannot leak across failures, and the relevant compiler representations fail
loudly rather than drift silently.

## M2: finish and adopt one count-unbounded kernel resource primitive

The `linux_user/intrusive_pool` investigation has completed important pieces:
slot layout, off-page metadata, synchronization authority, invariant probing,
reuse initialization, reclaim policy, validation hardening, and a contiguous
multi-page provider. The next value comes from convergence and real kernel use,
not more allocator feature comparison.

Required closing sequence:

1. **#364** -- make the pool provider-agnostic before promotion. The kernel and
   `linux_user/` must compile the same core source against different providers;
   do not repeat `growable_pool`'s copied-and-drifted implementation.
2. **#353** -- supply the kernel page-owner metadata needed by the promoted
   pool and make address-to-owner lookup explicit.
3. Move the single pool implementation into the maintained kernel library and
   retain the fast host-native exerciser against that exact source.
4. Adopt it in one real fixed-capacity kernel consumer from **#257**, exercising
   growth, exhaustion, reuse, corruption detection, and synchronization in
   QEMU and the applicable RPi5 lane.
5. Continue #257 consumer by consumer only after the first adoption is stable.

**#350** remains deferred until an actual pooled type exceeds a single page.
Contiguous multi-page allocation now exists, but capability alone is not a
reason to make every pool chunk multi-page.

Done when: one source implementation has a checked object contract and
invariants, is tested cheaply through `linux_user/`, and removes a guessed
object-count ceiling from at least one real kernel resource.

## M3: preserve failures and turn resource safety into compiler evidence

Finishing resource management is not only allocator work. It is the next source
of concrete evidence for Takibi's central claim.

### M3a: lightweight case records

For a real kernel defect that could plausibly be prevented by the language,
preserve enough evidence to reconstruct it without writing a paper during the
fix:

- observed symptom and triggering workload;
- violated kernel/resource invariant;
- why the compiler accepted the original program;
- the language/checker change, if any;
- a minimal compile-fail case and the real kernel regression;
- whether the change reduced risk or merely moved it into the trusted base;
- annotation, build-time, or usability cost where measurable.

Use the existing engineering history and tests as primary evidence. Introduce
only a small stable case-record format if those sources cannot answer the
questions above; do not create a second issue tracker or impose a long report
on every ordinary bug.

### M3b: close the concrete resource-safety gaps

- **#343** -- audit pool/reference call sites for references that outlive free
  or reuse, then add the smallest lifetime/authority rule justified by a real
  failing shape.
- **#342** -- design nullability around remaining sentinel-pointer sites after
  the audit establishes the migration shape.
- **#203** -- make "no uninitialized kernel memory reaches userspace" a static
  property of syscall output buffers; it is a bounded security property with
  real call sites and does not require beginning with a general SMT system.
- **#171/#298** -- close concrete DMA ownership/cache-line and interrupt-effect
  gaps before adding consumers that depend on them.

Issue #308 supplies possible real invariants, but does not authorize a general
invariant language. Issues #200, #201, #216, #267, #282, and #297 remain
research records until one is the smallest answer to a current kernel failure.

Done when: adopted heap resources cannot reproduce the selected dangling-use
shape, at least one further high-value runtime failure is statically rejected
at its real kernel boundary, and the before/after evidence is reproducible.

## M4: make QEMU and contribution policy the safe public entry point

QEMU is the contributor-acquisition strategy as well as a test target.

1. **#56** -- run `kernelcheck-qemu` in CI so an external PR cannot bypass the
   maintained hardware-independent kernel suite.
2. Define a contribution and AI-assisted-PR policy before actively soliciting
   implementation volume: small agreed scope, declared generation/verification
   method, mandatory checks, no batch of speculative PRs, and maintainer RPi5
   confirmation for hardware-sensitive changes.
3. Keep the first-run path short: devcontainer, QEMU BusyBox, and the browser
   HTTP demonstration. Treat successful reproduction reports and documentation
   fixes as useful first contributions.
4. **#338** -- run the pure USB descriptor parser cases at the Linux-native
   tier while keeping the kernel implementation as the single source of truth.
5. **#290** -- document kernel-aware QEMU/RPi5 debugging around the existing
   gdbstub, DWARF build, crash state, process trace, and page tables.
6. Use **#339/#300** only where this workflow exposes a concrete diagnostic or
   debug-metadata gap.

Do not promise native macOS or Windows toolchains. Windows through WSL2 and
macOS-hosted Linux containers may be documented as unverified or
community-supported after real users reproduce the QEMU path. Buy machines or
promote a host to maintained status only after repeated demand, an actual PR
verification bottleneck, or a contributor willing to maintain that lane.
Native PowerShell/MSVC and Homebrew build systems are not current roadmap work.

Done when: an external contributor on the maintained Linux environment can run
the demonstration, select a bounded task, submit a small PR under a documented
policy, and receive automated QEMU evidence before maintainer review.

## M5: resume one visible kernel capability without weakening RPi5

Safety work must continue to be driven by a useful kernel. Choose one bounded
external milestone at a time.

### M5a: serve real root-filesystem content

- **#285** -- serve rootfs assets through BusyBox httpd on QEMU and RPi5.
- **#281/#283** -- coalesce and type block transfers only where that workload
  demonstrates the need.
- **#270/#287** -- add BusyBox `init` and shebang semantics when the selected
  userspace tree actually requires them.

### M5b: log in over the network

- **#204** -- extend `readv`/`writev` to connected TCP/inetd descriptors when
  the traced service requires them.
- **#220** -- run one BusyBox telnet service/session through the existing
  process machinery.

The maintained ports remain QEMU/AArch64 and RPi5. QEMU is the default fast
development target; RPi5 remains indispensable evidence that Takibi is not an
emulator-only kernel. Do not slow RPi5 work in order to begin AMD64, RISC-V, or
additional board ports.

Filesystem growth remains caller-driven. Re-scope **#182** around the next
rootfs that actually fails. Build **#208** only when a measured workload or
write-ordering requirement justifies the dirty-state, eviction, ownership, and
synchronization obligations of a block cache.

Done when: M5a serves a real maintained-rootfs asset on both QEMU and RPi5;
then M5b reaches a BusyBox ash prompt through one network session. Neither is a
commitment to full POSIX service management.

## M6: prepare a research artifact and seek collaboration

Research publication follows M0 and the resource-safety evidence; it does not
wait for a feature-complete Unix kernel.

1. Select a narrow claim, initially the strongest resource-management case
   rather than "the Takibi language" as a whole.
2. Assemble a short English draft or extended abstract containing the threat
   model, trusted-base inventory, original kernel failure, compile-time
   countermeasure, remaining assumptions, evaluation cost, and reproducible
   QEMU/RPi5 artifact.
3. Compare the claim carefully with ATS/ATS2, Rust, SPARK, and relevant
   verified-kernel and systems-language work; do not present inspiration as
   novelty.
4. Ask an appropriate programming-languages/systems/formal-methods researcher
   to critique the claim and evaluation. A prior collaborator such as Hongwei
   Xi is a natural person to approach once the short artifact is concrete;
   propose substantive collaboration, not authorship in exchange for English
   editing.
5. Use focused community meetings, posters, demos, and workshops to improve the
   question and find collaborators. Treat international publication and its
   artifact as high-quality outreach, not as a substitute for maintainership.

No mechanized proof project is implied by this milestone. Add an SMT solver,
proof assistant, or formal compiler semantics only when the chosen claim has a
specific obligation that present tests and narrow type rules cannot establish.

Done when: a technically honest PDF and reproducible artifact can be sent for
expert review, and every central empirical claim traces back to a maintained
test or classified trusted assumption.

## M7: real SMP

Deliberately later. Treat SMP as one coherent milestone:

1. **#222** -- make scheduler/execution state per-core.
2. **#17** -- provide the required closed atomic operations.
3. **#261** -- establish synchronization and typed guard authority for page,
   MMU, allocator, and shared kernel state.
4. **#274/#299** -- make network frame disposition and atomic publication
   explicit where concurrent receivers demonstrate the need.
5. Run independent EL0 processes on all four RPi5 cores with real overlap.

Issue #202's user-range TOCTOU question becomes urgent here: a validated range
cannot remain trusted across concurrent address-space mutation without an
epoch, lock, pin, or equivalent authority.

Done when: independent EL0 processes run on four RPi5 cores, shared-state paths
are rejected without their authority, and hardware tests exercise concurrent
rather than sequential secondary-core behavior.

## Deferred by explicit triggers

- **Additional architectures (#50/#85):** revisit only when the QEMU/RPi5
  kernel and contributor base are mature and a concrete maintained machine is
  available. AMD64 and RISC-V hardware remain long-range ambitions.
- **Native macOS/Windows development:** revisit after real demand or a named
  maintainer appears. A host OS running the common Linux environment is a much
  smaller commitment than a native toolchain.
- **Unattended multi-platform hardware CI:** build incrementally when multiple
  maintained boards or host platforms create a real verification queue. The
  current RPi5 remains a maintainer-run authority lane.
- **Paid exhibition booths:** revisit when there is a defined product,
  collaboration offer, stable demonstration, follow-up capacity, and plausible
  contract value. Grass-roots technical meetings are the current outreach
  channel.
- **True separate compilation (#95):** revisit when measurements show current
  whole-program build latency obstructing work; source line count alone is not
  the trigger.
- **Solver-backed proof obligations (#13/#109/#200/#201):** begin with one
  current high-value property that established refinement, ownership, typestate,
  or narrowing techniques cannot express.
- **General lock/heap invariant logic (#132):** begin from one real API that
  cannot be expressed with current narrow contracts.

## Issue and board hygiene for this snapshot

- Promote **#236** to the only immediate foundational milestone, with the
  measurement/classification extension explicitly included in its closing bar
  or split into one direct follow-up.
- Keep **#331/#333/#334** ahead of compiler ergonomics because they protect the
  evidence used by every later claim.
- Keep **#344** as the allocator umbrella and **#364/#353** as its immediate
  closing sequence; return optional #350 generality to Backlog.
- Promote **#56** after M0-M2 so QEMU becomes the external PR gate before active
  contributor recruitment.
- Re-scope or close stale umbrellas whose completed work has moved elsewhere:
  **#15**, **#26**, **#149**, and **#182**.
- Keep M5a as the next product-facing milestone, with M5b queued behind it.

The board answers "where is this now"; this file answers "why in this order".
Board changes are separate actions and are not performed merely by documenting
the recommendation here.

## Relationship to YAGNI

- M0 is not premature formalization. The project already makes safety claims
  and already has hundreds of explicit trust sites; defining their meaning is
  a present requirement.
- M1 repairs known defects in the machinery used as evidence.
- M2 closes an active resource-management implementation and adopts it once;
  it does not authorize every allocator feature.
- M3 records and prevents real failures rather than inventing a general proof
  language.
- M4 exploits the already-landed QEMU port and limits review load before
  inviting contributions.
- M5 keeps language research accountable to useful kernel behavior and real
  hardware.
- M6 packages evidence already produced by the project; it does not begin a
  theorem-proving program without a concrete obligation.
- M7 and the deferred items preserve dependency order without authorizing work.

When this ordering conflicts with a concrete present requirement, the concrete
requirement wins and this dated snapshot should be refreshed again.
