# Takibi roadmap

This file is a dated mid-term plan for the project's ultimate goal: a
practical, monolithic, Linux-syscall-ABI-compatible Unix-like kernel written in
Takibi, whose runtime-error surface is lifted to compile time. It is a plan,
not a contract. `AGENTS.md`'s YAGNI principle still decides what gets built:
the ordering below does not authorize speculative implementation.

Written 2026-08-27 against the 99 open GitHub issues at that date. **The
baseline below is that date's; the two territory queues were re-cut on
2026-09-10** and carry their own dates, so read a queue's own heading rather
than this one for what is current. The previous
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

## Work split between two agents, 2026-09-05

Two agents run in parallel, one per territory, with the territories and the
shared-file conventions defined in `AGENTS.md`. This section is the part that
moves: when a new issue outranks what is queued below, edit it here.

**Codex holds Territory A. Claude Code holds Territory B.** The one measured
asymmetry is compiler experience -- of the last 40 commits by each, Codex
touched `lib/` 19 times and Claude Code did not -- and Territory A's
highest-priority items (#452, #450) are compiler work.

### Territory A queue -- the multicore critical path

The order is forced by M0's phase dependencies below, not chosen. Skipping an
entry leaves the next one unable to be verified.

1. **#448** a workload occupying two cores -- complete on QEMU and RPi5.
2. **#431** SIGCHLD/kill is closed. **#432** nanosleep is partly complete;
   remaining-time writeback still needs an observable early wake.
3. **#222** per-core scheduler state -- closed.
4. **#479** raise `KERNEL_ACTIVE_CORES` and clear its compiler-derived
   worklist -- complete for the deliberately admitted busy-loop workload.
5. **#483** the network stack's unsynchronized non-pool state -- the same
   files as #479, so the same hands.
6. **#478** the spinlock excludes but does not arbitrate -- closed with the
   measured unfairness retained as an explicit limitation; FIFO replacement
   waits for a real bounded-wait requirement and #450's compare-and-swap.
7. **#504** one world-stopped token -- closed.
8. **#452** make a lock say what it protects to the compiler -- complete,
   including the page allocator. **#466** lock order is complete: live linear
   guards and transitive minimum-rank acquisition summaries reject the
   Mutex-to-TaskMutex inversion, while equal-rank Mutex instances remain with
   the existing instance-level checks. **#450** compare-and-swap is complete:
   the local LLVM C-API bridge preserves backend instruction selection, and
   `spin_trylock` is its first caller. Next: **#261** PTE mutation against the
   hardware page-table walker.
9. **#261** PTE mutation against the hardware page-table walker.
10. **#9** processor affinity, with four cores.

Then, in this territory and unordered: #518, #468, #464, #516, #308, #414,
#514, #202, #476, #386, #274, #493, #422, #252, #216, #297, #131, #132, #343,
#342, #370, #374, #203, #200, #201, #212, #282, #417, #400, #109, #129, #155,
#267, #28, #58, #13, #95, #8, #528.

#### Territory A cold-start handoff, 2026-09-09

The maintainer authorized Codex to cross both territories for the two-core
blockers while Claude Code was unavailable.

**Status corrected 2026-09-10, by the other territory rather than this one:
#479 and #448 are both closed**, and the paragraphs below were written while
they were not. Read them as the investigation record they are -- the stalls,
the hypotheses and what each commit repaired are still exactly right and still
worth reading -- rather than as a description of what is left to do. What is
left is entry 5 onward: #483, #478, then #452 with #466 and #450 behind it.

Two things Territory B did on 2026-09-10 that this territory should know.
`kernel_log_tx_stand_down()` now returns the console state it FOUND, as a
`must_use` token with a third case, `NotConsoleOwner`, for a peer -- so a peer
stands nothing down and puts nothing back, and cannot re-arm core 0's queue
underneath a terminal path. And DDB has a `wait` command that derives the
causal wait edges from the stopped snapshot: on a two-core stall it says which
process is blocked collecting which child, which are waiting on events, and
whether the running process is one somebody is blocked on. That last digit is
issue #524's shape, and it is now one line rather than three views correlated
by hand.

The exit ASID reserve/prepare/revalidate work and remaining activation audit
landed in edd59f93 and 393519dd. Commit 055d09dd made ext2 scratch and crash
capture per-core and suppressed peer ordinary printk fragments. These remove
build assertions, not the need to verify their runtime contracts.

The working tree contains experimental secondary scheduling, a two-core
constant, peer timer scheduling, and an initial busy-pair PID admission gate.
That gate is diagnostic staging only: subsequent scheduling can select other
processes, so it does not enforce an I/O or syscall safety boundary. Do not
commit it as the finished two-core design or weaken the workload's original
restart and completion expectations to make it pass.

QEMU GDB captured the first stall in kernel_process_exit_would_strand on core
1 while core 0 computed in EL0. PID 1 was blocked waiting for SIGCHLD; exit
admission counted wait4 but not that signal wake. The predicate now recognizes
the exact blocked signal and wait-set combination, with positive and negative
cases in the existing scheduler probe. With that change the workload advances
to a later failure, not successful completion.

QEMU next stopped core 0 at the exception-entry stack guard with SP
0x403d0000, while core 1 entered crash capture from
kernel_syscall_clone_child_return. The peer snapshot identified PID 36.
An uninitialized clone stack being scheduled is a hypothesis: clone publishes
Ready before installing the saved frame, and context_install publishes the
parent Ready before writing saved_sp. Commit 29ecde8f repairs those logical
publication windows: clones stay Constructing until their frame is installed,
and the parent frame is saved before Ready publication. The scheduler probe
exercises both production selectors and a deliberately selectable negative
control. This does not establish physical stack ownership. Still audit outgoing Ready/Exited
publication before the old CPU stops using its process stack. Do not treat a
run-lock release as proof that the physical stack switch has happened.

Use the actual running ELF for GDB symbols: normal and debug kernels have
different addresses. The historical takibi-oops helper reads core 0 only;
peer evidence is in crash_snapshot_per_core[cpu]. Commit bf10db5c makes terminal
crash and stack-guard output bypass ordinary suppression and retained-line
assembly on every core. Ordinary peer text is still suppressed. Use DDB
first when responsive; use QEMU GDB or RPi5 OpenOCD for raw per-core evidence,
checking that all inspected CPUs really stopped. No two-core RPi5 success has
been established by this investigation.

The same experimental tree was then run on RPi5. Network and both HTTPd GETs
passed, and the busy pair emitted its measurement, but no restart/done marker
arrived. After the lane failed, OpenOCD confirmed both active CPUs halted in
EL0 at PC 0x400103c0, unlike QEMU's captured kernel failures. The subsequent
CPU-context kernel-memory read aborted in OpenOCD; later register reads also
failed, so those later states are not valid evidence of the original guest.
The board was reset successfully to the resident stub (EL2H, MMU disabled,
PC 0x800e4). Before another invasive read, use a debug access path appropriate
to an EL0 halt and account for dirty caches. Audit the suppressed completion
marker: workload_busy_restart_step prints only from B, which ran on core 1
in this hardware measurement. Missing text is not proof that the restart
failed. Commit 0346845e preserves B's original restart verdict and freezes its
inputs, then lets a core-0 progress syscall publish the pending result. Both
QEMU and RPi5 subsequently printed the positive restart and completion markers.

The current reproduced blocker is ordinary console delivery, not a missing
busy-pair restart. In the RPi5 capture 20260909T104013Z, interactive HTTP GETs
and the transfer measurement passed, but lifecycle text was missing. In QEMU
capture 20260909T211357Z, the busy-pair view passed and DDB completed a world
stop with mask 2. Both CPUs were running busy-loop processes; HTTPd's worker
was blocked on NetRx, its parent on ChildExit, and no clone remained
Constructing. The host waited for a listener notification suppressed on the
peer before sending requests. The injected DDB break was an investigation
action, not the original failure. This run passed 43 of 44 views, not the lane.

Next repair ordinary multi-core console delivery without sharing core 0's
partially assembled retained line or making crash/DDB reporters wait on a
lock. Account explicitly for fragmented lines, direct userspace bytes,
overflow, and a world stop interrupting a console drainer. Do not add another
subsystem-specific notification exception or weaken the expected markers.
The PID admission experiment still does not constrain subsequent scheduling.
Physical outgoing-stack lifetime, per-core workload accounting, and peer PMU
handling remain separate audits before the two-core acceptance claim.

The rollback audit also found an independent, deterministic process-tree
defect: cancelling a clone cleared the parent's whole child-list flag, losing
older live children and zombies. Rollback now restores the head to the
cancelled child's next sibling under the run lock before reaping. The fanout
probe cancels a fourth clone, checks counts return to baseline, and still
collects each original sibling by pid and status. The one-core main QEMU lane
and the allocation-refusal lane pass. This fixes error-path bookkeeping, not
ordinary console delivery or the physical outgoing-stack boundary.

The three completed fixes passed the one-active-core QEMU main lane (all 44
views and the kernelsh PTY script), all four QEMU oops cases, and langcheck.
Both target kernels build under forbid-trap with the two-core experiment.
The experimental activation changes remain uncommitted; neither a complete
two-core QEMU lane nor a complete two-core hardware lane has passed.

Integration update, 2026-09-10: rebased onto upstream 63e9d3c5. Upstream now
has an interrupt-driven 512-byte TX queue and common uart_putc in printk,
so the console task must extend that implementation rather than add another
transport. The resolved integration keeps that queue and its accounting
core-0-only; peer ordinary suppression and direct peer userspace output remain
explicit limitations. Emergency entry stands down the owner queue before
terminal text, including stack guards that never reach crash_console_run.
The rebased one-core main lane passed all 45 views and PTY, and all four oops
cases passed. Earlier two-core captures describe the pre-queue binary; do not
reuse their addresses or treat them as post-integration test results.
The first post-integration two-core QEMU run, capture 20260910T021642Z,
passed 44 of 45 views: restart/done and all interactive HTTP GETs passed,
while httpd_interactive_lifecycle lacked only the child-selected line.
The stack-overflow lane and langcheck also passed on the integrated tree.
The experimental peer timer policy now lives once in secondary.tkb, called
from both interrupt dispatchers; the upstream inline-duplication check
correctly refused the former duplicated sequence.

Completion update, 2026-09-10: `KERNEL_ACTIVE_CORES` is 2. Core 1 admits only
the persistent busy-pair B process; the ordinary selector enforces the same
boundary after initial activation, so init, ash, HTTPd, filesystem, network,
and direct userspace console paths remain on core 0. B takes its own timer
interrupts and progress syscalls. Complete peer log lines publish through a
bounded release/acquire ring to the sole core-0 retained-log and UART-queue
writer, while fatal/DDB output remains independent.

The two-core QEMU main lane passed three consecutive runs and a later full
QEMU check passed. RPi5 passed all 44 views, network and HTTP integration,
then DDB world-stop with peer mask 2, guarded-fault recovery, and shell resume.
The RPi5 helper now catches core 0 at an EL1 IRQ breakpoint before changing a
test byte and rejects OpenOCD's status-zero DSCR errors unless read-back
confirms the write. Fresh CPU-time evidence reports QEMU A/B as
30203442/25865922 cycles and RPi5 A/B as 9557022/7855074 cycles; the host
collector rejects a zero peer contribution.

The unchanged one-core fixture also passed QEMU main, four oops cases, and the
stack-overflow lane. This closes the #448/#479 two-core workload milestone,
not general process migration: physical outgoing-stack ownership and peer
access to filesystem/network/direct userspace UART remain later requirements
whose first admitting workload must carry its own audit.

#432's remaining-time writeback still awaits an observable signal-handler
interruption, not the busy-pair workload.

The paragraphs below retain earlier increments and their rationale.

The next profiling increment needs more than passing a `WorldStopped` token
into the current start/finish functions. They run under `ProcessRunGuard`.
The run-lock IRQ mask is now preserved until unlock, and profiling producers
keep activation checks and writes within one local IRQ-masked section.
Start and finish now reserve their boundary under the run lock, release it,
obtain a complete world-stop token, then revalidate under the lock before
resetting or reading per-core state. Busy and partial stops cancel the
reservation for a later progress syscall to retry. Next implement local PMU
start/stop on every process-running core. Keep the existing multicore
assertions until that boundary is exercised from the peer.

The timeline assertion is removed after that boundary audit. Its buffers are
per-core, activation and closure occur under complete world-stop, and each
event is published with local IRQs masked. The host workload profiler already
merges the stable per-core streams by timestamp, CPU, and local sequence. A
fresh two-core negative build then reported eight unique blockers and no
timeline diagnostic.

Flat PC sampling remains intentionally single-core, now with an explicit
interval owner. The complete-stop start boundary records the CPU that arms
the PMU; when both tags reach exactly eight rounds their counters freeze, and
only that CPU's next progress syscall may request the complete-stop finish.
Thus the same local PMU is started and stopped without inflating the workload
result while accounting and timeline evidence still cover every active CPU.
The two profiling assertions are removed. A fresh negative build now reports
six unique blockers, none in the profiling files.

`IntrusivePool` ordinary Live views now own the pool lock from validation
through payload use. The explicit unproven path remains only for stopped
reporting, the stale-cursor contention test, and the eleven caller-owned
pointer-lifetime escapes already counted by the trusted-base check. The
maintained two-core probe reads a payload while core 0 observes the lock held,
then observes it released when the linear view is consumed. The pool assertion
is removed; a fresh negative build reports five unique blockers.

Before adding repeated interval stops, the world-stop controller now separates
its nonblocking claim gate from the owner identity and uses non-reused request
generations. Old acknowledgements cannot satisfy a fresh stop, and a failed
claim cannot restore an owner that has already released. The maintained probe
adds sixteen immediate stop/release pairs and a stale-ack negative control.

ASID assignment now has a nonblocking attempt that returns either a complete
assignment or `RolloverNeeded`, plus a rollover entry requiring a
`WorldStopped` token. The maintained address-space probe crosses the 16-bit
edge only through that entry after stopping both cores; QEMU and RPi5 exercise
the real SGI and acknowledgement. At that increment, production scheduler
activation still used the one-core entry under `ProcessRunGuard`, so the
blocker remained until the reserve-stop-revalidate switch described on #479
was added.
Address-space activation is also split into a fallible preparation and a
linear prepared value whose only consumer commits TTBR0. Preparation changes
neither TTBR0 nor the per-CPU target-root record; the probe now reactivates its
stale running root through this boundary. The process-image wrapper publishes
its target-root and trace only after address-space commit succeeds.

The ordinary timer/deferred scheduler path now uses that split. It takes the
target's existing linear owner and changes its state from Ready to Running as
the reservation, drops `ProcessRunGuard`, prepares the ASID, then reacquires
the guard and revalidates both handles and states before committing TTBR0 and
the logical current process. A failed preparation, world stop, or revalidation
returns the reserved target to Ready through the same linear state token. At
this point the block, clone, and exit handoffs still used direct activation;
the next increment moved the common blocking path as described below.

The common blocking handoff used by UART, network, wait4, deadlines, and
signal waits now uses the same reservation and preparation sequence. Its
caller-held IRQ mask remains in force while `ProcessRunGuard` is temporarily
dropped, preserving the UART final-empty-check to Blocked-publication
boundary. Commit revalidates both processes before publishing Blocked; every
earlier failure returns the target reservation to Ready, and even the
defensive activation-failure arm reconstructs the outgoing Running state.

Clone success and clone rollback now prepare the logically current child's or
parent's ASID outside `ProcessRunGuard`, then reacquire the guard and revalidate
that the same process is still Running before committing TTBR0. An incomplete
world stop or stale current handle fails the syscall continuation instead of
returning through a frame under the wrong address space. Exit handoffs remain.

#### Handed over from Territory B, 2026-09-07

**#524 is the one that should be read first, and it is not a decision -- it is
an attributed defect with a reproduction.** The QEMU lane's oldest
intermittent, #509's stop point at `linux socket: listener ready port=8080`,
has a cause: the connected-fixture child calls accept, which may hold
non-preemptible EL1 while `kernel_process_other_ready()` is false -- and it is
false because the only other two processes are that child's own parent and
grandparent, both blocked on ChildExit waiting for it. The condition that
authorises holding the machine is produced by the thing the machine is being
held for. It does not resolve after the 30s accept deadline either: EL0 retries
and `kernel_tcp_accept_begin` resets the window, which is why the measured
silence is 175s and CI's was 218s rather than 30s. Two DDB captures are on the
issue, one with the process in the kernel and one in its userspace retry loop.
This failed CI on 2026-09-07 and is the reason that run needed re-running.

#### Handed over from Territory B, 2026-09-06

Four things this territory owns that Territory B found and could not decide.
None is queued above; they are recorded so they are not rediscovered.

1. **#520 needs an attribution, and only Territory A can make it.** The
   kernel's TCP path was measured at 15.6 KiB/s, flat across two orders of
   magnitude of transfer length, which is 12x slower than SWD and about
   0.013% of the RP1 GEM link. What the measurement cannot say is where the
   time goes: it spans host stack, wire, kernel and BusyBox with nothing
   separating them. The instrument already exists -- `profile: cpu` reports
   wall, EL0, EL1, IRQ and idle cycles for a named interval -- but is emitted
   for the `busy-pair` workload only. A second named interval around a bulk
   transfer is the missing piece, and it is also what #497's first milestone
   still needs.

2. **A `freelist contention` probe failure, seen once and not chased.** On
   2026-09-06 `kernel/qemu-debug view: pool_contention` failed with
   `freelist contention stage: incomplete` / `freelist contention: failed`
   where the expected view has `unlocked` then `locked`. Three consecutive
   re-runs passed. Recorded rather than filed because one sample is a rate of
   nothing; if it recurs, that is two, and the probe reported its own
   incompleteness rather than passing about nothing, which is the behaviour
   `kernel/CONCURRENCY.md` asks for.

3. **Whether #89's closure covers the escaping-index shape.**
   `scripts/find_stale_issue_workarounds.py` reports
   `linux_user/field_lease/field_lease.tkb` and its `examples/` twin as
   saying they "do not yet solve issue #89's actual fd-table shape (an
   escaping index into a table living past the acquiring function)", and #89
   has closed. Deciding it means reading the compiler's affine analysis. If
   the shape is now handled the comments should go; if not, they should stop
   naming a closed issue as the reason.

4. **The probe-verdict rule is documented but not mechanised, and the reason
   is a property of the probes.** `kernel/CONCURRENCY.md` now requires a
   probe's verdict to carry a term that is false when the probe did no work,
   asserted rather than printed. A build check was judged not writable
   because the probes disagree on shape: a trailing
   `return advanced == calls && overlap > 0`, a chain of guards ending in
   `return true`, and a two-phase verdict split across a helper called twice
   all appear today, and the cheap approximations fire on correct probes. If
   this territory converges the probes on one verdict shape, the check
   becomes possible and is worth revisiting.

### Territory B queue -- making two cores debuggable

**Re-cut 2026-09-10, and the re-cut is the point.** Until now this queue was
ordered to AVOID Territory A: entries were ranked by how little they needed
from it, because everything that needed something from it was blocked. That
was right while M0's foundations were unfinished. It is wrong now.

#504, #479, #222 and #448 all closed, and with them the four entries this file
listed as "Waiting on Territory A" became startable -- #456, #486, #505 and
#465. All four are in this territory's own files
(`kernel/arch/arm64/kernel/exception_evidence.tkb` and `kernel/printk/`), and
all four are about the same thing: what the machine can still tell you once
two cores are running. That is not a backlog beside the milestone. It is the
milestone's other half, and it gets more valuable as Territory A moves toward
four cores, not less.

So the order below is now what Territory A will need when a two-core run
fails, ahead of what merely does not collide with it.

The first five entries of the 2026-09-05 order closed on 2026-09-05 and
2026-09-06: #513, #515, #471, #387, #411, #336 and #56, plus #519, which was
filed and closed the same day, and #521, filed 2026-09-06 and closed
2026-09-07. #280, the sixth of the original order, was measured and then
deliberately parked; see below.

`make cicheck` -- allcheck minus the RPi5 lane -- now runs on every push
through `.github/workflows/ci.yml`, and reports where its own minutes went so
the first iteration's costs can be read rather than guessed. Hardware stays
out of CI: there is no always-on host, so a scheduled run would take the board
at the moment the workstation came back, which is when a person wants it.

Getting that first workflow green took five rounds, and four of the five
failures were latent defects rather than workflow mistakes -- a hosted runner
is a second machine, and this repository had only ever had one. What it found:
a dependency the build declared and nothing installed, a check that read every
file named `dune` including a switch's binary, QEMU lanes asking for more
guest vCPUs than the runner has cores, a host-side network peer that raced the
guest's boot with a single un-retried request, and `awk` leaving `llvm-nm`
holding a closed pipe.

The last of those, #521, is now closed both halves. `check_pipefail_early_exit`
refuses the pipeline shape at `langcheck` time -- narrow deliberately: the wide
rule matches 27 sites in this repository, almost none of which can fill a pipe,
and a check that fires 27 times on arrival is one people learn to silence. The
27 stay ungated and the evidence for that choice is reproducible rather than
remembered, since widening the rule makes the tree fail.

Three things came out of those five rounds that outlive them. Nineteen lane
runners now carry an ERR trap naming the script, line, command and status, so
an abort in a log nobody ran says what it was -- the round spent on `exit 74`
had no such line. `make cicheck-as-ci` reproduces the runner's constraints
here (four cores, one lane, CI's guest budget), and says in its own comment
what it does NOT reproduce: per-core speed, which is what actually starved the
guest, and which a CPU quota cannot supply from inside this devcontainer. And
asking whether other waits obeyed the constraint the repaired one documented
found the host peer's interactive readiness wait outlasting its own outer
`timeout`, so its give-up could never have printed; both waits now share one
budget derived from `KERNEL_QEMU_TIMEOUT`, with the first offline control this
file has ever had.

#280's own number is now measured and it closed the option it was expected to
open: the wire sustains 15.6 KiB/s against SWD's 187.4, so a network-delivered
rootfs is blocked on #520 rather than merely unproven. What that leaves
untested is persisting the rootfs across runs, since the board already writes
the same filesystem to USB at about 29.8 MB/s.

#336 left two stale references rather than an unowned design question:
`scripts/find_stale_issue_workarounds.py` reports `linux_user/field_lease`
and its `examples/` twin as saying they do not yet solve issue #89's
escaping-index shape. The closing comment on #89 explicitly split that exact
remaining shape to open issue #131. The historical example is not edited for
parity; #131 already sits in Territory A's unordered queue.

**Both of the 2026-09-07 Territory A audit's handoffs are done.**
`kernel/RUNTIME_STATE.md`'s FD section no longer says both `fd_slot_total` and
the per-process block chain are unlocked; only the second is, and for a reason
rather than for want of a lock. **#511 is closed**, by the prompt trigger
rather than by the silence trigger that was reverted: an ordinary lane now
walks `oops`, `intr`, `bt`, `sched`, `current`, `ps` on sight of a `ddb> ` it
never expected, and ends there instead of at its budget.

The main QEMU lane also asks for a prompt when the guest stops without
reaching one, over a QMP monitor it now opens on every run. That fires only
inside the last stretch of the budget the walk itself needs, with the guest
quiet for a quarter of the budget, so it cannot stop a run that would have
passed -- the measured longest silence in a healthy boot is 4.0s against a
22.5s threshold at 90s and 60s at CI's 240s. Run against #509's own
reproduction it produced a ten-frame backtrace and
`sched ... ready=0 running=1 blocked=2`, which names that stall as #509's
second sample -- accept holding the machine from nobody -- rather than
leaving it inferred.

**CI failed once on 2026-09-07 with #509's exact signature** and the failing
commit changed only documentation, so it is not a regression. Six consecutive
runs of the lane pinned to four cores with CI's budget all passed, which is
the gap the workflow already documents: `taskset` reproduces a hosted runner's
core count and not its per-core speed. What was missing was any account of
what the guest was doing, and that is what the paragraph above supplies. The
next occurrence answers it in the lane's own artifacts.

1. **#486 closed 2026-09-10, and it was NOT the close this entry predicted.**
   Territory A had added `crash_snapshot_per_core` and
   `crash_snapshot_capturing_per_core`, so the storage half was done -- but
   the reader still rendered only the calling core, the fault order between
   two cores was unrecoverable (`sequence` counts one core's captures), and
   publication was an ordinary store rather than a release. Checking the tree
   before writing is what the entry asked for and it is what turned a
   predicted close into three-quarters of an implementation. The next entry's
   prediction deserves the same suspicion.
**What #486 became, and what its lane found.** The machine-wide fault ticket
orders two cores' faults; `valid` is published with release and read with
acquire; the console's `oops` renders every published record in that order and
says how many it found. One core runs the console -- claimed by a swap that
never waits -- and the others park after reporting.

Then the two-core lane was written, and it immediately found what reasoning
had not: both cores wrote the UART at once and shredded each other's reports
byte by byte. Both records survived in memory, so the acceptance criteria held
and the output was unreadable, which is the moment a crash reporter exists
for. The repair is a report claim that every write in that file takes and the
blocking read does not -- a bounded spin that renders ANYWAY on expiry,
because a wedged core must not silence one that still has something to say.
`abandoned=0` in the summary is the lane's assertion that the bound is still
enough; if it fires, the bound is investigated rather than raised.

The last thing to fall was the smallest. A parked core's line landed inside
the word `ddb> `, which stopped the lane's driver counting prompts and turned
the run into a timeout -- 1-in-3 before the console's own prompt joined the
claim, 8-in-8 after. Two cores racing one UART is not only ugly; it silently
disables whatever is reading it.

2. **#505 closed 2026-09-10.** `bt PID` for a Running process used to answer
   "capture that cpu" and nothing could. The stop protocol the issue asks for
   already existed -- DDB only inspects on a Complete world-stop token -- so
   what was missing was a ROOT for a CPU that is not the one running the
   debugger. The peer publishes one as it enters the holding pen, which is the
   only moment its own interrupted frame is addressable and costs the stop
   nothing, and retires it on the way out so a stale root cannot read as a
   fresh one. `bt cpu N` selects it; a Running process now resolves through
   the CPU holding it. Two refusals stay distinguishable and neither is a
   trace: a CPU that never acknowledged, and a root that moved under the read.

   Three things worth carrying. The publish/hold/retire body went into
   `exception_evidence.tkb` rather than into both platform dispatchers,
   because `check_platform_file_parity.py` refused the first version -- three
   added lines took the shared run past its threshold, which is the check
   working rather than complaining. The decision that cannot be exercised with
   one core (a value moving between two loads) was separated into a pure
   function that `bttest` drives through all five verdicts. And
   `check_kernel_ddb_postmortem_controls.py` read `bt [PID|cpu N]` as a
   command with a required argument, because it split usage on spaces; a
   bracketed group is one optional token even when it contains one.
3. **#456 closed 2026-09-10.** The rendezvous already existed and the queue
   entry said so; what was left was the guarded read's arming, and the reason
   it mattered turned out to be sharper than "two cores cannot be told apart".
   The WRITER is the one core inspecting, which is what the world-stop token
   guarantees -- but the READER is whichever core takes a data abort. A peer
   faulting for a real reason at the address DDB happened to be reading had
   its fault swallowed: redirected to DDB's own recovery label, landing that
   core in the middle of a read it never made, while DDB reported a fault it
   never took. One shared word, two wrong answers.

   Per core, a core can only match its own arming. The decision -- armed, the
   right exception class, the right address -- is a pure function the existing
   `xkfault` gate drives through all four cases, because each of the three
   conditions alone has looked like a match. DDB's snapshot stays
   machine-global on purpose and the file now says why: one writer, and the
   complete token is what says so.
4. **#465 closed 2026-09-10.** Codex's publication was sound -- release
   publish, acquire read, the sequence verified before and after the copy,
   overwrite reported -- and it handed the peer's bytes to core 0, which
   retained them as core 0's own, timestamped when core 0 got round to them.
   Both wrong in the direction that matters.

   The record carries the writing core and that core's own tick now, and the
   replay prints `cpuN ` for anything that is not the console owner, so a
   single-core dmesg is byte-identical and a peer's line is the one that could
   not previously be told from core 0's at all.

   Two things worth carrying. The ordering rule is stated rather than
   inferred: the ring's order is arrival at core 0, because core 0 is its only
   writer -- which is what makes a separate sequence number unnecessary --
   and a record's timestamp is when its OWN core emitted it, so a peer record
   can carry a tick earlier than the record before it. The dmesg validator's
   monotonic rule is per CPU for exactly that reason, and it caught the change
   the moment the first peer line was retained.

   And the whole facility was unobservable. No maintained boot path had a
   secondary emitting ordinary log text, so publication and attribution alike
   could have stopped working with every lane green. A bounded four-line peer
   probe runs on every boot, for the same reason the two-core contention
   probes do, and the shared `dmesg` view compares it on both lanes. The
   effect checker decided where it lives: an `!{interrupt}` version was
   refused for reaching `kernel_boot_log`, which is also the only reason the
   peer's publish path is reachable from the secondary's ordinary loop and
   nowhere else.
5. **#520** and **#497** -- and this entry's own prediction was wrong, which
   is worth more than the entry was. It said the missing second
   `profile: begin name=` interval was now "a small edit this territory can
   make for itself" under the relaxed territory rule. Reading the instrument
   on 2026-09-10 says otherwise, and the correction is on #520:

   `workload_profile_start`/`_finish` are called from exactly one place each,
   inside the busy-pair state machine, and both take a `WorldStopped` token
   and a `ProcessRunGuard` -- an interval begins and ends at a complete world
   stop, which is what gives every core the same boundary. The wall span the
   report divides by is `workload_busy_pair.start_ticks`; the file names that
   struct 166 times. The per-core accounting IS generic and would serve a
   transfer unchanged; the interval around it is not.

   So a second interval needs the interval lifted out of one workload's
   struct, a world-stopped boundary of its own, and an EL0 trigger bracketing
   a transfer that BusyBox `httpd` knows nothing about. That is #497 stage
   1/2's own work in Territory A's file, not an edit across the boundary.
   Then **#502** call chains and **#503** PMU counters.

   **Do not start this from here.** What a Territory B session can do is what
   was done: read it, say so, and leave the measurement standing.
6. **#208 first, then #281**, and the order is measured rather than argued.
   `block io: reads=124173 writes=55 block_bytes=1024` on QEMU and 129384 on
   the board -- about 126 MiB of 1 KiB block reads for a 2.5 MiB filesystem,
   roughly fifty times the whole image, in a boot that reads a handful of
   files. That is not a coalescing shortfall; it is the same blocks read over
   and over, because `ext2_inode_block_pointer` re-reads the inode table and
   the indirect blocks on EVERY 1 KiB chunk `ext2_read_file_chunk` returns.

   #281 coalesces contiguous DATA runs, which is the minority of that number.
   #208's cache is what removes the majority, and it makes #281 worth doing
   afterwards rather than instead. The figure is printed on every boot and
   `validate_kernel_dmesg_timestamps.py` is its reader, so whichever lands
   first is judged by the same number in a diff.

   **#182 was split and closed 2026-09-10.** It was a follow-up to #177 and
   described a 1 MiB, one-block-group, direct-block-only filesystem; about
   half of its ten scope bullets had since been done under other numbers --
   indirect reads, multi-block directory lookup, path walking into
   subdirectories, `getdents64`, and the offset validation. The remaining five
   have different dependency chains, which is why the bar kept rising:
   **#535** indirect writes, **#536** multiple block groups, **#537**
   directory mutation beyond root and beyond one block, **#538** the three
   missing directory syscalls (behind #537), and **#539** long symlinks. The
   evidence table is on #182.

   Of those, **#537's first increment landed 2026-09-10**: the directory is a
   parameter and its blocks are walked, so a file can be created, read and
   unlinked in `/etc` on both lanes and over real USB. What #537 still wants
   is growing a directory by a block when none has room, and nested `mkdir`
   with `.`/`..` and link counts -- the two halves that need allocation rather
   than a walk. #538's three syscalls wait on those.

   The one-block scan became a per-block scan because an ext2 directory entry
   never spans a block: each block is self-contained and its record lengths
   sum to the block size. That is why only the modified block is written back.

   **A finding for Territory A while running this.** One `cicheck` in twelve
   lanes produced `process table: records MISSING uses=1 first_slot=0x403b37c0
   reason=2` on the qemu-debug lane, and `resources: every pooled record
   resolved to the slot its handle named` was absent. Three consecutive
   re-runs of that lane alone passed, and so did the next full `cicheck`. One
   sample is a rate of nothing -- recorded rather than filed, the same way the
   2026-09-06 `freelist contention` sample was, because the probe reported its
   own incompleteness rather than passing about nothing. If it recurs, that is
   two.
7. **#388** stack-overflow coverage for the hand-written vectors (Territory
   A's files), **#429** in-kernel GDB stub, **#149** GDB without JTAG,
   **#444** controlled DDB memory mutation.

**#523 carries CI risk** -- it edits `dune-project` and
`.github/workflows/ci.yml` -- so like #526 before it, it wants a quiet window
rather than a place in this order.

**#526 closed 2026-09-10**, with the maintainer saying so and Codex holding
still for the quiet window it needed. `langcheck` had grown from
one non-ASCII grep into a hand-listed gate of forty-eight invocations, and
a wall-clock control inside it cost CI nine consecutive runs on 2026-09-07;
for several of those rounds it gated `allbuild`, so no kernel lane ran and
the real defects behind it stayed invisible.

Both lanes are globs now, and the prefix is the dispatch: `check_*` reads
tracked files and runs in `make langcheck` under a timeout, `slowcheck_*`
waits on something real and runs in `make slowcheck`. The agreed design did
not cover a third population the issue had not measured -- the five checks
that must be handed a linked ELF or a built kernel -- so those are
`buildcheck_*` and sit outside both globs, which is what keeps the prefix
meaning exactly one thing rather than usually one thing.

The payoff is measured, not argued: `langcheck` fell from 34-46s to 8.0s,
and the 34s of controls that used to gate it now run beside the kernel
lanes instead of in front of them. `allbuild`'s per-script escape hatch
(`ALLBUILD_DEFER_DDB_POSTMORTEM`) is gone with the wall clock it was cut
for.

Two things the acceptance list forced that were worth more than the
renaming. `check_pass_line_counts.py` now covers every member of both
lanes, and the thirty controls -- the one group nothing had held to the
rule -- assert a count of the scenarios they ran, so a control whose loop
never executes reports zero and is refused. And `docs/BUILD_CHECKS.md`,
which called itself the complete inventory while missing thirty langcheck
members, is complete and enforced.

The closing demonstration is the instance that actually occurred: the
2026-09-07 wall-clock control, restored under a fast-gate name, is killed
at the bound (`exit=124` after 10s) and the lane goes red. Two other rules
catch it even earlier -- it is not in the inventory, and it reports PASS
without a count.

Renaming `langcheck` and `allbuild` themselves is still deliberately after
this, not part of it.

#### Territory B cold-start handoff, 2026-09-10

**Entries 1 to 4 are closed. Start at entry 6, and start by reading the
tree.** That last clause is not boilerplate: this queue's own predictions were
wrong four times in a row on 2026-09-10, and every time the reading was worth
more than the entry.

- Entry 1 (#486) predicted "very likely a verify and close". Three quarters of
  it was missing.
- Entry 5 (#520/#497) predicted "a small edit this territory can make for
  itself". It is a restructuring of Territory A's profiling facility; the
  correction is on #520 and the entry now says not to start it.
- Entry 6 named #281 and #208 in that order. Measuring said the reverse:
  126 MiB of 1 KiB block reads per boot for a 2.5 MiB filesystem, which is
  metadata re-read rather than data uncoalesced.
- #182 predicted an implementation. Half of its ten scope bullets were already
  done under other numbers; it was split into #535-#539 and closed.

What each of those cost was one hour of reading and what it saved was a week
of building the wrong thing. Do the same here.

**The next piece of work is #537's second half**, and it is the one place a
session can pick up cold with no re-derivation: the issue comment written on
2026-09-10 says exactly what is done, what is not, and why. Growing a
directory by a block, then nested `mkdir` with `.`/`..` and link counts. Both
need allocation rather than a walk, which is what makes them the same shape
and different from the increment that landed. #538's three syscalls wait on
them, and so does lifting `getdents64`'s direct-block limit.

After that, **#208** -- and it is now the measured priority rather than an
option, with `block io: reads=...` printed on every boot as the number it has
to move.

Eleven issues closed on 2026-09-09 and 2026-09-10: **#339**, **#531**,
**#530**, **#529**, **#526** (with the maintainer's explicit go-ahead and a
quiet window), then the four the re-cut put first -- **#486**, **#505**,
**#456**, **#465** -- and **#182**, split into #535-#539 rather than finished.
Their entries below say what each found.

The four multicore-debuggability ones are worth reading together, because they
are one story: a machine with two cores can now say which core faulted and in
what order (#486), backtrace the core that is not running the debugger (#505),
arm a guarded read without answering another core's fault (#456), and attribute
a retained log line to the core that wrote it and the time that core wrote it
(#465). Before them, every one of those questions had a single global answer.

**The territory rule was relaxed on 2026-09-10.** The maintainer asked that a
minimal edit into the other territory be allowed rather than blocking an
issue: "please be tolerant of rewriting a minimum of each other's territory".
The boundary still holds for STRUCTURAL change to a file the other territory
is reshaping -- that is what it was measured to prevent, and the one conflict
in the 2026-09-10 rebase was exactly that shape and cost one careful merge.
But a counter, a print, or a named profiling interval is now a thing to add,
not a thing to wait for. Entry 5 exists because of that change.

**What the 2026-09-10 rebase cost, for calibration.** Three Territory B
commits onto Codex's two-core work produced exactly one conflict, in
`kernel/printk/log.tkb`, where both sides had changed
`kernel_log_tx_stand_down()` for different reasons: Codex made core 0 the only
writer of the console queue, and #531 made the function return the state it
found. Neither side was wrong and a textual merge of either would have been:
returning a peer's found state lets a peer's resume re-arm core 0's queue
underneath a terminal path. The merged answer is a third case,
`NotConsoleOwner`. Expect that shape rather than a clean apply, and read both
sides' reasons before choosing.

**#339 closed 2026-09-09.** Every one of `disk_initialize()`'s failure
points answered `DiskIoResult::Err(-1)`, so six different repairs -- controller
reset, ring setup, slot enable, Address Device, configuration, unit readiness
and block size -- arrived on the board as one sentence. They are now a closed
`UsbInitOutcome`, and the ones that received a controller completion code, a
transport status or a block size carry it. The public Media Access Interface is
unchanged: `disk_initialize()` still answers `DiskIoResult`, and the detail
survives the call in a record the boot path reads, so the driver keeps no UART
dependency.

Two things it found that reasoning had not. A `*u8` name cannot live in a
struct field -- issue #240 refuses it, because a raw pointer there still
supports arithmetic and can hide a lifetime relationship -- so the stage is an
exhaustive `enum` beside the variant and the name comes from a `match` on it,
which makes an unnamed new stage a compile error rather than a number in a log.
And the retry rule is the half worth testing: `kernel/drivers/usb/init_report.tkb`
keeps the FIRST failing status as well as the last, because a drive that
reports Not Ready fifty times and one that fails once for a real reason and
then goes quiet end at the same last status -- which is exactly what the
temporary retry diagnostic the issue was filed from could not tell apart.
`linux_user/usb_init_report` runs all of that natively, and the board proved
the unchanged success path: `make kernelcheck-rpi5` passed all 44 views,
`usb_storage` included. What no lane can show is the failure line itself,
since producing it needs a drive that will not enumerate.

**Those 13 commits are published.** The console TX queue (#454), the four
duplication removals #517 produced, the documented-count check (#522) and #338
were all pushed, and `origin/main` is at `deb445d`. This paragraph used to say
they were not; it is left here rewritten rather than deleted because the next
session reads the sentence, not the date on it. The tree is one commit ahead
again -- #339 -- and the maintainer still owns that gate.

**#517's residue is two declarations, both in `intc.tkb`.** The parity check
now compares inline runs as well as functions, and `ALLOWED_RUNS` is down to
`platform_world_stop_notify`'s target-list computation and the dispatch tail's
EOI write. Both want an abstraction that Territory A is actively reshaping for
#479/#483/#478, so they are worth doing alongside that work rather than
against it; a stale entry there is a hard failure by construction, so the list
cannot rot silently while it waits.

**#454's numbers are printed by `make kernelcheck-rpi5` on every run and QEMU
cannot judge them.** If a console change shows 78 us/byte again, that is the
queue not being used, not a measurement artifact. The figure is no longer
optional: `validate_kernel_dmesg_timestamps.py` refuses a complete boot that
does not carry the line, because no view can compare it -- it holds per-boot
numbers -- and the validator is its only reader. And `disable_irq`/
`enable_irq` are absolute: anything entered with interrupts already masked
must use `mutex_irq_save`/`mutex_irq_restore`. The measured shape of that rule
across the tree is on #528, which is Territory A's: every valid restore in
this kernel is conditional, and the four unconditional ones are all boot-time,
so the narrow lexical check that issue assumed impractical is in fact a
four-entry declaration list.
**#454 closed 2026-09-08**, and its numbers outlive it. Measured on the board
before and after: `console tx spin=2519 ms over 31919 bytes (78.9 us/byte)`
became `81 ms over 31999 bytes (1077 spun, 75.4 us each)`. `kernel_boot_log`
queues and returns; the TX interrupt drains and disarms itself; early boot,
DDB and the crash console keep the old spinning path, and the terminal ones
stand the queue down at entry so their output is byte-identical through
exactly the path it used before. `make kernelcheck-rpi5` prints the figure on
every run, so a regression shows in a diff rather than in a memory -- and it
prints QEMU's 0.5 us/byte too, which is the standing reminder that only the
board can judge this one.

Two things the work found that reasoning had not. `disable_irq`/`enable_irq`
are absolute, so a console that enabled them unconditionally unmasked
interrupts underneath any caller holding them masked, including DDB; the fix
is `mutex_irq_save`/`mutex_irq_restore`, which `kernel/lib/pool_lock.tkb`
already carried. And `check_platform_file_parity.py` refused the first
version, correctly: queue-or-spin, when to drain and when to flush are console
decisions, not platform ones, so they live in `kernel/printk/log.tkb` and the
platform keeps only the four MMIO primitives that differ by base address.

**#517 closed 2026-09-09.** The parity check compared functions, and #517 was
the same defect written inline -- a 57-line probe sequence byte-identical in
both platform `init.tkb` files while the check said PASS. It now compares runs
of eight or more significant lines as well, and the four it found became
shared files: the boot memory map, the secondary-core bring-up, the ext2
fixture, and the boot prologue. Two declarations remain, both in `intc.tkb`,
and a declaration that outlives its subject is a hard failure, so the list
cannot quietly become an inventory. The ext2 fixture also closed a coverage
gap nobody had filed: the mutation views were QEMU-only because they were
written there, not because the board could not run them, and they are now
`kernel/tests/common/views/`.

**#410 closed 2026-09-07**, and what it found is worth carrying: the tree held
six of these counters rather than three, four were matched by no filter at
all, and the two that would have failed a lane did so only because their
prefixes collide with lines the process-lifecycle view already wanted. All six
now feed one positively reported line a view expects, and
`check_fallback_counters.py` refuses a counter the gate does not sum. Its
first run found a fallback firing twice on every healthy boot, on both
platforms, whose counter had conflated "no target chosen yet" with issue
#270's hazard -- which is why that one had a counter and no reader for months
rather than by oversight.

**Territory note.** Three of the first four entries of the 2026-09-07 order
were not workable in this territory alone: #520 and #497 both reduce to one
missing profiling interval that lands in `kernel/net/tcp.tkb`, the file
Territory A is changing for #479/#483/#478, and #388's vectors are Territory
A's as well. #410 was taken with the maintainer's go-ahead to cross where
separation is not possible, and it crossed cheaply -- the edits in A's files
are a counter and a print. The boundary that matters is structural change to
a file the other territory is restructuring, not any edit at all.

**#280 closed on 2026-09-06, and the numbers it produced outlive it.** SWD is
at its 30 MHz ceiling at 187 KiB/s with 40 MHz and above failing outright; the
rootfs is 85% of what each run transfers; the board already ingests the same
filesystem over USB at about 29 MB/s; and the wire it was expected to move to
sustains 15.6 KiB/s, which is why that half became #520 rather than a plan.

Two of those keep working after the close. `make kernelcheck-rpi5` prints the
SWD bytes and rate and the wire's throughput on every run, so growth shows in
a diff rather than in a memory. And `kernel/MEMORY_MAP.md`'s 4.00 MiB image
ceiling sits 0.41 MiB above the current image, so the next meaningful rootfs
addition fails `langcheck` with the per-MiB cost of raising it in the
message -- which is the conversation this issue existed to force, now had by
whoever causes it rather than by whoever remembers.

Nothing in this territory is waiting on Territory A any more. #456, #486, #505
and #465 were, on #504, #479 and #222, and all three of those closed -- which
is what the queue above was re-cut around. The one remaining dependency is
listed as entry 5 and is now a small edit rather than a wait.

Unordered, and not in the queue above: #268, #283, #389, #430, and #275 --
whose body asks for compiler diagnostics, so despite its place in this list it
is Territory A work. Plus two the CI work left behind: **#522**,
counts written into prose that nothing derives -- **closed 2026-09-09**; the
one current count is derived from the tree the way its runner derives it, and
the check was verified against all four historical repairs, reporting at each
commit's parent the exact number that commit went on to write -- and **#523**, the build's dependencies written
down three times, of which `check_ci_opam_deps.py` compares two and the third
is already wrong; and **#529 -- closed 2026-09-10**, see below.

Two build checks landed with that audit, both narrow by measurement.
`check_irq_restore_sites.py` refuses an `enable_irq()` that consults nothing
about the state it overwrites -- the shape that removed DDB from RPi5 during
#454. Counted first: 25 call sites, 18 already consult saved state on the
line that restores it, 7 are boot-time, so the declaration list is four
entries rather than an inventory. It is lexical and says so; the transitive
case stays #528's.

`check_platform_view_parity.py` requires a view compared on one lane only to
say why. That question had been answered by accident twice this session, and
writing the eight declarations found two more: `linux_file` carried a QEMU
filter narrower than the common one, so the lane that runs on every push
asserted one of the two lines the board asserted, and `distro_image.expected`
was byte-identical in both platform directories. Both are shared now, 42
common views rather than 40. The check does not decide what should be common;
it requires the answer to exist.

**#531 closed 2026-09-10.** The console transmit queue never came back after
a DDB `continue`, so a single serial BREAK cost the rest of that run #454's
whole improvement -- 81 ms of spinning becoming 2519 ms on the board. It had
been written up as deliberate and was not.

`kernel_log_tx_stand_down()` now returns the state it found, as a `must_use`
token, and that token is the only argument the resume takes: there is no
`kernel_log_tx_resume()` that reads no saved state, so the shape
`check_irq_restore_sites.py` has to look for lexically in the interrupt case
is, for this flag, the only shape that type-checks. The crash console has to
match its own token and say that a path which never returns has nothing to
restore -- which is precisely what stops a path that does return from
forgetting.

The half worth carrying is the observer. The loss was invisible because both
DDB lanes end at the shell rather than at the boot's own `console: tx spin`
measurement, so `continue` now says which state it restored, and it READS the
console rather than restating what it just did -- a line printed from the arm
that does the restoring keeps saying `queued` after someone deletes the
restore, which would make the observer agree with the defect. Three lanes
assert it, and it was validated by planting the defect: with the resume
removed, `kernelcheck-ddb-qemu` fails on `ddb: console tx=spinning`. The RPi5
driver's control test gained a board that resumes correctly in every other
respect and leaves the console spinning, and fails.

**#529 closed 2026-09-10.** DDB already held every fact needed to explain
issue #524's stall -- `ps`, `sched` and `current` between them -- and the
relation between the facts was still assembled by hand. `wait` derives it: a
parent blocked collecting a child names that child; UART, network, deadline
and signal waits are event nodes, because the kernel does not know which
future process will deliver them and a guess would read as a finding.

Two things it turned out to need that the issue did not say. The listing asks
about a process that is Blocked OR carries a wait reason, not one that is
Blocked -- #524's child was the RUNNING process and its reason was the
network, so a loop over blocked records alone would have dropped the record
that explains the stall. And the header's `awaited` digit is the shape itself:
the current process is running and something is blocked on its exit.

It found its own case immediately. The QEMU DDB lane's ordinary boot renders
`current=8 state=running awaited=1` with two ancestors blocked collecting it,
and the board renders a four-edge chain including a parent waiting on a child
that is itself waiting for the network. Neither needed the stall to recur.

`waittest` renders #524's topology from records the debugger wrote, so the
presentation is compared by a lane rather than trusted; it costs two kilobytes
of static, and the images' 32 KiB stack-alignment granule is what actually
moved the boot views' allocator page counts. On the multicore tree that
retired `kernel/tests/qemu-debug/views/boot.expected`: the debug build now
lands in the same granule as the ordinary one, so the overlay held bytes
identical to the view it overlaid.
`buildcheck_kernel_memory_map.py` reads the ordinary view when the overlay is
absent, which turns the overlay's absence into a claim -- the two builds
agree -- rather than into a gap.
`check_ddb_wait_reason_names.py` holds the two namers to the enums
kernel/kernel/process.tkb encodes them from, and requires the word to be
spelled FROM the case: a reason added there and not named here would print
`unknown` where a word should be, silently, and only to whoever is mid-stall.
It earned itself on the first rebase it met: Territory A's `Constructing`
process state had arrived while this was being written, and the check named
it rather than letting the view print a number.

**#530 closed 2026-09-10.** It was #517's shape one layer up: the two lane
runners held the view-comparison loop twice, and the copies had already
diverged. `scripts/kernel_views.sh` holds it once, and both runners source it.

The divergence was not cosmetic, which is the part worth carrying. QEMU's
normalization rewrote the dmesg timestamp prefix and the board's did not, so
`kernel/tests/qemu/views/dmesg` was QEMU-only because of how its runner
happened to preprocess text -- and the board asserted nothing at all about
the retained-log replay. With one normalization the view is common, and the
declaration that named this issue as what would retire it is gone. The shared
view asserts more than the QEMU-only one did: five records spanning t=0 to
about twenty seconds, so the ring is shown to have kept late records and not
only its first two. The board compares 45 views now rather than 44.

A second drift was found while extracting it. Both copies ran `sed` over the
raw capture and deleted carriage returns afterwards, so a `$`-anchored rule
only fired on lines the capture happened not to CR-terminate. The pid rule is
one, it works today by luck of which lines carry a CR, and nothing would have
noticed that changing. The CR is deleted first now, and the control writes
that line CR-terminated on purpose.

The loop was previously exercised only by a full boot. `check_kernel_views_controls.sh`
now asserts it directly in milliseconds: report every mismatch rather than
stopping at the first, purge a stale `.actual`, refuse a run that compared
nothing, refuse a filter with no expected file, and let platform and overlay
lookup win in that order.

Two dead `COMMON_VIEW_DIR` assignments went with it, in the lifecycle-gap and
alloc-rollback runners -- assigned, never read, and a reader would reasonably
have concluded those lanes compared views.

### Not started by either

**M3's userspace capabilities** -- #433, #434, #435, #436, #204, #220 --
concentrate in `kernel/kernel/syscall.tkb`, Territory A's second-largest file,
and sit at priority 4. Parallelising them would congest the milestone for
work that is not blocking it. The same applies to the other-architecture and
long-horizon items (#50, #51, #85, #95), the DWARF trio waiting on external
triggers (#122, #123, #124), and #250, which records that it blocks nothing.

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

### Group B, as of 2026-09-01

Two of the four "these ARE the change" sites are done, and the worklist is
FIFTEEN sites now rather than ten -- the coverage check added entries that
had been silent, which is the check working rather than a regression.

`process.tkb`'s scheduler lock is in. The defect it closed is worth stating
because it was not the expected one: `ProcessSlotState` already distinguished
Ready from Running, so two cores could never pick the same process off the
chain -- but `scheduled_process_ready_take` read the state and only THEN minted
the linear tokens standing for the claim, so two cores in that window both came
out holding one, with the linear types satisfied on each core separately. An
ownership discipline sound per-core and blind across cores. Measured at 3163
double claims per 8192 on QEMU, 3114 on RPi5, and zero with the lock.

The crash trace ring is per-CPU with one global sequence. It is not a lock, and
`kernel/CONCURRENCY.md` states why reporters never are.

What remains of `process.tkb` is one thing: the bootstrap record and its two
flags, which is really #415 -- the bootstrap process is distinguished by a
value, not a type. Then `address_space.tkb`'s ready flag and missing-record
fallback, and `syscall.tkb`'s re-entrancy.

### The liveness-proof thread, opened 2026-09-01

Not a milestone, but a new session should know it exists before touching the
process table or any pool.

**#488**: the kernel reaps the record `execution_here()` calls current, 26
times per boot, on every boot, and then keeps using it -- the trace arguments
read it and the successor search walks the process chain FROM it. It is
deterministic, not a flake; the intermittent symptom that led to it was a rare
failure of CONCEALMENT, because the freed slot is almost always recycled before
the read. `kernel_syscall_wait4_deliver` reaps the exiting child while it is
still current, and fixing it means reordering the exit path, which needs
hardware. A counter reports it every boot.

`IntrusivePool` no longer launders its own liveness proof: payload accessors
take the view or owner as `borrow` and return a pointer tied to it. What still
launders is named (`intrusive_pool_payload_unproven_of`), `unsafe`, and
therefore counted -- and every remaining one is an accessor that RETURNS the
pointer, so removing it means migrating that accessor's callers to hold the
proof. A count belongs in the trusted-base inventory rather than here, where
it goes stale the first time somebody converts one.

**#492** is half done. Every read that HAD a generation now compares it, and
the count is zero -- so #488's stale reads come through paths that take a bare
slot and never had one. **#493** (effect-indexed invalidation, a `!{reaps}`
with teeth) is the static rule aimed at exactly those. **#504** observes that
#456's stop-the-world, #452's remaining page-allocator lock and the two-core
probes all want one mechanism, and that `kernel/lib/occupancy.tkb`'s linear
`Quiesced` is already its shape.

Read `kernel/CONCURRENCY.md` before adding a lock, a probe, or a pooled read.

### Where to start

The threads above are not equally urgent, and one of them is the only DEFECT
among them.

1. **#488 -- DONE 2026-09-04, closed.** Its exit-path reorder was the
   first item here and is no longer pending; the queue in "Work split
   between two agents" above starts from what remains. The reasoning
   is kept because the rest of this section refers to it:
   Everything else here is a design step;
   this is a use-after-free the kernel performs 26 times per boot today. It is
   also the one item that gets WORSE rather than merely staying broken when a
   second core runs a process, because the window between the reap and the
   walk becomes another core's. Fixing a use-after-free before making it
   concurrent is the obvious order. Two candidate reorderings are on the issue;
   it needs hardware, and DDB's `bt` can now name the remaining stale readers,
   which is how the last round had to be done with hand-written instrumentation
   instead.
2. **Then the rest of #479 Group B** -- the bootstrap record (really #415),
   `address_space.tkb`'s ready flag and fallback, and `syscall.tkb`'s
   re-entrancy -- because that is the milestone, and the method is unchanged:
   correct for two cores with the flag still at 1, exercised FROM core 1.
3. **#492's remaining slot-only reads, #493 and #504 after that.** They are
   design work whose value depends on numbers the first two produce. #493 in
   particular must not be built before the measurement exists: an effect with
   no teeth and nothing to evaluate it against is what #449 already was.

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
  (`buildcheck_kernel_asm_invariants.py`) in both directions rather than
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
- **#505** -- revalidate DDB backtraces once #479 lets processes run on two
  cores. Stop and capture each selected CPU before reading its unwind root,
  reject stale `Running` process snapshots, and verify cross-CPU unwind and
  resume on QEMU and RPi5. This belongs here rather than in #495: the
  single-scheduling-CPU frame contract is complete, while the invalidating
  condition does not exist until Phase 3.

### The supporting track: the in-kernel debugger

A NetBSD-`ddb`-style kernel debugger is being built in parallel and is not
scheduled by this milestone, but it is the reason Phase 3 is approachable at
all. What has landed so far: an interrupt-safe UART DDB and read-only crash
console, entry from deliberate software breakpoints, interactive breaks driven
through QMP under QEMU, and the commands `ps`, `regs`, `current`, `intr`,
`sched`, `vm`, `fds`, `bt [PID]`, `trace`, `events`, `oops`, `continue`, plus
fault-contained read-only kernel, user and physical RAM inspection. `bt` consumes the checked compiler-owned frame chain from **#495 -- DONE
2026-09-02**. QEMU verifies a multi-frame compiler chain through the deliberate
software-break assembly bridge; RPi5 verifies the live CPU root, user boundary,
guarded fault, and resume path. A focused RPi5 kernel-mode chain walk is not
currently claimed. Cross-CPU stop and root capture after processes begin
running on core 1 are deliberately tracked by **#505**. The supported QEMU and
RPi5 DDB/GDB/crash-inspection workflow is documented in `kernel/README.md`.
Open and relevant: **#444** (controlled mutation, deferred), **#429**
(in-kernel GDB stub, deferred), **#425**/**#300** (debug metadata a debugger
needs to decode variants and enums), **#496** (read-only kernel-aware GDB
helpers), **#505** (cross-CPU backtrace capture after #479), and **#149**.

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
4. **#338** -- **closed 2026-09-09.** The descriptor walk left
   `xhci_configure()` for `kernel/drivers/usb/config_descriptor.tkb`, and
   `linux_user/usb_config/` compiles that same file rather than a copy, so
   four malformed-descriptor cases cost milliseconds instead of a board. It
   was verified by planting the original off-by-one, which fails the native
   lane on the exact-end case; the real xHCI path is still only judged by
   `make kernelcheck-rpi5`.
5. **#411** -- report how long a boot took, so a ten-second regression stops
   reading as a network bug. Cheap, and it is CI's most basic signal.
6. **#339** -- **closed 2026-09-09**, and taken exactly where this workflow
   had exposed the gap: `disk_initialize()`'s eight failure points all
   answered `DiskIoResult::Err(-1)`, so the board's log named none of the six
   repairs they stand for.

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
