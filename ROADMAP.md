# Takibi roadmap

This file is a dated mid-term plan for the project's ultimate goal: a
practical, monolithic, Linux-syscall-ABI-compatible Unix-like kernel written in
Takibi, whose runtime-error surface is lifted to compile time. It is a plan,
not a contract. `AGENTS.md`'s YAGNI principle still decides what gets built:
the ordering below does not authorize speculative implementation.

Written 2026-08-27 against the 99 open GitHub issues at that date. The previous
snapshot was written 2026-08-20, and three of its eight milestones have since
closed outright, along with the first half of a fourth: the trusted base is
defined and measurable (#236), the known evidence-machinery defects are
repaired (#331/#333/#334/#335/#337), the
count-unbounded resource primitive is finished and adopted
(#344/#364/#353/#257/#350), and the kernel serves real root-filesystem content
with BusyBox `init` as PID 1 and shebang scripts working (#285/#270/#287). See
"Completed since the previous snapshot" below.

**The priority has therefore materially changed. Real multicore is promoted
from last to first.** The previous snapshot deferred SMP explicitly ("M7:
deliberately later") because the foundations it would have rested on were
unfinished. They are finished. What is left in front of SMP is no longer
foundational, and continuing to defer it now costs more than it saves: every
month the single-core assumption stays unexamined, more code is written whose
correctness argument names the core count without saying so.

**This is the one tracked file where open issue numbers are intentionally
listed.** It is refreshed wholesale and is expected to become stale. Live
status belongs on the [project board](https://github.com/orgs/takibi-lang/projects/2);
`HISTORY.md` records what happened; `kernel/README.md` describes current
behavior.

## Baseline at the time of writing

| Measure | Value | Previous snapshot |
|---|---|---|
| Open GitHub issues | 99 | 85 |
| Kernel Takibi code built under `--forbid-trap` | 31,411 lines in 56 files (RPi5/QEMU union) | 22,747 in 53 |
| Explicit `unsafe { }` sites in `kernel/` | 227, all classified, 0 unclassified | 203 |
| Raw-pointer casts in `kernel/` | 482 (memory 240 / MMIO 180 / string 62) | 445 |
| Production handwritten assembly | 1,042 lines in 6 files, plus 75 generated | 861, not split |
| Linux syscalls | 29 Implemented, 12 Partial, 5 Unsupported-by-design (`kernel/SYSCALLS.md`) | 29 / 10 / 5 |
| Hardware-independent kernel execution | QEMU/AArch64 with ext2, BusyBox `init` as PID 1, processes, UART, ARP/ICMP/TCP, DDB and debug lanes | as before, without `init`/DDB |
| Real-hardware authority | one physical RPi5; no unattended hardware CI | unchanged |

`make trustedbasecheck` produces this inventory, and since #236 the counts have
an interpretation rather than being raw totals: every `unsafe` site carries a
rationale category and the unclassified count is zero. A rising count now
readably means either a new trusted site with a stated reason or an implicit
boundary made explicit -- which is what the measurement was for.

The growth in the table is mostly real kernel capability (`init`, shebang, DDB,
the pooled process/connection tables) rather than a loosening. Treat the
assembly line as the one worth watching: the previous snapshot counted 861
lines without separating generated from handwritten, so the two rows are not
directly comparable, and re-establishing the trend from this snapshot's split
figures is the point of recording them apart.

## Priority order

1. **Real multicore, in strict phase order, starting with the language
   primitives that make a lock expressible at all.**
2. Close the concrete resource-safety gaps that are already identified.
3. Make QEMU CI and a bounded contribution policy the safe external entry point.
4. Resume one visible kernel capability at a time, while retaining RPi5 parity.
5. Turn the accumulated evidence into a research artifact and seek expert
   collaboration before expanding formal machinery.

Multicore leads not because it is the most valuable feature but because it is
the deepest dependency: it needs a language primitive this compiler does not
have, and every week of single-core code written before that primitive exists
is a week of code whose synchronization argument has to be reconstructed later.

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
DMA/cache/interrupt/concurrency claims stay on real hardware. Multicore is the
clearest case of that last clause the project has had: QEMU can find a logic
error in a lock, and only RPi5 can find a missing barrier.

## M0: real multicore

Immediate, and now the highest priority. Treat it as one milestone with a
strict internal order; the phases are not independent tracks and the value of
the order is that a failure in a later phase is attributable.

### What already exists

More than the previous snapshot's deferral suggests. A second core boots today:
`kernel_secondary_entry` is reached by PSCI CPU_ON, sets its own stack and
VBAR_EL1, activates the shared page-table root through
`kernel_mmu_init_secondary()`, runs compiled Takibi, and is recorded by the
`smp_bringup` view. The QEMU harness already passes `-smp 2`. The MMU's memory
attributes are already SMP-correct (SH=3 Inner Shareable, nG set), and per-page
and per-ASID TLB maintenance already uses the broadcast `...is` forms.

Two things are missing, and they are of different kinds.

**The language has no atomic operation.** `signal_fence()` lowers to a compiler
barrier that emits nothing. Consequently neither thing this kernel calls a lock
excludes a second core: `pool_lock` masks DAIF.I, which excludes an interrupt
handler and nothing else, and `scheduled_process_spare_lock` returns an erased
`linear view` that emits no instruction at all. Both are correct single-core
designs whose correctness argument names the core count.

**Several resources are singular by assumption, not by capacity.** This is the
distinction worth stating plainly, because the intuitive worry is the wrong
one: `RESOURCE_LIMITS.md` records that **no kernel pool has a hand-picked
capacity left** (#391/#393/#402 finished what #257/#392/#401/#406 started), so
"N=16"-style ceilings are not the obstacle. The obstacle is "N=1": one
scheduler, one live child per process, one parked spare kernel-stack run, one
trace producer, one local-only whole-TLB flush.

### Where this is going, and what must not be foreclosed

Four goals the maintainer stated on 2026-08-27. None of them has to be
reached by the end of M0 -- what matters is that the sequence below does not
paint the design into a corner.

1. **A preemptible kernel.** Today it is not: a timer interrupt taken at EL1
   only sets a flag, and the switch happens at syscall return
   (`kernel/platform/qemu/intc.tkb`'s `if (lower_el)`). That is
   `CONFIG_PREEMPT_NONE`, deliberately.
2. **Multicore.** This milestone.
3. **A way for an interrupt handler to hand information to the main
   context.** Today the only channel is a bare global flag, because the
   effect system forbids `!{locks}` on an `!{interrupt}` function outright.
4. **Locks that control access to the resource they protect**, rather than
   sitting beside it by convention.

**Three of the four are not foreclosed, and one is at risk.**

Goal 1 is *helped* by the sequence: the interrupt mask #451 gives each guard
is also the preemption-disable primitive, since preemption arrives through
the timer interrupt. #453 turns enabling preemption into a compile-error
worklist rather than a silent change.

Goal 4 is verified to work, including the case that looked hardest -- a
pooled object with its protected fields grouped behind one accessor:

```takibi
fn e_data(g: borrow EGuard[id], e: *Entry) -> *Protected @ id {
    return &e.data;
}
```

Using the returned pointer after releasing the guard is rejected: "pointer
'd' is derived from linear value 'guard' and cannot be used after 'guard' is
consumed". The tie is lexical and type-level, so it does not care whether
the racing context is another core or another task -- it works under goal 1
as well as goal 2.

**Goal 3 is the one at risk.** The `locks`-forbidden-on-`interrupt` rule
looks like it settles the question and does not: it fires on the
annotation, and no function in this kernel declares `!{locks}`, so an
interrupt handler taking a pool lock compiles today. Meanwhile the
scheduler already runs in interrupt context and mutates the process table,
so "handlers do not lock" was never true of the one handler that matters. Three
mechanisms are on file -- relaxing that rule (#449), a lock-free classified
ring (#440), and atomic commit publication (#299) -- and the design space is
covered. What is not settled is which one handlers are supposed to use, and
that question should be answered in #449 **before** more handlers are
written, not after.

**Which decisions are one-way.** Reversible: the `Mutex` type, view-to-linear-struct,
the spinlock's internals, non-preemptible-to-preemptible. Costly to revisit:
the public/private split and grouping of a struct's fields, because every
call site moves twice instead of once -- which is why #452 should group the
protected fields when it makes them private, not in a later pass. And the
interrupt/locks rule, because handlers get built around whatever it says.

### Phase 0: the foundation, language and observation

- **#17 -- DONE 2026-08-27.** `atomic_load_acquire`, `atomic_store_release`,
  `atomic_swap_acquire`, `atomic_fetch_add_relaxed`, all behind `unsafe`. The
  exclusives-versus-LSE question answered itself: the read-modify-write pair
  goes through LLVM's `atomicrmw`, so `--cpu` picks, and measured on objdump
  cortex-a53 gets a retry loop while cortex-a76 gets `swpa`/`ldadd`. x86-64
  works too, so the lock can be exercised from `linux_user/` in seconds
  instead of a QEMU boot. **#450** holds compare-and-swap, which LLVM's OCaml
  bindings cannot express (`build_atomicrmw` exists, `build_cmpxchg` does
  not) and which a test-and-set spinlock does not need.
- **#445 -- DONE 2026-08-29, closed, QEMU and RPi5.** The spinlock, plus
  `cpu_id()`. What its last criterion bought was not the code, which landed
  in 2026-08-27 -- it was the evidence that the lock EXCLUDES, which needed
  a second core running kernel code (#447) before it could be taken at all.
  Two cores now run 4096 allocate/free cycles each against one pool through
  one lock; removing the exchange corrupts the free list.

  The board said something QEMU could not. The first version of that probe
  passed with core 1 having completed ONE cycle to core 0's 4096, where
  QEMU showed 4096 vs 4110 for the same binary: the lock excludes and does
  not arbitrate, and QEMU's round-robin vCPU scheduling supplies a fairness
  the hardware does not. Filed as **#478**; not urgent, since every current
  caller holds the lock for a short straight-line critical section, but the
  first measured argument this project has for why a criterion named real
  hardware.
- **#449** -- give the `locks` effect a meaning. It has existed in the checker
  since before there was a lock, has zero uses, and currently forbids the one
  case a spinlock exists for (an interrupt handler taking one).
- **#299 -- DONE 2026-08-29, closed, QEMU and RPi5.** `struct
  publish` is the second safe surface over #17, and the diagnostic ring has
  moved onto it. What it makes checkable is the write ORDER: the payload is
  unreachable except through a linear token `publish_begin` returns, so a
  payload store can only happen between the clear and the commit, and a
  record left in flight is a compile error. Measured against the real ring
  by breaking it: moving the commit above the payload now says "linear value
  'w' was already consumed". The reader's re-check-after-copy -- the step a
  hand-written reader omits, invisibly -- is the compiler's. Follow-up
  **#476**: the token proves the payload is written only between the clear
  and the commit, not that the writer wrote all of it; today a forgotten
  field is scrubbed to 0 rather than rejected. Original reasoning, which
  held: The reasoning is Codex's, from working on the
  diagnostic ring: #299 is not a tracing feature, it is the publication
  protocol that lets DDB read a ring another CPU is writing. The current
  hand-written ring is correct for one CPU plus its own interrupts and says
  nothing about cross-CPU visibility, so deferring #299 until multicore
  actually runs is too late -- but building it now, against an imagined
  API, is worse than building it against #222's real per-CPU state once
  that lands. So: #445/#449 settle the lock and its effect discipline,
  #222 fixes the actual shape of per-CPU state, #299 is written as a
  consumer of that shape, the diagnostic ring moves onto it, and only then
  does Phase 3 let two CPUs run at once. Where the ring lives and who owns
  it follows #222; the fixed record layout and write-last publication are
  #299's and must exist before multicore starts; a cross-CPU total order
  and a general lock-free API are neither.
- **#440 -- DONE, closed.** The classified deferred log ring, four per-CPU
  readers, verified on QEMU and on RPi5 over SWD. It is the reason Phase 3
  is approachable at all: an SMP race with no per-CPU trace is the
  debugging bottleneck, not the coding.

**Phase 0 is complete.** #17, #449, #440 and #299 are closed. #445 landed
and holds open only its two-core contention test and an RPi5 run of its
changed secondary-entry path -- both of which are #447's to unblock, since
neither can happen while core 1 parks.

**Phase 3's entry is open as of 2026-08-29.** A second core takes
interrupts on both targets. What that unblocks was one wait rather than
four: #445's two-core contention test, #445's RPi5 run of its changed
secondary-entry path, and #448's two-core criterion. #222's remaining scope
(the one-deep spare kernel-stack cell) is small and independent; the crash
trace ring it also named is done, since #440's ring is already per-CPU.

**#479 Group A is DONE, 2026-08-30, QEMU and RPi5.** Five locks -- the page
allocator, the ASID counter, the shared-object refcount, the pid counter and
the pool tag -- each with a probe that produced the race BEFORE the fix
(`doublefree=1618`, `advanced=3974/4096`, `refs=0 refused=978`,
`advanced=3936/4096`, `duplicates=1349` on the board against 3 under QEMU).
Plus three PER-CORE conversions, which is the distinction worth carrying:
`execution_state`, `address_space_active_slot` and
`process_image_target_root` were not missing locks, they were per-core state
stored as though it were global, and a lock would have made two cores agree
on something that should have had two answers.

`scripts/check_execution_model_coverage.py` closed the hole
`execution_model.tkb` had named since it was written -- "the assertion set is
a claim, not a proof". Two files fell through it this week, both found by
accident while fixing something else. 35 files hold mutable state now, 16
assert a constant, 19 are exempt with a stated reason, and none says "not
audited". The worklist grew from 8 sites to 14, which is the check working:
every one added was already true and none of them said so.

**Running a PROCESS on core 1 is the rest of #479, and it is a different kind of
change.** The first thing it must do is raise `KERNEL_ACTIVE_CORES`, which
prints the ten-site worklist #453 built for exactly this moment.
Everything up to here has been "a second core does work that reaches no
shared state" -- which is why the constant could stay 1 through all of it.
Past here it reaches shared state, and Phase 0's lock discipline stops
being latent and starts being load-bearing.

The worklist was read from a build rather than predicted, and doing that
found three entries whose stated reasons had already been fixed (`4b87978`)
-- one of them pointing at #446, which had closed two days earlier. The
ten sites are not one problem: three are the scheduler becoming per-core,
one is a lock a primitive never had, two are unsynchronised counters,
three are the network stack's shared scratch, and one is the syscall
path's whole re-entrancy assumption. Splitting the
constant into "cores that run kernel code" and "cores that run the
scheduler" was considered and REJECTED: no Unix-like kernel has that
state -- an online CPU runs both -- so it would invent a state this
kernel's own target design does not have, to avoid fixing ten sites at
once. An abstraction whose removal date is known before it is written
should not be written.

What replaces it is the method #446 and #477 already used, strengthened:
make a site correct for two cores while the flag is still 1, and exercise
it FROM core 1 to prove it. That is not hypothetical --
`kernel/kernel/pool_contention_evidence.tkb` already has core 1 hammering
a pool concurrently with `KERNEL_ACTIVE_CORES` at 1, because the probe
touches only that one part.

The ten sites split three ways by what can actually reach them, which is
a real division rather than an invented one. Three (`freelist`, `asid`,
`fd_table`'s refcount) are probe-able from core 1 today. Four
(`process.tkb` x2, `syscall.tkb`, `secondary.tkb`) ARE the change --
core 1 calling `execution_here()` is what "a process on core 1" means.
The remaining four are the network stack, and they are the hard part: RX
stays single-core because device SPIs are routed to CPU0, but a socket
call from a process on core 1 enters `tcp.tkb` there anyway. A busy loop
never makes one, and nothing enforces that -- which is the assumption
shape this project exists to stop relying on. They need #261's design,
not four locks bolted on.

**Decision recorded 2026-08-27: raw atomics are reachable only through
`!{unsafe}`.** Ordinary kernel code goes through the spinlock or the
publication record; there is no third surface and no plain-atomic escape for a
caller who finds neither convenient. This is a deliberate choice of the
project's usual shape over the fast one, and #449 is the reason it is not
merely a naming convention.

### Phase 1: shape the state per-core, with the cores still parked

**#222**. One state struct per core, held in a `PerCore(T: type, N: usize)`
container -- the mechanism that issue predicted has since landed as const
generics. Verified by the existing views passing unchanged, which is only
possible while nothing actually runs concurrently. Do this before the cores
run, not during.

### Phase 2: make a multicore workload expressible, still on one core

**#437 -- DONE 2026-08-28, closed.** A process may have as many children as
the page allocator allows. Three commits, each verifiable before the next
because none could be exercised by what the next one enabled: `1dd33db` made
the scheduler walk the process TREE rather than a chain (a pre-order
successor that reduces to the old walk exactly while nothing has a sibling);
`1567fb5` made an exited child wait to be collected, holding its own status,
so the parent's single `child_exit_status`/`child_waitable` were deleted
rather than pluralised -- pluralising meant a per-parent queue with a
capacity, in a kernel that has removed every hand-picked one; `7a2f6b3`
lifted the count refusal and made `wait4` validate and collect by pid.

The typestate paid for itself: `scheduled_process_reap` consumes a linear
`ScheduledProcessState[Exited]` whose only source is a take on a record that
IS Exited, so moving that take from exit to the wait path turned the zombie
window into a state the checker sees. RPi5 caught the one bug QEMU could not
-- `process_image_target_root` left at 0 on wait4's fast path, aiming the COW
handler at PID 1's live image.

**#448 is next**, and #437's userspace criteria moved into it: both `respawn`
entries alive, killing one restarting only that one, and ash backgrounding
more than one job.

The workload is a pair of CPU-bound busy loops with a fairness assertion, and
it must pass **on one core** before the second core is enabled -- so that
anything that breaks afterwards is provably a concurrency defect rather than a
workload defect. Realistic BusyBox services are the follow-on and are wanted;
busy loops are what makes the scheduler the only variable.

**Decision recorded 2026-08-27: dependencies get implemented, not worked
around.** If `respawn` needs SIGCHLD/`kill` (**#431**) or `nanosleep`
(**#432**), those are written, not routed around with a busy-wait or a
test-driver special case.

### Phase 3: two cores actually running

- **#447 -- DONE 2026-08-29, closed, QEMU and RPi5.** The secondary core
  idles instead of parking: its own GIC CPU interface, its own timer PPI,
  its own tick, `wfi` in between. None of the three was new code -- all are
  per-core banked registers that core 0's one-time initialization does not
  reach, and what was missing was a path on the secondary that reached
  them. `KERNEL_ACTIVE_CORES` stays 1, which was this issue's own first
  question: the dispatch branch returns before every path that reaches
  kernel state, so core 1 executes kernel code and touches no kernel STATE.
  The view earns its line -- core 0 masks its own interrupts for a
  CNTFRQ-derived window and compares core 1's counter across it, so what is
  measured is core 1's own interface and not that time passed.
- **#477 -- DONE 2026-08-29, closed.** What #447 cost on the way: the
  generated exception entry switched to ONE global IRQ stack, so core 1's
  first tick landed on core 0's frame and its INTID came back as core 0's
  ELR. The linker script had already written that reopen condition
  verbatim, and it fired exactly as predicted. Both the IRQ and the guard
  stack are per-core now, selected through TPIDR_EL1, and neither entry
  path reads MPIDR -- PSCI starts exactly one secondary, so each path IS
  its core by construction, which keeps #445's per-platform affinity-field
  difference out of shared generated code.
- **#446 -- DONE 2026-08-29, closed.** `mmu_tlb_invalidate_all()` is the
  broadcast `tlbi vmalle1is`, verified on QEMU and RPi5. It landed ahead of
  the rest of this phase because it had no dependency of its own. What it
  bought beyond the instruction: `kernel_mmu_activate` keeps the LOCAL form,
  so the tree now holds the two whole-TLB invalidates that want OPPOSITE
  answers, and the difference is checked on emitted instructions
  (`check_kernel_asm_invariants.py`) in both directions rather than
  described in a comment. The two mnemonics differ by two characters, both
  are correct on one core, and the wrong one fails silently on two.
- **#261 -- re-derived and split, 2026-08-30.** Its inventory was five parts
  stale: every pool it named is an `IntrusivePool` whose mutation requires
  the lock as a matter of TYPING (`insert`/`remove` take a
  `borrow IntrusivePoolGuard[pool_id]`), one named file left `kernel/`
  entirely, and #17 -- listed as an open dependency -- had closed. Its body
  was rewritten rather than commented on, because a stale body is what a
  long-lived coarse issue costs.

  What survived is the one part where **the answer is not a lock**: PTE
  mutation against the hardware page-table walker, which acquires nothing.
  Every other unsynchronized structure in this kernel was fixed by adding
  the mutual exclusion that was missing; here one participant cannot be
  excluded, and break-before-make is the shape both Linux and NetBSD use
  instead. #261 keeps that.

  Split out: **#482** (pool WALKS take no guard while mutations do -- narrow
  and real, `tcp.tkb` walks its connection pool that way) and **#483**
  (#479's Group C: `arp`/`icmp` shared reply frames, `socket_capability`'s
  init flag, `tcp`'s multi-statement sequence updates).

**Decision recorded 2026-08-27: two cores before four.** Every class of race
appears at two. Four adds reduced reproducibility and a different problem --
scalability -- and should not be mixed into the phase that is finding
correctness bugs.

### Phase 4: four cores, and affinity

`-smp 4` and all four RPi5 cores, **#9** processor affinity, and per-CPU
allocator structures if and only if measurement shows contention. This is the
first phase where throughput rather than correctness is the question.

### Phase 5: re-examine what concurrency invalidates

- **#202** -- the `UserRange` TOCTOU question. That issue defers itself until
  "there is a real mechanism that could actually trigger this"; Phase 3 is that
  mechanism, and the deferral expires there rather than at the end.
- **#274** -- TCP RX frame disposition under concurrent receivers.
- **#412** -- the lock-order checker that reported success while tracking
  nothing.

### The supporting track: the in-kernel debugger

A NetBSD-`ddb`-style kernel debugger is being built in parallel and is not
scheduled by this milestone, but it is the reason Phase 3 is approachable at
all. What has landed so far: an interrupt-safe UART DDB and read-only crash
console, entry from deliberate software breakpoints, interactive breaks driven
through QMP under QEMU, and the commands `ps`, `regs`, `current`, `intr`,
`sched`, `vm`, `fds`, `trace`, `oops`, `continue`, plus fault-contained
read-only kernel, user and physical RAM inspection. The supported QEMU and
RPi5 DDB/GDB/crash-inspection workflow is documented in `kernel/README.md`.
Open and relevant: **#444** (controlled mutation, deferred), **#429**
(in-kernel GDB stub, deferred), **#425**/**#300** (debug metadata a debugger
needs to decode variants and enums), **#496** (read-only kernel-aware GDB
helpers), **#495** (a trustworthy unwind contract before `bt`), and **#149**.

**Do not begin Phase 3 without the observation half of Phase 0.** An SMP race
with no per-CPU trace is a debugging bottleneck, not a coding one; this project
has already measured that cost once, on a single-core scheduler bug that needed
three rounds of hand-rolled globals because interrupt handlers may not log
(#440's motivation). `ddb`'s `sched`/`intr`/`ps` become the per-core views once
#222 lands, and #440's ring is the write side `ddb` reads.

Done when: independent EL0 processes run on all four RPi5 cores with real
overlap, shared-state paths are rejected without their authority, and the
hardware tests exercise concurrent rather than sequential secondary-core
behavior.

## M1: close the concrete resource-safety gaps

These are identified, have real call sites, and do not require beginning with a
general proof system:

- **#343** -- audit pool/reference call sites for references that outlive free
  or reuse, then add the smallest lifetime/authority rule justified by a real
  failing shape.
- **#342** -- design nullability around remaining sentinel-pointer sites after
  the audit establishes the migration shape.
- **#203** -- make "no uninitialized kernel memory reaches userspace" a static
  property of syscall output buffers. A bounded security property with real
  call sites.
- **#171** -- close the concrete DMA ownership and cache-line gaps before
  adding consumers that depend on them. (#298, the interrupt-effect half, is
  closed.)

Keep the lightweight case-record practice from the previous snapshot: for a
real kernel defect the language could plausibly have prevented, preserve the
symptom, the violated invariant, why the compiler accepted it, the minimal
compile-fail case, and whether the change reduced risk or moved it into the
trusted base. Use the existing engineering history and tests as the primary
evidence; do not create a second issue tracker.

Issue #308 supplies possible real invariants but does not authorize a general
invariant language. Issues #200, #201, #216, #267, #282, and #297 remain
research records until one is the smallest answer to a current kernel failure.
**#374** stays deferred until a device-read buffer is allocated at runtime
across more than one page.

Done when: adopted heap resources cannot reproduce the selected dangling-use
shape, at least one further high-value runtime failure is statically rejected
at its real kernel boundary, and the before/after evidence is reproducible.

## M2: make QEMU and contribution policy the safe public entry point

QEMU is the contributor-acquisition strategy as well as a test target.

1. **#56** -- run `kernelcheck-qemu` in CI so an external PR cannot bypass the
   maintained hardware-independent kernel suite. **#426** (two concurrent makes
   share `kernel/build` and the failure reads as a compiler regression) is a
   direct prerequisite: CI will run concurrent builds by construction.
2. Define a contribution and AI-assisted-PR policy before actively soliciting
   implementation volume: small agreed scope, declared generation/verification
   method, mandatory checks, no batch of speculative PRs, and maintainer RPi5
   confirmation for hardware-sensitive changes.
3. Keep the first-run path short: devcontainer, QEMU BusyBox, and the browser
   HTTP demonstration. Treat successful reproduction reports and documentation
   fixes as useful first contributions.
4. **#338** -- run the pure USB descriptor parser cases at the Linux-native
   tier while keeping the kernel implementation as the single source of truth.
5. **#411** -- report how long a boot took, so a ten-second regression stops
   reading as a network bug. Cheap, and it is CI's most basic signal.
6. Use **#339** only where this workflow exposes a concrete diagnostic gap.

Do not promise native macOS or Windows toolchains. Windows through WSL2 and
macOS-hosted Linux containers may be documented as unverified or
community-supported after real users reproduce the QEMU path. Buy machines or
promote a host to maintained status only after repeated demand, an actual PR
verification bottleneck, or a contributor willing to maintain that lane.
Native PowerShell/MSVC and Homebrew build systems are not current roadmap work.

Done when: an external contributor on the maintained Linux environment can run
the demonstration, select a bounded task, submit a small PR under a documented
policy, and receive automated QEMU evidence before maintainer review.

## M3: resume one visible kernel capability without weakening RPi5

Safety work must continue to be driven by a useful kernel. Choose one bounded
external milestone at a time. The previous snapshot's M5a is finished: BusyBox
`init` runs as PID 1 (#270), shebang scripts work through `execve` (#287), and
httpd serves real rootfs assets (#285).

The natural next capability is the one the multicore workload will already have
forced part of the way: a process model that supports more than one child, real
signal delivery (**#431**), and timed blocking (**#432**). Everything else
queues behind that.

- **#204** -- extend `readv`/`writev` to connected TCP/inetd descriptors when
  the traced service requires them.
- **#220** -- run one BusyBox telnet service/session through the existing
  process machinery.
- **#433**/**#434**/**#435**/**#436** -- `reboot(2)`, `setsid`/`getsid`,
  termios `TCGETS`/`TCSETS`, and `faccessat`'s mode argument, each when a real
  workload asks.
- **#281/#283** -- coalesce and type block transfers only where a workload
  demonstrates the need.

The maintained ports remain QEMU/AArch64 and RPi5. QEMU is the default fast
development target; RPi5 remains indispensable evidence that Takibi is not an
emulator-only kernel, and multicore raises rather than lowers that -- a missing
barrier is invisible under QEMU. Do not slow RPi5 work in order to begin AMD64,
RISC-V, or additional board ports.

Filesystem growth remains caller-driven. Re-scope **#182** around the next
rootfs that actually fails. Build **#208** only when a measured workload or
write-ordering requirement justifies the dirty-state, eviction, ownership, and
synchronization obligations of a block cache -- obligations that multicore
makes strictly larger, which is a reason to keep it behind M0.

Done when: one further bounded external milestone works on both QEMU and RPi5.
Neither this nor anything above is a commitment to full POSIX service
management.

## M4: prepare a research artifact and seek collaboration

Research publication follows the resource-safety evidence; it does not wait for
a feature-complete Unix kernel. #236 removed the blocker the previous snapshot
placed in front of this milestone: the threat model and proof boundary now
exist and are reproducible from one `make` target.

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

If M0 produces a lock discipline that the effect system actually checks (#449),
that becomes a second candidate claim and a more distinctive one: lock
discipline is on the same list -- sparse, lockdep, `might_sleep` -- that this
project's positioning argues should be types and effects rather than runtime
instrumentation. Do not promise it before it is demonstrated.

No mechanized proof project is implied by this milestone. Add an SMT solver,
proof assistant, or formal compiler semantics only when the chosen claim has a
specific obligation that present tests and narrow type rules cannot establish.

Done when: a technically honest PDF and reproducible artifact can be sent for
expert review, and every central empirical claim traces back to a maintained
test or classified trusted assumption.

## Completed since the previous snapshot (2026-08-20 to 2026-08-27)

Recorded here so that finished work stops occupying the active plan, and so
that the previous snapshot's milestone letters can be found.

- **Old M0, define and measure the trusted base -- #236 closed.** The threat
  model and proof boundary are written, and `make trustedbasecheck` classifies
  every trusted site with zero unclassified.
- **Old M1, repair evidence machinery -- #331, #333, #334, #335, #337 all
  closed.** Test-order fragility, checker state leaking across exceptions,
  monomorphization's unprotected type-shape matching, and the sync-comment and
  bloat watchdogs.
- **Old M2, the count-unbounded resource primitive -- #344, #364, #353, #257,
  #350 all closed.** `IntrusivePool` is in `kernel/lib/`, provider-agnostic,
  and adopted; the TCP connection pool migration removed `TCP_CONNECTION_MAX`
  rather than raising it. Beyond that milestone, #392/#391/#393/#402 removed
  the process, descriptor, shared-object and ASID ceilings too, which is why
  `RESOURCE_LIMITS.md` can now say no pool has a hand-picked capacity.
- **Old M5a, serve real root-filesystem content -- #285, #270, #287 all
  closed.** httpd serves rootfs assets, BusyBox `init` is PID 1, and shebang
  scripts run through `execve` on both QEMU and RPi5.
- **Old hygiene item -- #15 and #26 closed**, both split into narrower
  successors rather than left as drifting umbrellas.

## Deferred by explicit triggers

- **Additional architectures (#50/#85):** revisit only when the QEMU/RPi5
  kernel and contributor base are mature and a concrete maintained machine is
  available. AMD64 and RISC-V hardware remain long-range ambitions. Note that
  M0 makes this cheaper rather than more expensive: #85's lost-wakeup question
  and #17's atomics are the same design surface.
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
- **Solver-backed proof obligations (#13/#109/#200/#201/#417):** begin with one
  current high-value property that established refinement, ownership,
  typestate, or narrowing techniques cannot express.
- **General lock/heap invariant logic (#132):** begin from one real API that
  cannot be expressed with current narrow contracts. M0 is likely to supply
  that API, which is the first time this trigger has had a plausible date.
- **Contiguous-memory type (#374):** the trigger is a device-read buffer
  allocated at runtime across more than one page. Not reached.
- **In-kernel GDB stub (#429) and DDB memory mutation (#444):** deferred by
  their own issues; read-only inspection (#443) is the part with a current
  requirement.

## Issue and board hygiene for this snapshot

- **#17 is closed**, so the immediate foundational issue is now **#445**, the
  spinlock. #17 sat as a one-line stub for two months precisely because
  nothing was blocked on it; it took one session once something was.
- Decide once, rather than per issue, what triggers investing in a locally
  built and patched LLVM. **#123**, **#300**/**#425**, and **#450** are all
  waiting on the OCaml bindings, and building LLVM is the expensive part.
  #450 proposes the trigger: two or more of them blocking work that is
  actually scheduled at the same time, rather than a count of open issues,
  since a gap nobody is blocked on costs nothing to leave.
- Keep the M0 phases in separate issues with their own closing bars rather than
  collecting them into an SMP umbrella. The previous snapshot's "treat SMP as
  one coherent milestone" was right about the ordering and wrong about the
  issue shape: an umbrella's closing bar drifts upward.
- Re-verify an issue's stated premises before building on it. **#222** and
  **#261** were both found to name globals, files, and primitives that no
  longer exist; both have corrections recorded as comments rather than silent
  rewrites.
- Promote **#56** and its prerequisite **#426** once M0 Phase 0 is stable, so
  QEMU becomes the external PR gate before active contributor recruitment.
- Re-scope or close stale umbrellas whose completed work has moved elsewhere:
  **#149** and **#182**.
- **#336** -- flag `kernel/` workaround comments citing closed issues. Cheap,
  and this snapshot's staleness audit is the argument for it.

The board answers "where is this now"; this file answers "why in this order".
Board changes are separate actions and are not performed merely by documenting
the recommendation here.

## Relationship to YAGNI

- M0 is not speculative concurrency work. A second core already boots and
  already activates a shared page table; the milestone makes the kernel honest
  about a configuration it is already in, and every phase has a workload or a
  view as its acceptance criterion rather than a capability.
- M1 closes gaps that have identified real call sites, not a general proof
  language.
- M2 exploits the already-landed QEMU port and limits review load before
  inviting contributions.
- M3 keeps language research accountable to useful kernel behavior and real
  hardware.
- M4 packages evidence already produced by the project; it does not begin a
  theorem-proving program without a concrete obligation.
- The deferred items preserve dependency order without authorizing work.

When this ordering conflicts with a concrete present requirement, the concrete
requirement wins and this dated snapshot should be refreshed again.
