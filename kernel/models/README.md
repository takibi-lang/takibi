# Kernel protocol models

TLA+ models of the kernel's shared-state protocols. A model
checks a design before the change that implements it; it is not kept in
lockstep with the implementation, and it is not proof that the Takibi code is
correct. What ties the two together is the table below and the review of a
change against it.

Run every model with:

```bash
make modelcheck
```

It fetches the pinned tools on first use (`scripts/fetch_model_tools.sh`,
Java 21 required). It is a lane of `make allcheck` and `make cicheck`.
TLC jobs run concurrently with a private JVM temporary directory per job
(`scripts/run_tlc.sh`), because the pinned resolver extracts standard
modules to fixed basenames and deletes them on JVM exit. Apalache jobs
likewise have separate output directories.

## How the models are written

Plain TLA+, not PlusCal, with Apalache type annotations (`\* @type: ...;`
comments) from the first line. TLC checks every model over its whole state
space, safety and liveness. Apalache type-checks it and runs a shallow check,
so a model can move to Apalache, whose symbolic search scales past what TLC
can enumerate, without a rewrite.

Each action is one indivisible protocol step. In the process models that is
one critical section under the process-run lock; in the DMA model it is one
guarded slot exchange, submission, completion observation, or confirmed
reset. A window between actions is a place where another participant can
act. That is the whole point of writing the model: #550's defect is such a
window.

Every model has two variants, fixed and unfixed, selected by a constant. The
unfixed one must violate its property, or the model has stopped modelling the
defect it was written for, and `make modelcheck` fails.

A passing variant must also have used all of itself. Every TLC run reports
per-action coverage (`-coverage`), and `scripts/model_coverage.py` fails
`make modelcheck` when a run that explored the whole state space never took
an action of its next-state relation: an invariant that holds because the
step that could break it never runs proves nothing (GitHub issue #802; #778
found every emitted protocol model holding `held = {}`). An action dead by
design in one variant -- a step only a faulty design takes -- is listed in
`coverage_allow.txt` with its reason; a stale entry is an error too. Do not
allow-list a path the model claims to check: make it reachable, as
StackOwnership's `other` variant does for `CloneReschedule`.

## Where one model ends and the next begins

A model is one **protocol**: a piece of shared state together with the
actions that touch it under one discipline -- one lock, one ownership rule.
Not one issue: an issue usually adds a slice or a variant pair to the model
of the protocol it changes, and opens a new model only when the state it
touches belongs to no existing one.

- **Candidates, from the kernel as it stands:** wait and wake per wait reason
  (the decide-then-sleep window); stack ownership and movement (Migrate, idle
  entry and leave); ext2 mutation against counted readers; connection close
  against the reference count; a signal taken and restored across a call
  restart.
- **Size.** TLC must still cover the whole state space in seconds to
  minutes. Leave out what the property does not depend on, and say in the
  action table's "dropped" column why leaving it out is safe (below).
- **Two protocols in one model** only when a defect actually crosses the
  boundary between them. Model that interaction; do not merge the two whole.
- **Every model carries a variant pair** for the defect or design decision
  that motivated it: the fixed variant holds, and the unfixed one violates
  the property for the stated reason. `make modelcheck` enforces both.
- **Where to look for the next property:** commits whose `Protocol:` trailer
  says `yes -- <property>`, indexed by the `protocol` issue label. Each one
  names a property phrased so it can be checked.

## Wait4Block.tla -- the wait4 ChildExit window (#550)

Two cores; a parent, its child, and one other runnable process. Since #726
the parent can also be sent a signal it catches; `SIGRECHECK` is the
publication's re-check of a pending one, as `RECHECK` is of the zombie.
Since #628 a handler also runs at the return to EL0 from a timer interrupt
(`IRQDELIVER`), except at the wait4 SVC a wake rewound it to (`IRQSKIPSVC`).

| Action | Kernel function it abstracts | What is kept | What is dropped, and why that is safe | Reviewed |
| --- | --- | --- | --- | --- |
| `Wait4Decide` | the wait4 arm of `kernel_syscall_dispatch_action` | the zombie check and the decision to block, under one hold of the run lock (#571) | the pid, the status copy and ECHILD -- irrelevant to `NoLostWakeup`: none of them changes which process is Blocked or Exited | `2f8d2d3a6254` |
| `Wait4Block` | `kernel_process_block_current`, `kernel_process_block_reserved` | successor choice and the Blocked publication in one critical section; `RECHECK` is the zombie re-check there | ASID preparation and the lock drop around it -- irrelevant to `NoLostWakeup`: the drop comes after Blocked is published and re-checked, and the successor it crosses with is already reserved Running | `6465d59adaf3` |
| `ChildExit` | `kernel_process_child_exit` | the child becomes a zombie and wakes the parent only if the parent is Blocked in ChildExit | zombie draining -- irrelevant to `NoLostWakeup`: it reaps the exiting child's own children, never this parent or this child; SIGCHLD -- irrelevant to `NoLostWakeup`: it makes no process Blocked or Exited, and only such a step can break the property; the direct parent start -- modelled elsewhere: `StackOwnership.ChildExitStart` | `e50f8f38411e` |
| `Wait4Resume` | `kernel_syscall_wait4_deliver` | the woken parent reaps | the user-memory status write -- irrelevant to `NoLostWakeup`: it runs after the reap, when the child is no longer Exited | `c69dd34f5376` |
| `SendSignal` | `kernel_process_signal_deliver_to` | a caught, unmasked signal becomes pending, and a parent Blocked in wait4 is woken in the same critical section to rerun the call | which signal, the sender, siginfo and SA_RESTART -- irrelevant to `NoSleepWithSignal`: only whether a caught signal is pending, and whether the parent is Blocked, decide it; terminating signals -- modelled elsewhere: `TickWake.SignalWake` | `d563de58316c` |
| `TickDeliver` | `kernel_signal_return_deliver`, `signal_resumes_at_svc` | a return to EL0 takes a pending caught signal and enters its handler, unless the parent resumes at its wait4 SVC | a frame that cannot be written and a pending terminating signal, which end the process there instead (#949) -- modelled elsewhere: `StackOwnership.ChildExit`; returns through `el0_context_resume` from a syscall -- irrelevant to `SignalWakeEndsWait`: they resume after the SVC, at "done", or at it, where the rule is the same | `65fbd4cd3672` |
| `Preempt` | `kernel_process_timer_schedule` | the timer takes a process off its core, never inside the parent's wait4 syscall (`KERNEL_PREEMPTIBLE` is 0) | the test-only spread rendezvous -- irrelevant to `NoLostWakeup`: it changes affinity before scheduling and observes an existing leave, without changing a wait or wake | `5ca8ea2be2e4` |
| `Dispatch` | `kernel_process_secondary_start`, `kernel_process_schedule` | an idle core takes a Ready process | affinity -- irrelevant to `NoLostWakeup`: it only forbids some dispatches, and the model already allows each one it forbids; the debugger-armed starvation injection of the busy-pair control -- irrelevant to `NoLostWakeup`: like affinity it only forbids some dispatches; the boot gate that lets only the boot core take the first process after main() hands off (#831) -- irrelevant to `NoLostWakeup`: like affinity it only forbids some dispatches; stack ownership -- modelled elsewhere: `StackOwnership.Reserve` | `c642b5f6d1fb` |

Properties:

- `NoLostWakeup` (safety): the parent is never Blocked while its child is a
  zombie. The unfixed variant violates it in four steps: decide, child exits,
  block.
- `NoSleepWithSignal` (safety, #726): the parent is never asleep in wait4
  while a signal it catches is pending. The `sigunfixed` variant violates it
  in four steps: decide, signal sent, block. `Wait4Decide` stands for the
  decision and its Block return (`syscall_block_interrupt`), which answers
  EINTR; the gap between those two is the one `Wait4Block` re-checks.
- `SignalWakeEndsWait` (safety, #628): a wait4 a signal woke is never asleep
  again. The `svcunfixed` variant, which takes the signal at the rewound SVC,
  violates it: the handler runs and the rerun sleeps.
- `Wait4Finishes` (liveness, TLC only): wait4 eventually completes, under the
  fairness the kernel's scheduler rotation provides.
- `SignalRuns` (liveness, TLC only, #628): a pending caught signal is
  eventually handled, by a parent that makes no syscall too. The
  `irqunfixed` variant, with no delivery at the interrupt return, loses it.
- `TypeOK`, `RunningMatchesCores`: bookkeeping sanity.

## StackOwnership.tla -- kernel stacks across switch, exit and idle

Two cores; a parent and the child it clones. A core's logical current
process and the stack it physically stands on are separate variables, as
they are in the kernel, and `owner` records each process stack's physical
owner. The cores, the processes and who is whose child (`ParentOf`) are
constants, and no action names a process: the model's own runs set them to
two cores and "parent" and "child", and the trace check below sets them to
the cores and processes of a real run (#606, stage 2).

Each action is one hold of the process-run lock where the kernel really
takes one, which GitHub issue #606's trace of real runs is what showed.
An interrupt from EL0 releases the interrupted process's stack on entry
and takes it back on return (`interrupted` remembers which cores are inside
one). Three kernel sequences are two holds: a switch reserves its successor
(Ready to Running, `reserved`) and commits it as current after preparing
the address space unlocked; a clone makes the still-Constructing child
current and finishes it later; a process leaving its core stops being
current first and is made Ready on the idle stack afterwards.

Three constants re-introduce three past defects: the two #601 asked the
model to find, and one #609 introduced. Each is one variant, and `make
modelcheck` requires each to fail:

- `EXIT_IDLES = FALSE` is 08df64c6's deadlock. After an exit, core 0
  waited for a successor while it still stood on the zombie's stack. The
  only successor was the parent, which could not start while that stack
  was owned. TLC reports `Deadlock reached`. Apalache reports a deadlock
  only when every run of some length is stuck, so this variant is TLC's to
  find, and Apalache only shows that it runs.
- `LEAVE_CHECKS_STACK = FALSE` is 765a27af's lost child. A process leaving
  its core hands back whatever stack the core stands on. A clone child's
  first return stands on its parent's, so the parent was made Ready and the
  child was lost. TLC and Apalache both report `RunningMatchesCores`, in
  three steps: clone begin, clone finish, the child's leave.
- `WAKE_START_CHECKS_STACK = FALSE` is #609's shared stack. Once wait4 ran
  on a peer, a parent could block there, publishing Blocked while that peer
  still stood on its stack. The child's exit on core 0 woke the parent and
  started it at once, on the same stack. TLC and Apalache both report
  `StartsOnFreeStack`, in eight steps: clone begin and finish, switch, the
  parent reserved and committed on the other core, switch, block, exit.

A fourth constant is the design #992 (#638 stage 3) adds before any EL1
switch exists: `PREEMPT_EL1_KEEPS_STACK = FALSE` releases a preempted
process's stack at the EL1 entry, as the lower-EL entry releases it
(`InterruptDepart`). The tick at EL1 interrupted code on that very stack,
so another core can then take the process and its stack while this core
still runs on it. TLC reports `StackSafety`; Apalache's shallow run, given
`CoreInvariants` only, shows that it runs.

A fourth configuration widens the model rather than breaking it. Variant
`other` adds a third process to `Procs`, Ready from the start. With only the parent and the child no process is ever free to be
reserved while the child first runs on its parent's stack, so
`CloneReschedule` was never enabled and the safety invariants held over it
vacuously; `make modelcheck`'s coverage check found that (#802). The
variant checks `ChildReaped` too (#803), which needed the model to say what
the kernel's scheduler already gives: no process is starved (per-process
strong fairness on `Reserve`), a running process asks for a successor only
once it runs on its own stack or inside an interrupt taken from it (or at
a clone child's first return), and an interrupt that switched returns to
the successor rather than staying inside the outgoing process's interrupt.
Without them TLC found a third process taking every turn, and a child
preempted on each turn before it ever reached EL0 -- behaviours of the
model, not of the kernel.

| Action | Kernel function it abstracts | What is kept | What is dropped, and why that is safe | Reviewed |
| --- | --- | --- | --- | --- |
| `CloneBegin` | `kernel_process_clone_begin` | the child becomes the core's current process while still Constructing; the core stands on the parent's stack | fork's fd, VM and inherited session copies -- irrelevant to `StackSafety`: they touch no kernel stack and no core's current process | `8ec635c76a71` |
| `CloneFinish` | `kernel_process_clone_context_install` | the child is Running and the parent Ready, in a later hold | nothing | `37a91956037b` |
| `SwitchComplete` | `kernel_process_stack_switch_complete` | the physical handoff at exception return: release the stack stood on, own the current process's | the deferred reap it runs after the release -- modelled elsewhere: `Wait4Reap`; the signal handler it enters last, for an El0 frame only (#992: an El1 frame skips it, the signal waits for the next EL0 return) -- modelled elsewhere: `Wait4Block.TickDeliver` | `fd1319f47f22` |
| `Reserve` | `kernel_process_schedule`, `kernel_process_secondary_start`, `kernel_process_block_current` | a core takes a Ready process whose stack no core owns, and a parent with a continuation only once the child's stack is free too, and marks it Running before it is current | affinity -- irrelevant to `StartsOnFreeStack`: it only forbids some reservations, and the model already allows each one it forbids; the debugger-armed starvation injection of the busy-pair control -- irrelevant to `StartsOnFreeStack`: like affinity it only forbids some reservations; the boot gate before the first start after main() hands off (#831) -- irrelevant to `StartsOnFreeStack`: like affinity it only forbids some reservations; the unlocked ASID preparation before the commit -- irrelevant to `StackSafety`: it moves no stack, and the reserved process is Running, so no other core can take it | `60cdc9b29264` |
| `Commit` | `kernel_process_secondary_start_reserved`, `kernel_process_exit_reserved` | the reserved successor becomes current on a core with no running current process | Ready wait4 marker consumption -- irrelevant to `StackSafety`: it changes no physical owner, and the reservation already checked the child stack before clearing the marker | `44a17f1b45c4` |
| `SwitchAway` | `kernel_process_schedule_reserved`, `kernel_process_block_reserved` | the reserved successor replaces a running current process, which is preempted, naps, or blocks in wait4; the core still stands on the outgoing stack, or on its IRQ stack inside an interrupt from EL0 | which child a wait4 waits for, and whether it has exited -- modelled elsewhere: `Wait4Block.Wait4Block` | `52e8e5166b4e` |
| `CloneReschedule` | `kernel_syscall_clone_child_return`, `kernel_syscall_resume_return`, `kernel_process_syscall_return_schedule`, `kernel_process_schedule_reserved` | a deferred request can save the installed child frame and make the unstarted child Ready before the physical clone handoff; the reserved successor replaces it while this core still owns the Ready parent's stack | why the request is pending -- irrelevant to `StackSafety`: it changes no physical ownership, and the successor was reserved before replacement | `01e50f1cb550` |
| `Wait4Block` | the wait4 arm of `kernel_syscall_dispatch_action`, `kernel_process_block_to_idle` | a parent blocks before its child exits, with no successor | the #550 window -- modelled elsewhere: `Wait4Block.Wait4Decide` | `fb7e01f06290` |
| `Nap` | `kernel_process_block_to_idle` | a process blocks for anything but a child's exit, with no successor | what it waits for -- irrelevant to `StackSafety`: every other wait reason blocks and wakes the same way | `0d68e6e1cc82` |
| `Wake` | `kernel_process_tick_wake_scan` | a napping process becomes Ready wherever its stack is | the other wakers (UART, network, signal) -- irrelevant to `StackSafety`: each makes a Blocked process Ready and moves no stack | `7ea08785f26e` |
| `ChildExit` | `kernel_process_child_exit`, `kernel_syscall_exit_current_process`, `signal_return_exit` | the child becomes a zombie and wakes a Blocked parent, leaving it Ready with its continuation; the core still stands on the zombie's stack. The exit runs from a syscall or, since #949, from the return-to-EL0 hook after `SwitchComplete` has settled the core on the process's stack: the same `Settled` state the action requires | zombie draining -- guarded: `scheduled_process_exited_take` fail-stops with `reap-on-owned-stack`; SIGCHLD -- irrelevant to `StackSafety`: it moves no stack and no core's current process; the init-child exit log line (#887) -- irrelevant to `StackSafety`: it only reads the record under the run lock and writes the log | `a03b6fda546b` |
| `ChildExitStart` | `kernel_process_child_exit` | the same exit reserving the woken parent for this core at once, only when no core owns the parent's stack; `Commit` makes it current | affinity -- irrelevant to `StartsOnFreeStack`: it only forbids some starts, and the model already allows each one it forbids | `e50f8f38411e` |
| `IdleEnter` | `kernel_process_stack_idle_complete`, `kernel_process_stack_idle_blocked` | a core with no current process moves to its idle stack and releases the one it stood on | nothing | `3151a0ca2353` |
| `Wait4Reap` | `kernel_syscall_wait4_deliver` | the parent reaps once the child's stack is free | which process reaps (a deferred reap, an exiting parent's drain) -- guarded: `scheduled_process_exited_take` fail-stops with `reap-on-owned-stack` | `e5296b3f3dac` |
| `LeaveBegin` | `kernel_process_core0_leave_excluded`, `kernel_process_migrate_current` | a running process stops being its core's current process and stays Running | why it leaves (affinity, a refused syscall, the tick) -- irrelevant to `StackSafety`: the model lets a running process leave at any step, which covers every reason | `4f045bdabc54` |
| `LeaveComplete` | `kernel_process_stack_idle_yield` | on the idle stack, the process the core stood on is made Ready and its stack released | nothing | `d9dad47d4287` |
| `InterruptDepart` | `kernel_process_stack_interrupt_depart` | an interrupt from EL0 moves the core to its IRQ stack and releases the interrupted process's stack; the process stays current and Running, and `SwitchComplete` takes it back at the return | which interrupt it was -- irrelevant to `StackSafety`: every lower-EL IRQ enters through the same hook | `cee90a827978` |
| `TickLeave` | `kernel_process_tick_leave_excluded` | inside that interrupt, a process that may no longer run here is made Ready, its stack already free, and the core idles | why it may not run here (its mask), including the spread test hook, and the hook's observation after Ready publication -- irrelevant to `StackSafety`: the model lets it leave at any interrupt, and the observation changes neither stack ownership nor process state | `3a5a8f934acc` |
| `PreemptEL1` | `kernel_tick`, `kernel_process_stack_switch_complete` | a tick taken at EL1 inside a syscall leaves the process Ready while this core still owns and stands on its stack, which still holds live kernel frames; the release is `SwitchComplete`'s, at the return into the successor, and the core that takes the process takes the stack (GitHub issue #992) | that no EL1 switch is produced yet -- irrelevant to `StackSafety`: until #638 stage 8 `kernel_tick`'s El1 branch only requests a reschedule, taken at the syscall return as `SwitchAway`, so the kernel's behaviours are a subset of the model's; the El1 frame's registers -- irrelevant to `StackSafety`: the frame type (`FrameRef[process, ExceptionLevel::El1]`) keeps deliveries out of it, and no register moves a stack | `196153a1edd8` |

Properties:

- `StackSafety` (#601's safety property, TLC): a core stands only on a stack
  it owns, and since `owner` names one core per stack, no stack is used by
  two cores at once.
- `RunningMatchesCores`: a Running process is held by some core -- current,
  reserved, or stood on while it leaves or finishes a clone -- and no
  process is current or reserved on two cores. The lost child violates it.
- `StartsOnFreeStack`: a core's current process, and its reserved
  successor, have a stack no other core owns. The direct start of #609
  violates it. Apalache's shallow check is given `CoreInvariants`, this and
  `RunningMatchesCores` together.
  In the kernel it is a type before it is a check: `scheduled_process_start`
  takes a `Startable` token and `scheduled_process_reap_remove` a `Reapable` one,
  made only by `scheduled_process_ready_take`, `scheduled_process_start_check`,
  `scheduled_process_restart_check` and `scheduled_process_exited_take`, each
  after reading the stack owner under the run lock. A path that starts or
  reaps without asking does not compile, and
  `scripts/check_stack_proof_states.py` fails if that set is widened. That
  the read is right stays trusted: the run-time checks in start and
  exited_take, and the trace check below, watch it.
- `ChildReaped` (liveness, TLC only): the parent's wait4 completes.
- Deadlock freedom: TLC's own check, which the exit variant fails.

### Checked against real runs: StackOwnershipTrace.tla

`/bin/protocol-trace` opens a window in which the kernel diffs this
model's state -- each process's state and stack owner, each core's current
process and the stack it stands on -- at every release of the run lock
(`kernel/kernel/protocol_trace.tkb`), and prints the changes when the window
closes. On every QEMU and RPi5 kernel lane,
`scripts/validate_protocol_trace.py` parses the window into a TLA+ module,
one record per hold, and TLC checks `StackOwnershipTrace.tla` against it:
is there a behaviour of this spec, with this run's cores, processes and
parent links substituted for the constants, that produces exactly that
sequence of holds? Since #606's stage 2 no enabling condition, effect or
invariant is written outside the `.tla`, so the check cannot drift from the
model, as stage 1's Python replay could.

- Observed: `state`, `owner`, `current`, `stands`. Each locked hold that
  changes them is one action of `Next`; a hold that changes nothing
  observed is a stutter; an unlocked hold may change nothing at all.
- Not observed, and chosen by TLC among the values the model allows:
  `reserved`, `interrupted`, `reapPending`. A refusal prints the state some
  behaviour reached before the refused hold, these included.
- Invariants after every hold: `StackSafety`, `RunningMatchesCores`,
  `StartsOnFreeStack`, `NoLostWakeup`, and `WaitMatchesState` (#653: a
  Running process holds no published wait except the wait4 continuation of
  a reserved process), which is the trace spec's own, not the model's.
- Not checked by TLC, because it is about the report rather than the
  protocol: a lost change, a cut report, a malformed line, a missing
  window. And one policy, also the script's: an action the probe is written
  to exercise that the matched behaviour never took fails the lane, so a
  PASS cannot be vacuous about it.
- Conventions of the parse, each stated in the script: a pid first seen
  mid-window as a fresh Constructing record (allocation is ordered by the
  pool lock, not the run lock) is Constructing from the start, as the
  model's child is; any other pid not in the opening snapshot is `Absent`,
  a state no action takes; a removed record is `Reaped`. `ParentOf` is a
  constant, so a window in which a parent link changes (a reparented
  orphan) is refused before TLC runs; the link the kernel clears while it
  removes a record is the same link.

What a PASS claims is narrow: every transition the kernel made in that
window is one the model has. It says nothing about paths the window did not
run, and nothing about whether the model is right. What it catches is a
path the model lacks that runs routinely: #609's direct start ran on every
ordinary wait4 wake, and the recorded window checked without
`ChildExitStart` fails on the first one. The controls
(`scripts/protocol_trace_tlc_controls.py`, part of `make modelcheck`) also
plant #609's start on an owned stack and 765a27af's leave on the parent's
stack: the fixed model refuses each at its hold, and the model with the
variant's guard dropped takes it and breaks `StartsOnFreeStack` or
`RunningMatchesCores` -- the refusal is the guard's.

Wait4Block.tla is checked through the same run, not instantiated: its
`RECHECK` is an enabling condition of this model's `Wait4Block` and
`SwitchAway` (`WaitsForChild`: no child of the blocking parent has exited),
"an exit wakes exactly its parent" is how `ChildExit` uses `ParentOf`, and
its `NoLostWakeup` is an invariant of this model over every parent. Its own
coarser actions (`Wait4Decide`, `Dispatch`, `Preempt`) have no hold of
their own to match. The controls plant #550's two shapes, a block with a
zombie child and an exit that wakes nobody, and a wake of the wrong
process. Narrower than this model's tie: the "decided" window between
wait4's two critical sections is not a state the trace can see, so what is
checked is that the publication closing it re-checks, not that the window
is closed. Blocking needs the child's nap to have started before the parent
reaches wait4, which a stalled vCPU can spoil, so a window may never block
a parent and then says nothing about this model. One awaited child at a
time is assumed, as `/bin/protocol-trace` runs: a parent that waits for one
pid while another child is already a zombie would be refused although the
kernel is right.

## TickWake.tla -- per-CPU deadline and NetRx wake lists (#829)

Two cores, two processes. A process blocked on a deadline or a NetRx retry
is queued on the list of the core it blocked on, and that core's tick wakes
it. `PERCPU = FALSE` is the kernel before #829, where core 0's tick was the
only walker: with core 0 masked for good, TLC finds a sleeper on core 1
never woken (`core0only` loses `PeerSleeperWakes`). `UNLINK = FALSE` is a
signal wake that leaves the record on its list (`nounlink` breaks
`ListsMatchBlocked`).

| Action | Kernel function it abstracts | What is kept | What is dropped, and why that is safe | Reviewed |
| --- | --- | --- | --- | --- |
| `Block` | `scheduled_process_block`, `kernel_process_tick_wake_enqueue` | Blocked is published and the record queued on this core's list in one critical section | the successor choice and the switch -- modelled elsewhere: `Wait4Block.Wait4Block`; waits a tick does not end -- irrelevant to `ListsMatchBlocked`: they are never queued, and the model's processes stand for the queued ones | `bc2af7fccda8` |
| `Expire` | `kernel_process_tick_wake_due_of` | a queued wait becomes due (a NetRx retry is due at once) | the deadline's value -- irrelevant to `PeerSleeperWakes`: only whether it has passed decides a wake | `0f494c97d76e` |
| `Tick` | `timer_irq_handler`, `kernel_process_tick_wake_if_due`, `kernel_process_tick_wake_scan` | a core's tick, core 0's included through the same entry since #932, wakes every due record on its own list, and no other list | the unlocked due-word skip -- irrelevant to `PeerSleeperWakes`: the word is never above the earliest due entry, so a skipped tick had nothing due; the frame result write, the per-core tick times and the watched pid's wake record (#863) -- irrelevant to `ListsMatchBlocked`: they change no state or list | `62296e34d6b9` |
| `SignalWake` | `scheduled_process_wake_ready`, `kernel_process_tick_wake_unlink`, `kernel_process_signal_deliver_to` | a wake that is not the tick makes the record Ready and, with `UNLINK`, takes it off its list | which signal and its pending bits -- irrelevant to `ListsMatchBlocked`: only the state and list change matters | `5d181242e508` |
| `Run` | `kernel_process_schedule` | a Ready process runs again on the core its mask allows | stack ownership -- modelled elsewhere: `StackOwnership.Reserve` | `6cb59178b605` |
| `SetAffinity` | `kernel_process_affinity_set` | the mask changes, and a queued sleeper stays on its list | the pin and the migration of a running process -- irrelevant to `PeerSleeperWakes`: neither touches a list | `f5f22503bf39` |
| `Mask` | `workload_peer_sleep_progress` | core 0 masks its interrupts and takes no tick | how long -- irrelevant to `PeerSleeperWakes`: the model masks for good, the worst case; the wake record it reads (#863) -- irrelevant to `PeerSleeperWakes`: watching changes no state or list | `e6c0dbaafd06` |

Properties:

- `ListsMatchBlocked`: a process is on a list exactly while it is Blocked,
  and on one list.
- `PeerSleeperWakes` (liveness, TLC only): a due sleeper that blocked on
  core 1 is woken although core 0 is masked for good, under weak fairness
  of each core's tick.

## PipeWait.tla -- a pipe's reader and writer on two CPUs (#1042)

One pipe of `CAP` = 1 byte, a writer that writes `ITEMS` = 2 one-byte writes
and then closes its end, and a reader that reads until end of file. A look
at the pipe is one critical section under the pipe's own lock; one that must
wait names the pipe in its process record and sets the pipe's waiting flag
before the lock is let go (`pipe_put_waiting`), and the syscall publishes
Blocked in a later critical section under the run lock. A change reads and
clears the flag under the pipe lock and, when it was set, walks the records
under the run lock (`pipe_put_changed`, `kernel_process_pipe_wake`). That a
change cannot skip its wake is the compiler's: a change returns a linear
`PipeChange`, and only `pipe_put_changed` discharges it.

`NAMED_UNDER_LOCK = FALSE` names the pipe after the lock is let go: a change
between the look and the name finds the flag clear, and the waiter sleeps
beside a byte (`unlocked` breaks `NoLostWakeup`). `RECHECK = FALSE` is a
Blocked publication that does not ask whether a wake already took the name:
a change between the name and the block clears it while the waiter is still
Running (`norecheck` breaks `NoLostWakeup`).

| Action | Kernel function it abstracts | What is kept | What is dropped, and why that is safe | Reviewed |
| --- | --- | --- | --- | --- |
| `ReaderLook` | `syscall_pipe_read`, `pipe_take`, `pipe_consume`, `pipe_put_waiting`, `pipe_put_changed`, `kernel_process_pipe_wait_prepare` | one look under the pipe lock: a byte taken (a change, which reads and clears the waiting flag), end of file once the write end is closed, or the pipe named and the flag set before the lock is let go | the user copy and its fault -- irrelevant to `NoLostWakeup`: a faulted read changes nothing and so owes no wake; the byte count -- irrelevant to `NoLostWakeup`: a read takes what is buffered up to its request, and the model's one-byte reads take all of it; the ppoll look of one pipe end (`syscall_pipe_poll_wait`) -- irrelevant to `NoLostWakeup`: it names the pipe through the same `pipe_put_waiting` under the same lock, and names none when it is ready, which reruns the call at once | `8e3137bb2e3b` |
| `WriterLook` | `syscall_pipe_write`, `pipe_write_amount`, `pipe_produce`, `pipe_end_close`, `pipe_end_mark`, `pipe_put_waiting`, `pipe_put_changed` | one write under the pipe lock: a byte put, or the pipe named for room; after the last byte the write end's close, which is a change too | writes of more than one byte -- irrelevant to `NoLostWakeup`: one that does not fit decides to wait exactly as the model's full pipe does, and room comes only from a consume, which wakes it; EPIPE and the read end's close -- irrelevant to `NoLostWakeup`: a writer that finds the reader gone does not wait, and the model's reader never closes | `d6c5a542ae9c` |
| `Name` | negative variant only: the name written after the pipe lock is let go | the window between the look and the name | nothing | `e3b0c44298fc` |
| `Block` | `kernel_syscall_block_return`, `kernel_process_block_pipe`, `kernel_process_block_current`, `kernel_process_block_would_miss` | the Blocked publication under the run lock; with `RECHECK`, a name a wake already took reruns the call instead | the successor choice and the switch -- modelled elsewhere: `Wait4Block.Wait4Block`; a caught signal pending at the publication -- modelled elsewhere: `Wait4Block.SendSignal` | `8a5c95d1c226` |
| `Walk` | `kernel_process_pipe_wake`, `scheduled_process_wake` | under the run lock every record naming the pipe loses the name, and one Blocked on `Pipe` becomes Ready to look again | records naming another pipe or none -- irrelevant to `NoLostWakeup`: the walk leaves them alone; Free and Constructing records -- irrelevant to `NoLostWakeup`: neither can have named a pipe | `ce5709a9abaa` |

Properties:

- `NoLostWakeup`: a sleeper beside what it waits for -- a byte or end of file
  for the reader, room for the writer -- is still named, and the other side
  is on its way to the walk that wakes it.
- `AllRead` (liveness, TLC only): every byte written is read, then end of
  file, under weak fairness of every step.

## RecordLifetime.tla -- a process record read while another CPU reaps it (#482)

One record, one reader, one reaper, and the process's own execve. The
reader is a scheduler walk, an interrupt-side wake or procfs's snapshot: it
holds the process-run lock, probes the record live, lets the pool's view
go, and reads through the pointer. The reaper tears down what the exited
process owned, then removes the record from the pool. execve rewrites the
live record's command line, which the snapshot copies (#618).

Four variants:

- `REMOVE_UNDER_LOCK = FALSE` is the kernel before #482. The removal ran
  outside the run lock, and TLC finds a read of a freed record in five
  steps: exit, probe, teardown, remove, read.
- `REMOVE_UNDER_LOCK = TRUE` is the fix, and `ReadsOnlyLiveRecords` holds.
- `READER_HOLDS_LOCK = FALSE`, with the fix in place, breaks the assumption
  the fix rests on: that a reader of another process's record holds the run
  lock from probe to read. The type system enforces the removal's half, the
  guard `scheduled_process_slot_remove` requires. It does not enforce the
  reader's half in the historical shape. Guard-derived pointers now enforce
  both halves; this counterfactual variant checks the protocol assumption.
  procfs's snapshot was such a reader until #618.
- `EXEC_WRITES_UNDER_LOCK = FALSE` is execve rewriting the command line
  outside the run lock. The rewrite is then two steps, and a locked reader
  copies between them: TLC reports `NoTornRead` in three steps.

| Action | Kernel function it abstracts | What is kept | What is dropped, and why that is safe | Reviewed |
| --- | --- | --- | --- | --- |
| `ReaderProbe`, `ReaderMiss`, `ReaderRead` | `kernel_process_secondary_start`, `kernel_process_next_ready`, `kernel_process_tick_wake_scan`, `scheduled_process_diagnostic_snapshot`, `kernel_process_session_get`, via `scheduled_process_record_locked` (including the snapshot under the same run lock) | the probe retains its pool view, transfers the record-reference loan to the existing run guard, and releases the view; the read comes later under that same guard | which reader reads and what it reads besides the command line -- irrelevant to `ReadsOnlyLiveRecords`: the property depends only on whether the record was freed before the read; the monitor's `ps` and `proc`, which read with no lock -- irrelevant to `ReadsOnlyLiveRecords`: they run with every other CPU stopped, so no reap can land during the read; the snapshot's resident page count, read since #1071 after the run unlock from process-image handle words copied under it -- irrelevant to `ReadsOnlyLiveRecords`: it reads the image pool through a generation-checked pin, never the process record, and a freed image reads as 0 | `7892bfe2c1de` |
| `ReaperTeardown` | `scheduled_process_reap_teardown` | frees what only the exited process owned; no lock | nothing | `bc1b5b838038` |
| `ReaperRemove` | `scheduled_process_reap_remove`, `scheduled_process_slot_remove` | resets and removes the record, under the run-lock guard since #482; since #745 the removal takes the record's Held permission back out of its RegionPool slot (once; a second removal finds it not Held), scrubs and frees it | releasing the placement pin (#686), and (#672) taking the stack run's permission out of the record's `stack` place under the pool lock before the record goes -- irrelevant to `RecordInvariants`: both end a token held in the live record and read or free no other record | `d1f8203feae2` |
| `Exit` | `kernel_process_child_exit` | the process becomes a zombie | the rest of exit -- irrelevant to `ReadsOnlyLiveRecords`: only the zombie state lets a reaper start, and nothing else in exit frees the record | `e50f8f38411e` |
| `ExecWrite`, `ExecWriteEnd` | `syscall_execve_current_with`, `scheduled_process_set_command_line` | the live process's command line is replaced in one critical section under the run lock; `ExecWriteEnd` is the second half only the unfixed variant takes | the argument count, inode and pending flag written in the same hold -- irrelevant to `NoTornRead`: no reader copies them | `3e695faae708` |

### Checked against real runs

StackOwnershipTrace.tla holds the reaper's half of this model (#647): a
record is removed only once it is Exited (`Wait4Reap`'s enabling
condition), and the removal is a step of its own hold of the run lock,
never made with none held (`REMOVE_UNDER_LOCK`: an unlocked hold may change
nothing). The model itself is not instantiated. The controls
plant a removal with no lock held and the removal of a live record.

Much narrower than the model. The reader's half, the probe and the read
through the pointer, changes no protocol state, so nothing is recorded and a
PASS says nothing about `READER_HOLDS_LOCK`. Nor is execve's command-line
rewrite (`EXEC_WRITES_UNDER_LOCK`) observed: the record carries no image
generation. The teardown is not observed either, since it is not a change of
process state, pool membership or core.

## LogRing.tla -- the multi-writer kernel log ring (#613)

The design of docs/LOG_RING_DESIGN.md (option B, records spanning several
slots), checked before its code and now implemented by
`kernel/printk/log.tkb` (slice 5: every CPU writes, syslog on any CPU the
reader). N slots; sequence s lives in slot s % N, and each
slot has one state word (seq, state, span). A writer reserves k slots with
one CAS on `head`, then claims each slot by a CAS from its previous
occupant -- finished (Committed or Discarded) and older, or Free -- to
(s, Reserved), the first slot carrying span k and the others the
continuation mark (span 0). A previous occupant still Reserved -- a stalled
writer -- or a newer one makes the claim Refused: the writer reports every
sequence of the record lost, discards the slots it already claimed, and
holds no token. It writes the text, then commits each slot by a release
CAS, continuations first. The one reader acquire-loads a slot word, copies,
and re-loads it, for the first slot and then the continuation; anything
else is reported lost by sequence. Overwrite is oldest-first by
construction (a claim of s replaces an older record).

Bound: writers 2 or 3, N = 2, 3 or 4 slots, records of k <= 2 slots,
sequences below 6 (`MAXSEQ`). Variant `fixed` is 3 writers on 3 slots (3.2
million states, about a minute in one TLC worker); `fixed4` is 2 writers on
4 slots and `fixed2` 2 writers on 2. The model is sequentially consistent;
the AArch64 orderings it relies on are the LogRing litmus tests
(`litmus/README.md`), tied to the emitted instructions.

Invariants: `NoTornRead` (no returned copy holds text of another record),
`NoSilentLoss` (every sequence the reader has passed was returned or
reported lost), `NoDoubleOwner` (no slot held by two writers' tokens),
`NoNeedlessRefusal` (a claim is refused only for a writer still holding
the slot or a newer record in it).

Unfixed controls, each a constant, each failing in TLC:

- `aba` (`SEQ_IN_WORD = FALSE`): the state word carries no sequence; a slot
  reused and committed again between the reader's two loads passes the
  re-check. `NoTornRead`, 13 steps.
- `trustreserved`: the reader accepts a Reserved slot and copies text not
  yet written. `NoTornRead`, 7 steps.
- `noprev` (`CHECK_PREV = FALSE`): a claim ignores the previous occupant
  and takes a slot a stalled writer still holds. `NoDoubleOwner`, 7 steps.
- `contnoseq` (`CONT_SEQ = FALSE`): the reader accepts any committed
  continuation mark; after it re-checked the first slot, the record is
  overwritten by a later two-slot record, and the reader takes that
  record's continuation as its own. `NoTornRead`, 20 steps.
- `silentrefuse` (`REPORT_REFUSAL = FALSE`): a refused writer discards its
  claimed slots without reporting, and the reader skips Discarded slots as
  already reported. `NoSilentLoss`, 10 steps.
- `exactprev` (`PREV_EXACT = TRUE`): the first design, in which a claim of
  s required exactly (s - N, finished), or Free only on the first turn. A
  refused claim leaves its slot holding an older turn, so every later turn
  of that slot is refused for ever. Found writing the code (slice 4): the
  boot probe's held reservation poisoned slot 0. `NoNeedlessRefusal`, 4
  steps: one writer reserves 0..1, another 2, and the claim of 2 finds slot
  0 Free.

### Checked against real runs: LogRingTrace.tla (#656, host side only)

`LogRingTrace.tla` INSTANCEs this model with the kernel's slot count and a
`MAXSEQ` wide enough for a window, in the shape of `StackOwnershipTrace.tla`.
A window is one stream of events per writing CPU, in program order, and one
for the reader; each event is one action of `Next` with the record, slot
index and the slot word it observed. No CPU-global order is recorded: TLC
looks for an interleaving of the streams that is a behaviour of this model
with every observed word equal to the model's. `scripts/validate_log_ring_trace.py`
only parses (wire format and opening-state conventions in its docstring),
and refuses before TLC a record wider than K = 2. The TLC controls
(`scripts/log_ring_trace_tlc_controls.py`, in `make modelcheck`) refuse a
torn read, a silent loss and a double owner, the last also with the claim's
guard removed (`CHECK_PREV = FALSE`), where the model breaks
`NoDoubleOwner`. The kernel does not record windows yet; the only input
is `kernel/tests/qemu/log_ring_trace_synthetic.window`, written by hand.
Measured on simulated windows: writer streams alone check in seconds (4
CPUs x 8 records, 12 s), but a reader stream beside them multiplies the
interleavings TLC must try (3 CPUs x 5 records with a 15-record read did
not finish in 180 s), so a recorded window needs some order between
streams, or a short read.

Found while writing it: the kernel reader skips a continuation whose first
slot is gone (`KernelLogSlotView::Continuation` -> `Skipped(1)`) without
counting it, where `ReadHead` reports it lost; the control "a stray
continuation skipped uncounted" is that shape.

| Action | Kernel function it abstracts | What is kept | What is dropped, and why that is safe | Reviewed |
| --- | --- | --- | --- | --- |
| `Reserve` | `kernel_log_reserve` | one compare-swap on the head takes k sequences, retried from the value a failed swap observed | the head's load before the swap -- irrelevant to `NoDoubleOwner`: only the swap decides, the load seeds its expected value | `088699932faa` |
| `Claim`, `Refuse` | `kernel_log_claim`, `kernel_log_previous_done`, `kernel_log_discard_slots` | the occupant's load, the compare-swap from it to (s, Reserved) when it is finished and older or Free, and on refusal the claimed slots Discarded and the record's sequences counted in `kernel_log_discarded` | the reserving core in the state word -- irrelevant to `NoTornRead`: the reader compares whole words, so a further field only narrows what matches | `038cee65a3ed` |
| `Write` | `kernel_log_write` | each slot's text words, then the first slot's tick and metadata, all before the commit | packing the staged line's bytes into words -- irrelevant to `NoTornRead`: the model's text is one value per slot and each word store lands in its own slot | `adf5c5145acb` |
| `Commit`, `CommitLost` | `kernel_log_commit`, `kernel_log_discard` | release compare-swap (s, Reserved) to (s, Committed), continuations first and the first slot last; a failed swap is counted in `kernel_log_commit_lost` | giving a whole token up (`kernel_log_discard`) -- modelled elsewhere: `Refuse` | `b43c36c486a8` |
| `ReadHead`, `HeadCopy`, `HeadCheck`, `ContCopy`, `ContCheck` | `kernel_log_snapshot_build`, `kernel_log_snapshot_record`, `kernel_log_slot_view`, `kernel_log_still`, `kernel_log_copy_slot_text` | the first slot's acquire load and classification, the text copy, its re-load; each continuation's load, copy and re-load; Discarded skipped as reported, anything else counted lost | records of more than two slots -- irrelevant to `NoTornRead`: each further continuation is the same `ContCopy`, `ContCheck` pair on its own slot; the snapshot's headers and timestamp formatting -- irrelevant to `NoTornRead`: derived from fields read between the two loads | `f74f6f0fa6c1` |
Slice 4 adds the table when the ring code lands (`Reserve`, `Claim`,
`Refuse` to the reservation function; `Write` to the token's text writes;
`Commit` to the commit; the reader's actions to the syslog and DDB
readers), and `CommitLost` stays allow-listed in `coverage_allow.txt` as an
action only `noprev` takes.

## The dropped column

#609's shared stack sat in a path StackOwnership.tla's ChildExit listed as
dropped, with no reason given. The model was right about everything it
modelled; the defect was in what it left out. So a dropped cell is either
`nothing`, or `; `-separated entries, each `<path> -- <why>`, where `<why>`
is one of three checkable forms:

- **Modelled elsewhere:** `` modelled elsewhere: `Model.Action` `` (or
  `` `Action` `` in the same model). The `.tla` must define the action.
- **Guarded:** `` guarded: `<function>` fail-stops with `<activity>` ``. The
  function must set the `KernelActivity` that `kernel_activity_name` names
  so, and it must fail-stop where the dropped path would break the model's
  property.
- **Irrelevant:** `` irrelevant to `<Property>`: <reason> ``. The section's
  `.tla` must define the property, and the reason says why the path cannot
  affect it. A dropped restriction (affinity) is the common case: the model
  already allows every step it would forbid.

`scripts/buildcheck_model_function_map.py` fails the kernel build when a function or
action named in these tables no longer exists, or when a dropped entry has
none of the three forms or names something that does not exist. A rename or
removal forces the table, and a look at the model, to be updated.

## FixedDmaOwnership.tla -- a fixed allocation across RX and TX DMA (#596, #707)

One allocation and one explicit linear authority. A guarded stable-slot
exchange gives the CPU token to a synchronous request. Submission turns it
into a DMA token. An observed completion, including a completed error, or a
confirmed reset allows recovery; an unobserved timeout does not. A failed
reset leaves Device authority in the slot and no CPU access can follow. The
unfixed variant permits recovery on timeout and reaches a CPU access while
the device may still read or write.

| Action | Kernel function it abstracts | What is kept | What is dropped, and why that is safe | Reviewed |
| --- | --- | --- | --- | --- |
| `TakeCpu`, `PutCpu`, `PutDma` | `gem_pkt_take`, `gem_pkt_park`, and the guarded exchanges in `virtio_blk_receive_take`, `virtio_blk_receive_put`, `msc_csw_take`, `msc_csw_put`, `msc_data_take`, `msc_data_put`, `xhci_control_take`, and `xhci_control_put` | one serialized slot exchange and unique token storage, including a Device token stored after failed reset | lock instructions -- irrelevant to `UniqueAuthority`: the action assumes the exchange is serialized, which the driver lock must establish; buffer bytes -- irrelevant to `UniqueAuthority`: they hold no authority | `a9879f17efc0` |
| `Submit` | `gem_send_built`, `gem_tx_start`, `net_transmit`, `net_transmit_ready`, `net_packet_kept_resend`, `virtio_blk_submit_owned`, `virtio_blk_submit_header`, `virtio_blk_submit_write_data`, `msc_cbw_send_once`, `msc_data_send_once`, `usb_bulk_out`, `msc_csw_receive_once`, `msc_data_receive_once`, `xhci_receive_configuration`, `usb_bulk_xfer`, `usb_bulk_in`, `usb_ctrl_in` | preparation and submission transfer authority to the device | descriptor layout and cache instructions -- irrelevant to `UniqueAuthority`: neither can create another token; the device span -- irrelevant to `UniqueAuthority`: it only bounds which bytes the device may write | `1e1940b9d196` |
| `ObserveCompletion` | `gem_tx_wait`, `gem_tx_slot_done`, `gem_tx_finish`, `virtio_blk_receive_settle_used`, `virtio_blk_used_pending`, `msc_cbw_send_once`, `msc_data_send_once`, `msc_csw_receive_once`, `msc_data_receive_once`, `xhci_receive_configuration`, `usb_bulk_xfer` | an observed final completion, including a completed error, ends writes to the request buffer | completion code values -- irrelevant to `NoCpuAccessWhileDeviceMayWrite`: every final completion ends device writes to this request buffer | `62c5077cc50f` |
| `Timeout` | `gem_tx_wait`, `gem_tx_finish`, `gem_tx_unconfirmed`, `virtio_blk_submit_owned`, `virtio_blk_receive_settle_used`, `msc_csw_receive_once`, `msc_data_receive_once`, `xhci_receive_configuration`, `usb_bulk_xfer` | a missing completion leaves device activity possible | timer arithmetic -- irrelevant to `NoCpuAccessWhileDeviceMayWrite`: elapsed time alone does not end device writes | `77d1fe84c782` |
| `ConfirmReset` | `gem_halt`, `gem_tx_unconfirmed`, `virtio_blk_receive_settle_reset`, `virtio_blk_reset`, `msc_abort_unobserved_transfer`, `xhci_halt_and_reset` | confirmed reset ends device writes | register polling details -- irrelevant to `NoCpuAccessWhileDeviceMayWrite`: this action is enabled only after quiescence is confirmed | `d2d888524962` |
| `ResetFailed` | `gem_halt`, `gem_tx_unconfirmed`, `virtio_blk_receive_settle_reset`, `virtio_blk_reset`, `msc_abort_unobserved_transfer`, `xhci_halt_and_reset` | failure preserves possible device writes and forbids recovery | controller-specific failure codes -- irrelevant to `NoCpuAccessWhileDeviceMayWrite`: every failed reset leaves authority with the device | `d2d888524962` |
| `Disabled` | `gem_tx_claim`, `net_rx_send_reply`, `net_transmit_ready`, `virtio_blk_submit`, `disk_status` | later requests are refused while Device authority remains stored; GEM also refuses after a confirmed halt, with CPU authority stored | error reporting -- irrelevant to `NoCpuAccessWhileDeviceMayWrite`: it does not touch the allocation | `a550d8ecda42` |
| `Finish` | `gem_tx_finish`, `gem_tx_unconfirmed`, `virtio_blk_receive_settle_used`, `virtio_blk_receive_settle_reset`, `virtio_blk_request_settle`, `virtio_blk_data_settle`, `msc_cbw_send_once`, `msc_data_send_once`, `msc_csw_receive_once`, `msc_data_receive_once`, `xhci_receive_configuration` (the compiler accepts the RX and TX finish builtins only in the record's declaring file, issues 716 and 717; a TX finish has no cache work) | RX/TX finish returns CPU authority after completion or confirmed reset/halt; the unfixed variant also permits timeout | cache instructions -- irrelevant to `UniqueAuthority`: they do not create a token | `13c19ff078b1` |
| `CpuAccess` | `gem_send_built`, `virtio_blk_submit_owned`, `virtio_blk_submit_header`, `virtio_blk_submit_write_data`, `msc_cbw_header`, `msc_cbw_set`, `disk_write_sectors`, `msc_csw_receive_attempt`, `disk_read_sectors`, `usb_disk_initialize_stages`, `xhci_configure` | one CPU read or write through the protected allocation, permitted only with CPU authority | alias syntax and provenance -- irrelevant to `UniqueAuthority`: they cannot create another token, while their access safety requires the separate compiler checks | `019a9b7d745b` |

`UniqueAuthority` checks that the only token is either in the slot or held by
the request, including a retained Device token after reset failure.
`NoCpuAccessWhileDeviceMayWrite` retains its original name but covers device
reads as well as writes. `NoPrematureCpuAuthority` excludes CPU authority
while device access remains possible. These are bounded model evidence.

The GEM policy variant sets `txDown` on absent completion before halt.
Confirmed halt allows a CPU token to be put back, failed halt retains Device,
and neither permits another buffer write or submission (`NoReuseAfterHalt`).
Three negative variants recover on timeout, recover on failed halt, or ignore
the down flag. Both descriptors share the same allocation and token; their
identities and ring alternation are irrelevant to `UniqueAuthority`: neither
provides independent buffer authority. A failed claim may take and replace the
CPU token under two guard holds, but permits no `CpuAccess` or `Submit`.
The finish-to-put step is separate from a new claim, as in the driver.
`ObserveCompletion` cannot replace GEM's halt outcome after its wait expired.
The caller serializes network capability access as described in
`kernel/CONCURRENCY.md`; interrupt observations do not mint another token.
This model does not prove the compiler's direct/alias access rule, cache
maintenance, or the hardware reset contract; those require separate evidence.
Cache visibility of a receive handoff is DmaCacheVisibility.tla's (#625).

## ConsoleTx.tla -- terminal output from any CPU onto one queue (#663)

One process writes three chunks to the terminal and may run on core 0 or on a
peer between writes. The model is the design decision for GitHub issue #663
before any of it is built, so it describes the kernel as it stands
(`LOCKED = FALSE`) and the option chosen (`LOCKED = TRUE`) side by side.

`LOCKED = TRUE`: every CPU appends to the one transmit queue in a critical
section under one console lock, the transmit interrupt takes chunks out under
the same lock, and the lock order is run -> console. Each action is one such
critical section, so the queue order is the lock order and a writer's chunks
reach the wire in the order it wrote them. `LOCKED = FALSE`: core 0 appends
directly and a peer publishes to its ring, which core 0 moves into the queue
at moments of its own. Three variants each re-introduce one defect, and `make
modelcheck` requires each to fail:

- `LOCKED = FALSE` is the current design. A chunk written on a peer sits in
  the ring while a chunk written later on core 0 goes straight to the queue,
  so the wire gets them reversed. TLC and Apalache both report
  `ProgramOrder`. This is what garbled the echo on the board.
- `RECHECK = FALSE` is #550's decide-then-sleep window applied to the queue:
  the writer decides the queue is full in one critical section and publishes
  itself asleep in a later one, the interrupt drains between them, and the
  writer sleeps beside a queue with room. TLC and Apalache both report
  `NoLostWakeup`.
- `NESTED = TRUE` is the lock-order defect: the transmit interrupt keeps the
  console lock while it takes the run lock for the wake. A writer that got
  the run lock first wants the console lock, so each waits for the other. TLC
  reports `Deadlock reached`; Apalache only shows that the variant runs.
- `POLLWAKE = FALSE` is GitHub issue #1211: a drain outside the transmit
  interrupt (`PollDrain`: the RX handler's resume drain, a kernel log line's
  drain) makes the room a sleeping writer waits for, but only the interrupt
  path wakes writers, and with the queue empty nothing enables the interrupt
  again. The writer sleeps beside an empty queue. TLC and Apalache both report
  `NoLostWakeup`. The kernel's drain marks the wake owed and keeps the
  interrupt enabled until its service has run (`POLLWAKE = TRUE`).

| Action | Kernel function it abstracts | What is kept | What is dropped, and why that is safe | Reviewed |
| --- | --- | --- | --- | --- |
| `WriterEnter` | `syscall_write_segment_with` | a terminal write is admitted whole under the run lock | fd lookup and the user-memory copy -- irrelevant to `ProgramOrder`: they run before the chunk is admitted and change no queue or lock | `4fd1259b7c7b` |
| `WriterAppend` | `uart_user_write`, `uart_terminal_write_chunk`, `uart_user_write_locked`, `uart_user_write_room_locked`, `syscall_write_segment_with`, `kernel_log_emit_line`, `kernel_log_emit_byte_locked`, `console_lock`, `console_unlock`, `mutex_acquire_measured` | the append to the queue under the console lock, or the decision that there is no room; on every CPU the same queue, and the run lock let go | short counts and partial chunks -- irrelevant to `ProgramOrder`: a partial chunk is a shorter chunk, and the model already appends each whole; nonterminal fd paths -- irrelevant to `ProgramOrder`: they do not append terminal bytes; kernel log lines -- irrelevant to `ProgramOrder`: they share the FIFO order without changing a terminal writer's chunk order; measurement counters -- irrelevant to `ProgramOrder`: they are updated under the same lock and never select queue contents, admission or ownership | `fa453cfb903d` |
| `BlockWriter` | `kernel_process_block_uart_tx` | the writer publishes itself asleep under the run lock; `RECHECK` is the room re-check there | successor choice and the switch -- modelled elsewhere: `Wait4Block.Wait4Block` | `d28cda46e101` |
| `TxTake` | `uart_tx_service`, `uart_tx_drain_into_fifo` | one chunk leaves the queue onto the wire under the console lock and makes room; `NESTED` keeps the lock | the FIFO's capacity and the byte-by-byte drain -- irrelevant to `ProgramOrder`: bytes leave the queue in order, so a chunk taken whole is the same order | `f1ef95519445` |
| `PollDrain` | `uart_tx_drain_into_fifo_force`, `uart_terminal_resume_output`, `uart_wire_byte`, `kernel_log_tx_writer_room_locked` | a drain outside the transmit interrupt takes a chunk onto the wire under the console lock and, when it gives writers their room, keeps the interrupt enabled so the service runs the wake | the FIFO and the interrupt's own timing -- irrelevant to `NoLostWakeup`: an enabled TX interrupt is taken once the FIFO falls to its level, which the drained bytes guarantee; the echo queue -- irrelevant to `NoLostWakeup`: echo pending is one more reason the room predicate is false, and the drain that empties it is this action | `872c40b37bf3` |
| `TxWake` | `kernel_process_uart_tx_wake_all` | under the run lock, a writer asleep on room becomes runnable | which other processes wait on UartTx -- irrelevant to `NoLostWakeup`: the model has one writer, and each waiter is woken by the same scan | `f0e8320644be` |
| `Drain` | Retired terminal ring; negative variant only | the former route delays peer chunks independently of the shared queue | the retired implementation -- irrelevant to `ProgramOrder`: this action is reachable only in the unfixed variant and remains its negative control | `e3b0c44298fc` |
| `Migrate` | `kernel_process_timer_schedule` | the process changes CPU between writes, never inside one (`KERNEL_PREEMPTIBLE` is 0) | affinity -- irrelevant to `ProgramOrder`: it only forbids some moves, and the model already allows each one it forbids | `5ca8ea2be2e4` |

Where the kernel stands against the model: terminal writers on every CPU,
the shared queue and FIFO drain use the console lock, with order run -> console.
The TX interrupt (`uart_tx_service`) releases it before the wake. Writer-room
rechecks also take the console lock. The maintained terminal follows
`LOCKED = TRUE`, `RECHECK = TRUE`, `NESTED = FALSE`, `POLLWAKE = TRUE`. The terminal ring and
its DDB rendezvous are retired; `Drain` remains only in the unfixed model
variant to demonstrate the old reordering.
The retained kernel-log publication stream is separate from terminal ordering.

Properties:

- `ProgramOrder` (safety): the wire is in the order the process wrote.
- `NoLostWakeup` (safety): the writer is never asleep while the queue has
  room and no wake is on its way.
- `AllSent` (liveness, TLC only): every chunk is written and sent, under
  fairness on each action.
- `TypeOK`: bookkeeping sanity.

## ConsoleOwner.tla -- console ownership by priority, any core (#830)

The switch between the queued console and the spinning one, after the UART
interrupt (and with it the queue's drain) stopped being core 0's. Maintainer
decision 2026-10-23, option C, modeled on Linux's nbcon: one atomic word in
`kernel/printk/log.tkb` holds an owner priority and cpu and a TERMINAL bit,
and the queue is live only while the platform has armed it and the word is
zero. Emergency (1), DDB (2) and the crash console (3) take the word by
compare-swap over a strictly lower priority, from any core; the two that
never return set TERMINAL even when outranked, and DDB gives back what it
displaced only while its own owner field is still there. Two cores, each
of which may enter DDB, continue, or enter a terminal path.

- `BLIND = TRUE` is the resume the kernel had before: it stores the found
  state back unconditionally. A DDB that continues after an emergency on the
  other core makes the queue live under it. TLC reports `TerminalStays`.
- `NOSTICKY = TRUE` is an outranked emergency that leaves no mark: the same
  continue, through a correct compare-swap, does the same. TLC reports
  `TerminalStays`.

| Action | Kernel function it abstracts | What is kept | What is dropped, and why that is safe | Reviewed |
| --- | --- | --- | --- | --- |
| `Activate` | `kernel_log_tx_activate` | the platform arms the queue once | the boot probe's re-init (`kernel_log_tx_ownership_reset`) -- irrelevant to `TerminalStays`: it runs on core 0 before any other core or terminal path exists | `693dfdcad0c5` |
| `EnterDdb` | `kernel_log_tx_stand_down_stopped`, `kernel_log_tx_take_owner`, `kernel_ddb_enter_stopped` | one compare-swap at debugger priority, or Outranked with no token | the queue flush after a successful take, a try-lock since #920 -- irrelevant to `TerminalStays`: it changes no ownership; the world stop -- irrelevant to `TerminalStays`: it only forbids some interleavings, and the model already allows each one it forbids | `f7ec36e25894` |
| `Terminal` | `kernel_log_tx_stand_down`, `kernel_log_tx_stand_down_stopped`, `kernel_log_tx_take_owner`, `kernel_log_enter_emergency`, `crash_console_run` | a take at emergency or panic priority, or TERMINAL alone when outranked; the core never returns | the per-core emergency byte path -- irrelevant to `TerminalStays`: it makes that core spin and never reads the word; the bounded retry of a lost compare-swap -- irrelevant to `TerminalStays`: each attempt is this one action, and an exhausted retry leaves the word as some other terminal taker set it | `e7af8bba07a9` |
| `Resume` | `kernel_log_tx_resume` | the compare-swap from DDB's own owner field back to the found owner, keeping TERMINAL; `BLIND` stores it unconditionally | the read-back line DDB prints -- irrelevant to `TerminalStays`: it only reads the word | `a442edb102ac` |

## UartServe.tla -- the UART serve try-lock under 1-of-N delivery (#925)

#830 routes the UART SPI to every online core (GICv2 1-of-N), and one core
at a time serves it: `uart_irq_serve` takes `uart_irq_service_busy` by
compare-swap, and a core that finds it taken EOIs and leaves. That is safe
only because every PL011 source is level: what the server did not drain
keeps the line up, so the interrupt is pending again. Three cores, an RX
FIFO of two bytes, and three source events (RX bytes or TX-space) in all.
`NoStranded`: no RX byte or TX-space event waits with no core about to serve
it and nothing pending; `OneServer`; `Quiesces` (liveness, TLC only): once
the sources stop, everything is served.

- `fixed` drops GICv2's active-state gate (`GATE = FALSE`): the SPI may reach
  a second core while the first is inside the handler, as
  `uart_irq_affinity.tkb` conservatively assumes. This is the variant that
  contends the try-lock.
- `gated` keeps the gate. The kernel clears the busy word before its EOI,
  so under the gate the try-lock is never contended (`TryLockBusy` is
  allow-listed as dead): the try-lock is a defence for deliveries the gate
  does not cover, not a path QEMU's GIC takes.
- `edge` (`EDGE = TRUE`) latches the interrupt on a rising line and lets a
  delivery consume it. A byte arriving after the server's drain goes to a
  core that finds the service busy and leaves. TLC reports `NoStranded`.

| Action | Kernel function it abstracts | What is kept | What is dropped, and why that is safe | Reviewed |
| --- | --- | --- | --- | --- |
| `Deliver` | `uart_irq_route` | the GIC hands the pending SPI to any idle core of the route, which acknowledges it; `GATE` forbids it while the SPI is active | which cores are online and the route rewrite after each EOI -- irrelevant to `NoStranded`: a narrower route only forbids some deliveries, and pending stays a property of the source | `22d1bdc9ec08` |
| `TryLockWin` | `uart_irq_serve` | the compare-swap of the busy word from 0 to 1 wins | the per-core taken counter -- irrelevant to `NoStranded`: it is only read by the boot report | `d6de02e82b9d` |
| `TryLockBusy` | `uart_irq_serve` | the compare-swap finds the word taken; the core goes to its EOI | nothing | `d6de02e82b9d` |
| `ServeTx` | `uart_irq_service`, `uart_tx_service` | the TX FIFO is refilled above its level | the writer wake under the run lock -- modelled elsewhere: `ConsoleTx.TxWake` | `18e019c77743` |
| `DrainRx` | `uart_irq_service`, `uart_rx_drain` | the RX FIFO is drained to RXFE | a BREAK that ends the drain early -- irrelevant to `NoStranded`: the bytes it leaves keep the line asserted, the same as bytes that arrive after the drain | `0e2700a3ec92` |
| `Release` | `uart_irq_serve` | the busy word is stored back to 0 | nothing | `d6de02e82b9d` |
| `Eoi` | `rp1_vector_iack`, `uart_irq_after_eoi` | the SPI stops being active on this core | DDB entry after the EOI -- irrelevant to `NoStranded`: the core takes no further UART step, which the model already allows by never delivering to it | `1d97797d26f8` |

## WorldStop.tla -- CPU startup and a complete machine stop

A shared nonblocking gate serializes CPU_ON reservations and stop requests.
Before firmware can expose a CPU, its bit joins the possible-participant set.
Only definitive absence removes a new bit. A complete machine stop captures
this set under the gate and waits for current-generation acknowledgements
from every other participant, including pending and uncertain starts.

The fixed model has three CPUs and two non-reused generations. TLC checks its
whole finite state graph; Apalache checks safety through eight steps. The
`subset` variant accepts a caller-selected subset as full-machine authority;
the `ungatedstart` variant starts a CPU during inspection. Both must violate
`NoUnstoppedRead` (the latter's Apalache bound is ten).

`RequestResolves` checks only that a waiting request eventually completes or
times out, under weak fairness on those two actions. It does not guarantee
that retries ever obtain a complete stop. IRQs opening infinitely often and
weak fairness alone do not guarantee that every CPU acknowledges within one
bounded wait or that an initiator wins a contested gate. No starvation-freedom
claim follows from this model alone; `WorldStopRetry.tla` checks the retry's
liveness under the timing and fairness assumptions it states. Physical
holding, firmware status truthfulness,
ARM ordering, interrupt decoding and raw mint correctness remain trusted.
The model treats owner-side reads as indivisible and does not model owner IRQ
mutation. The implementation now saves and masks owner IRQs before claiming
the gate, retaining that exclusion in full/partial stop and CPU-start guards.
Compiler tests reject IRQ re-enablement while those guards or derived pool
views remain live; this is separate evidence from the bounded model.

| Action | Kernel function it abstracts | What is kept | What is dropped, and why that is safe | Reviewed |
| --- | --- | --- | --- | --- |
| `StartReserve` | `cpu_start_reserve` | claim before adding the possible target, sharing the stop gate | exact bit encoding, and the gate's distinct start-holder value (#556) -- irrelevant to `NoUnstoppedRead`: the set is the mask's membership relation, and the value only names which holder a refused claim met | `42c15ac93b47` |
| `StartFirmware`, `CpuArrive` | `qemu_psci_cpu_on`, `rpi5_psci_cpu_on`, `kernel_secondary_main` | reserved target can execute before or after the firmware call returns | entry assembly and PSCI encoding -- irrelevant to `NoUnstoppedRead`: a CPU may arrive at any step after reservation; the cache-geometry halt before arrival (#759) and the FEAT_PAN halt after it (#1032) -- irrelevant to `NoUnstoppedRead`: each reads no shared state and is a CPU that never arrives | `626a62cb99ec` |
| `StartFinish`, `StartAbsent` | `cpu_start_finish`, `cpu_start_gate_release` | uncertain targets stay possible; only definitive absence removes a new reservation before releasing the gate | scheduler's contiguous online prefix -- irrelevant to `NoUnstoppedRead`: the full stop uses the independent possible-participant mask | `3ac0805fdc48` |
| `Claim`, `Publish` | `world_stop_claim`, `world_stop_begin_claimed`, `world_stop_machine_begin`, `world_stop_machine_begin_holding_probe` | one initiator; set capture under the gate; fresh request generation | the whole-machine stop's bounded wait while a start reservation holds the gate, including a release right after a failed CAS, which is classified by the value that CAS observed (#556, #613) -- irrelevant to `NoUnstoppedRead`: it changes no state until the gate is free and then takes the same `Claim`, or answers Busy; generation exhaustion -- irrelevant to `NoUnstoppedRead`: two generations are never reused and exhaustion only refuses another request; subset probe API -- irrelevant to `NoUnstoppedRead`: its distinct WorldStopped type cannot enter a whole-machine reader | `6be6b7993395` |
| `Ack`, `PenExit`, `ToggleIrq` | `world_stop_hold`, `kernel_world_stop_serve`, `kernel_ddb_stopped_root_publish`, `kernel_ddb_stopped_root_retire` | ack current request only after entering the pen; exit only when request changes; masked IRQs can delay ack (the quiescent SGI; the debug stop's NMI-priority SGI is taken through the priority mask, #920) | physical instruction timing -- irrelevant to `NoUnstoppedRead`: arbitrary scheduling allows every delay; stopped-root sequence parity -- irrelevant to `NoUnstoppedRead`: an unsettled root is refused, while the repeated real-stop fixture checks usable publication separately | `623e596ab909` |
| `Complete`, `Timeout` | `world_stop_begin_claimed` | all captured targets must ack the current generation; timeout yields no complete authority | spin count -- irrelevant to `NoUnstoppedRead`: timeout may happen at any waiting step | `2b89419b5373` |
| `Release` | `world_stop_resume`, `machine_stop_release`, `machine_stop_partial_release` | end the local authority before clearing request and releasing claim, then restore saved initiator IRQs | terminal keep-forever -- irrelevant to `NoUnstoppedRead`: it never resumes or releases the gate | `9c676f3ab022` |
| `Read` | `kernel_process_ddb_copy`, `kernel_ddb_enter_stopped`, `process_record_inspect_stopped`, `scheduled_process_record_stopped`, `scheduled_process_slot_remove`, `address_space_inspect_stopped`, `fd_context_inspect_stopped`, `fd_block_inspect_stopped`, `kernel_fd_table_stopped_entry`, `process_image_inspect_stopped`, `scheduled_process_diagnostic_copy`, `crash_snapshot_shared_stopped`, `crash_console_dispatch_stopped` | inspection requires the borrowed machine authority; scoped pool loans cannot cross resume or slot destruction | pool metadata Busy/Stale refusals and which record fields and memory commands are inspected -- irrelevant to `NoUnstoppedRead`: every successful inspection is gated by the same machine authority, while metadata consistency is a separate trusted mint condition checked before inspection; the NIC RX-pending look (`kernel_net_rx_frame_pending`, #959) -- irrelevant to `NoUnstoppedRead`: it reads device-written ring memory and driver shadows, no stop state, and takes no lock | `9ea06b50ca02` |

## Keeping models and the kernel in step

A model and the `.tkb` code drift apart silently: nothing compiles them
together. Three things keep them in step:

1. **The table above.** Each action names the functions it abstracts and
   what it deliberately leaves out. A reviewer of a change to one of those
   functions reads the row and asks whether the model's claim still holds.
2. **A build check that the named functions exist and every drop is
   justified** (in place). It catches a rename, a removal and a path left
   out with no reason, not a change of behaviour.
3. **A review stamp per row** (in place). The Reviewed column is a hash of
   the compiler's `body_hash` (docs/CALL_GRAPH.md) of every definition, in
   either kernel, of the functions the row maps and of the guards its
   dropped paths name. Any token change to that code fails the kernel build
   until someone re-reads the row against the model and runs
   `make model-map-restamp`; the commit that restamps says what was
   reviewed. A comment-only edit keeps the stamp. The
   stamp says only "look again", not what is wrong, and it fires whether or
   not any test exercises the change.

## WorldStopRetry.tla -- the Busy/Partial retry, any initiator (#641)

The retry slice of the world-stop protocol. Any of three CPUs may need a
Complete stop (an ASID rollover) and retries on Busy and Partial; any other
CPU may be interrupted into the hold pen, or be inside an IRQ-masked
section: a finite one holding the one modelled IRQ-masking lock, a spin on
that lock, or one longer than the spin budget. CPU startup and partial
membership are left to `WorldStop.tla`; generations are abstracted to "the
ack is for the live request" (a set every publication and release empties),
and `WorldStop.tla` checks the stale-ack window that leaves out. TLC covers
the whole graph, safety and liveness; Apalache checks `Safety` to length 4.

Properties:

- `Safety`: `StoppedWhileComplete` (a Complete token only while every
  other CPU is in the pen having acknowledged it), `AckedInPen` (only a CPU
  held for the live request counts as stopped), `NoFailStop`.
- `RetrySucceeds` (liveness): every CPU that needs a Complete stop gets one.
- `PenResumes` (liveness): every CPU in the pen leaves it. Release resumes
  exactly the CPUs that acknowledged; a CPU that never entered is untouched.

The assumptions the liveness rests on, each stated rather than proved:

1. **Spin budget.** `Timeout` (Partial) fires only while some target cannot
   acknowledge within the budget (`LongMasked`): it is masked longer than
   the budget, spins on a lock the initiator or a held CPU owns, retries
   with IRQs masked, or refuses the request. Every acknowledgement that can
   arrive is assumed to arrive within `SCHEDULER_WORLD_STOP_SPINS` rounds.
   Variant `shortbudget` drops this and loses `RetrySucceeds`.
2. **Finitely many masked sections longer than the budget** (`longLeft`,
   one). A peer in DDB or the crash console, or a fault loop at EL1, keeps
   IRQs masked past the budget; each such Partial is retried. Variant
   `stuck` lets one never end and loses `RetrySucceeds`: a CPU spinning with
   IRQs masked cannot take the quiescent stop SGI, so every attempt ends
   Partial and the retrier livelocks, never with a Complete token. That is
   what Partial means here: some target was masked for the whole budget.
   The quiescent stop keeps that meaning on purpose (GitHub issue #920): a
   CPU that could own a lock is never held by it, so its work (the ASID
   rollover takes `asid_cell`) cannot wait on a held CPU. The DEBUG stop is
   the one that reaches such a CPU -- the pseudo-NMI SGI above the GIC
   priority mask -- and is modelled by `NMI_STOP` below.
3. **A pending SGI is taken first.** The GIC keeps the SGI pending; an
   IRQ-open CPU takes it before its next instruction, so while it is
   pending an IRQ-open CPU only acknowledges (`Pending` guards its other
   steps).
4. **Fairness.** Steps a CPU takes without waiting on another (`Ack`,
   `PenExit`, `Exit`, `LongExit`, `Claim`, `Busy`, `Complete`, `Timeout`,
   `Finish`, `Retry`) are weakly fair. `Acquire` is strongly fair: an
   assumption, since `mutex_acquire`'s spin is not FIFO. Entering a masked
   section and needing a stop are not fair.
5. **One rollover serves every waiter.** `Finish` empties `wants`: after
   the back-off each retrier prepares its activation again and finds the
   generation current.

Variants (`make modelcheck` requires each verdict):

- `fixed` holds `Safety`, `RetrySucceeds` and `PenResumes`, and reaches
  `Timeout` through the one long masked section.
- `failstop`: Busy and Partial fail-stop, #632's activation defect;
  violates `Safety` (`NoFailStop`).
- `core0ack`: only CPU 1's stop is acknowledged, #632's sender-decode
  defect in model form; loses `RetrySucceeds` for every other initiator.
- `maskedbackoff`: a retrier keeps IRQs masked between attempts (a caller
  that entered with IRQs masked); two such retriers time each other out
  forever; loses `RetrySucceeds`.
- `holdlock`: a retrier holds an IRQ-masking lock across its attempts; a
  peer spinning on it never acknowledges; loses `RetrySucceeds`. The
  compiler rejects this shape: `world_stop_machine_begin` declares
  `acquires_lock_10_world_stop`, below every other lock class, so calling it
  while any ranked guard is live is a lock-order error.
  `scripts/buildcheck_world_stop_rank.py` keeps that rank the lowest and
  allows the unranked `world_stop_machine_begin_holding_probe` only in the
  single-attempt `*_probe` functions that hold a pool guard on purpose.
- `stuck`, `shortbudget`: assumptions 2 and 1 dropped, as above.
- `debugstop` (#920): the debug stop (`NMI_STOP`), which a CPU also takes
  inside a masked section, a lock spin or a masked section that never ends,
  with work that takes no lock (`STOPPED_LOCKS` false). It holds `Safety`,
  `RetrySucceeds` and `PenResumes` even with a CPU masked for good -- what
  the escalation buys.
- `debuglocks` (#920): the same stop whose work takes the lock: a CPU held
  while it owns the lock is never released, and the work never finishes;
  loses `RetrySucceeds`. The compiler rejects this shape:
  the caller of `world_stop_debug_begin` (`starts_debug_stop`) must be a
  `debug_stopped` root, which reaches no lock and spends the token inside.

The compiler rejects `maskedbackoff`'s shape too (#809):
`kernel_process_rollover_backoff` declares `requires_irq_unmasked`, so
reaching it from an `interrupt` or `exception` root, while an IRQ-masking
or lock guard is live, or after a bare `disable_irq` or an unrestored
`mutex_irq_save` on the same path is a compile error (SPEC.md). What stays
outside: a mask the checker cannot see -- one set in assembly before the
Takibi entry, or behind an indirect call. No real run is checked
against this model (#810: world-stop events are not recorded, and no lock
orders them, so StackOwnershipTrace.tla's one-step-per-run-lock-hold
mechanism does not carry over).

| Action | Kernel function it abstracts | What is kept | What is dropped, and why that is safe | Reviewed |
| --- | --- | --- | --- | --- |
| `Need`, `Retry` | `kernel_process_activate_stable_root`, `kernel_process_activate_current_root`, `kernel_process_rollover_backoff` | RolloverNeeded begins a stop with IRQs saved and masked; after Busy or Partial the back-off runs with the caller's IRQ state restored, then preparation is retried and begins another stop only while a rollover is still needed | the busy-injection test hooks -- irrelevant to `RetrySucceeds`: they only add back-offs before the first real attempt, finitely many; the secondary-start path, which hands the process back instead of looping -- irrelevant to `RetrySucceeds`: the scheduler retries the same Ready process later, the same back-off and retry | `3e5230cbe226` |
| `Claim`, `Busy` | `world_stop_machine_begin`, `world_stop_machine_begin_holding_probe`, `world_stop_claim` | any CPU may claim; a held gate answers Busy at once | the bounded wait for a CPU-start holder (#556) -- modelled elsewhere: `WorldStop.StartReserve`; generation exhaustion -- irrelevant to `RetrySucceeds`: a 64-bit counter is not exhausted by any run | `0f0a55f8be89` |
| `Complete`, `Timeout`, `Finish` | `world_stop_begin_claimed`, `machine_stop_release`, `machine_stop_partial_release`, `world_stop_resume` | Complete only when every other CPU acknowledged the live request; Partial when the budget runs out; release clears the request, then the gate | the spin count itself -- irrelevant to `RetrySucceeds`: assumption 1 states what the budget is assumed to cover; the rollover body -- irrelevant to `RetrySucceeds`: it runs under the Complete token and changes no stop state | `76bc63b66e50` |
| `Ack`, `PenExit` | `world_stop_hold`, `world_stop_interrupt_hold`, `kernel_world_stop_serve` | a CPU with IRQs open acknowledges the live request and spins until it is released or overtaken, and under the debug stop (`NMI_STOP`, #920) a masked or spinning CPU does too; the owner never holds itself | the two-step read-then-store of the hold -- modelled elsewhere: `WorldStop.Ack`; the stopped-root publication -- irrelevant to `RetrySucceeds`: it runs inside the pen and changes no stop state | `7e1c96b35725` |
| `Enter`, `EnterSpin`, `Acquire`, `Exit`, `LongEnter`, `LongExit` | `mutex_irq_save`, `pool_lock_acquire`, `pool_lock_release` | a masked section holding a lock, and a masked spin waiting for it | which lock and what it guards -- irrelevant to `RetrySucceeds`: only whether a masked CPU can be blocked by the stop's owner matters, and one lock shows it | `52c0c9384d27` |

## SharedRegionTransfer.tla -- general partial authority and protocol handoff

This is a first B+C design layer for the shared DMA consumer, not an
implemented ownership feature. Two abstract cells represent disjoint
subregions. A nonempty reservation retains only its span; preparation,
publication, device access and completion observation are separate actions.
This distinguishes a resource's existence from the correctness of the
protocol that transfers it. The model is not a complete xHCI ring model.

The correspondence below identifies the existing consumer functions whose
contracts the general API must replace. In particular, the matching-event
predicate and typed reservation are proposed stronger contracts, not claims
that the current driver implements them. A passing model does not validate
those bodies or supply memory access authority.

| Action | Kernel function it abstracts | What is kept | What is dropped, and why that is safe | Reviewed |
| --- | --- | --- | --- | --- |
| `Reserve` | `usb_ctrl_xfer`, `usb_bulk_xfer`, `xhci_run_command` | writes at the producer cursor need the ring's whole-region XhciRing Ready owner (usb_xhci_rings.tkb, decision S1); the reserved subregion itself is not a typed owner | ring wrap -- irrelevant to `Safety`: this layer treats the reserved span as abstract cells, and makes no wrap or ring-progress claim | `ad7febd06e78` |
| `Prepare` | `usb_ctrl_xfer`, `usb_bulk_xfer`, `xhci_run_command` | each descriptor cell is initialized before publication | descriptor encodings -- irrelevant to `ReadyBeforeRead`: this property distinguishes initialized cells from uninitialized cells, not the meaning of their bits | `ad7febd06e78` |
| `Publish` | `usb_ctrl_xfer`, `usb_bulk_xfer`, `xhci_run_command` | publication consumes CPU permission before the device may access the span: XhciRing's generated publishing edge cleans, moves the ring to InFlight, and only then rings the doorbell | cache visibility -- irrelevant to `ReadyBeforeRead`: this property tracks initialization, not whether backing memory contains the latest writes | `ad7febd06e78` |
| `DeviceRead`, `DeviceComplete` | `usb_await_event` | environment actions represent device access and completed access to this span; completion truth is an explicit device assumption | device implementation -- irrelevant to `NoOverlap`: the environment nondeterministically reads or completes, and the invariant tests which authority the host holds | `5ad3531d03a8` |
| `ForeignEvent`, `DiscardForeign`, `Observe` | `usb_await_event` | matching-event observation: an event is Matching only when its TRB Type, its TRB Pointer inside the request's TRBs and, for a transfer, its slot and endpoint are the request's (xhci_event_match.tkb); every other event is discarded without ending the wait | raw event decoding -- irrelevant to `Safety`: Matching and Foreign are abstract truth labels, and the decoder that distinguishes them is tested by linux_user/xhci_event_match, with TRB-address reuse excluded by the synchronous driver (TRUSTED_BASE.md) | `5ad3531d03a8` |
| `Timeout` | `msc_abort_unobserved_transfer` | missing completion retains the pending authority | iteration bound -- irrelevant to `Safety`: timeout may occur at any point after publication and is never completion evidence | `187f503790fd` |
| `ConfirmReset`, `ResetFailed` | `xhci_halt_and_reset`, `msc_abort_unobserved_transfer` | confirmed quiescence and failure are distinct; failure retains possible device activity | register polling -- irrelevant to `Safety`: confirmed reset is an explicit environment contract, not the act of requesting reset | `fdcffb04752e` |
| `Restart` | `usb_disk_initialize_stages`, `xhci_setup_rings_and_start` | initialization requires quiescence and reclaims retained authority; failure cannot grant it | reset register ordering -- irrelevant to `Safety`: this layer checks authority reclamation, not whether the hardware accepts a new session | `1f16a6c85772` |

Properties: `NoOverlap` excludes simultaneous CPU authority and device
activity on a cell; `ReadyBeforeRead` excludes reading an unprepared cell.
`Safety` is their conjunction. TLC checks the complete finite state space;
Apalache typechecks it and checks shallow traces. No liveness, capacity,
wrap, endpoint recovery, session-identity or cache-order proof is claimed.

The fixed variant passes. Each independent control violates `Safety`:

- `early`: publication before every reserved cell is prepared;
- `foreign`: reclaim on an unrelated completion while the device is active;
- `timeout`: reclaim on a timeout alone;
- `failedreset`: restart after failed reset while device activity remains.

The next connection to code needs general protected backing storage and
retained region ownership, then generated permissions that carry that same
region. An erased state token over independently accessible memory would
not establish `NoOverlap` in the implementation.

### protocols/ -- the same protocol as a Takibi declaration

`protocols/RegionTransfer.tkb` states this protocol as a Takibi `protocol`
declaration (SPEC.md, "Protocol Declarations"). `make modelcheck` runs
`takibi --generate tla` on every `protocols/*.tkb` into `_build/models/generated/`
and checks the output; nothing generated is tracked. The fixed declaration
passes, and `RegionTransferEarly_faulty.tkb`, which drops `requires
prepared`, violates `Safety` as the handwritten `early` control does. The
`foreign`, `timeout` and `failedreset` faults cannot be declared at all:
the compiler rejects a witness without a request identifier and a
transition out of a `device` state without a `completes` or `quiesces`
witness, so those three are compiler rejection tests rather than models.
`TxTransfer.tkb`, `RxTransfer.tkb` and `PacketBuffer.tkb` are device
protocols (GitHub issue #778): their models add cached, dirty and stale
cells and `CacheCoherent`, and each edge's cache step comes from the rule
the wrappers are generated by. The generator always emits that step, so
the fault controls are generator-side: `--internal-tla-omit-cache publish`
(tx and rx) and `finish` (rx) leave it out of the model, giving
`TxTransfer_omitpublish`, `RxTransfer_omitpublish` and
`RxTransfer_omitfinish`, each of which must violate `Safety`.
`RxTransfer.tkb`'s `peek` is a `snapshot` observation (GitHub issue #801):
its model step reads one held cell after the generated per-element
invalidate, and `--internal-tla-omit-cache refresh` gives
`RxTransfer_omitrefresh`, which must violate `Safety` as well. The
invalidate and the copy are one step: a device write between them makes
the copy old, which the consumer's protocol handles, not incoherent.
The generated model keeps one cache rather than composing the two cores'
lines of `DmaCacheVisibility.tla` below. The generated cache steps are
whole-region or per-element maintenance by address; whether that
maintenance reaches the other core's lines and survives a holder migration
depends only on the builtin (`dma_prepare_tx`, `dma_prepare_rx`,
`dma_finish_rx`), not on the declaration, and `DmaCacheVisibility.tla`
already checks it, with `localinvalidate` as the control. Per-core lines
in every generated model would double the three cache sets and add a
holder variable for no declaration-dependent fault.
Generated actions are named after the declaration's
transitions and observations, so they have no action-table rows: the code
they will map to is the sealed permission API generated from the same
declaration, not yet built. Until then the handwritten table above remains
the reviewed correspondence.

## DmaCacheVisibility.tla -- what a CPU reads after a receive handoff (#625)

FixedDmaOwnership.tla checks who holds a fixed allocation's authority. This
model checks what the holder then reads. It keeps the data: two cores'
cache lines (`lst`, `lval`), backing memory (`mem`), the device's write and
completion, and the holder's prepare / completion / finish sequence. A
ghost `truth` holds the latest defined contents; `dma_begin_rx` makes them
undefined until the device writes. Ownership and visibility are separate
variables: `phase` and `holder` say who may access, the line states say
what an access returns.

The receive path checked is the MSC CSW allocation `MscCswReceive` on RPi5
(`kernel/platform/rpi5/usb_xhci_dma.tkb`), a 64-byte `dma_fixed` record
aligned to 64; the other fixed receive records use the same builtins and
the same lowering. One line stands for the allocation: every line is
maintained by the same loop, and the `dma_fixed` placement rule keeps any
other object out of them.

**The lowering modelled** (`lib/llvm_gen.ml`, AArch64): `dma_begin_rx` is
`dma_prepare_rx`, which emits `dc ivac` over the range, `dsb ish; isb`,
then `dsb sy`. `dma_finish_owned_rx` is `dma_finish_rx`: `dsb sy`, the
same `dc ivac` loop, `dsb ish; isb`, `dsb sy`. `usb_await_event`'s poll
takes an XhciEvents snapshot of the entry at the dequeue index, which is
the same `dma_finish_rx` lowering over that entry's lines; its leading
`dsb sy` also completes any earlier maintenance before the completion is
read.

**Hardware assumptions.** These are enabling conditions of actions, not
properties, and the model proves nothing about them:

- The kernel maps the allocation Normal write-back, Inner Shareable
  (`kernel/arch/arm64/mm/mmu.tkb`: MAIR index 1 = `0xff`, descriptor
  `0x705`). CPU caches are coherent with each other and not with the RP1
  PCIe master. Any core may speculatively fill a clean copy, or evict a
  line, at any time whoever holds authority (`SpecFill`, `Evict`).
- `dc ivac` by VA to the point of coherence reaches every cache of the
  Inner Shareable domain. On a dirty line it discards the data or may
  write it back first (as when executed as `dc civac`); the model allows
  both.
- `dsb` completes all earlier cache maintenance before any later
  instruction executes, and orders it after earlier loads (Arm ARM DDI
  0487, ordering and completion of data cache maintenance instructions).
- `CTR_EL0.DminLine` and the writeback granule `CTR_EL0.CWG` are at most
  64 bytes (`DMA_CACHE_LINE`), as on Cortex-A76; otherwise the loop's
  rounding would reach a neighbouring object's line.
  Checked at bring-up on every core, which halts otherwise
  (`kernel_cache_geometry_require` in `kernel/init/boot_prologue.tkb`,
  decoding tested by `linux_user/cache_geometry`; GitHub issue #759).
- The device's data writes reach memory before its Transfer Event can be
  observed (PCIe posted-write ordering; xHCI 1.2, 4.11.3.1), and a
  confirmed halt ends its writes (xHCI 1.2, 5.4.1.1). A completion event
  that overtakes its data is outside the model.

| Action | Kernel function it abstracts | What is kept | What is dropped, and why that is safe | Reviewed |
| --- | --- | --- | --- | --- |
| `CpuWrite`, `CpuRead` | `msc_csw_receive_attempt` | a CPU access through `dma_cpu_slice` while the holder has CPU authority; a read returns the holder's line, another core's dirty line, or memory | which bytes are touched -- irrelevant to `ReadsCurrent`: every line of the allocation is maintained identically | `2365f5438d22` |
| `Handoff` | `msc_csw_put`, `msc_csw_take` | the CPU token stored on one core and taken on another, after the finish's barriers completed | the mutex instructions -- irrelevant to `ReadsCurrent`: they move no line, and the finish's `dsb` completed the invalidate before the put | `4311ac6127b7` |
| `BeginRx`, `PrepareInvalidate`, `Submit` | `msc_csw_receive_once`, `usb_bulk_in` | `dma_begin_rx`'s invalidate completed before the doorbell; the contents become undefined | the TRB and doorbell encoding -- irrelevant to `DeviceDataKept`: only the order of the doorbell after the invalidate matters to the line | `8f538a69d1df` |
| `DeviceWrite`, `DeviceComplete` | `usb_bulk_in` | the device writes memory directly, then makes its completion observable | the 13-byte span inside the 64-byte line -- irrelevant to `ReadsCurrent`: the CPU reads only bytes the whole-line invalidate covered | `f3b0b8bf936b` |
| `ObserveCompletion` | `usb_await_event` | the final Transfer Event observed after the poll's barrier | event decoding -- modelled elsewhere: `SharedRegionTransfer.Observe` | `5ad3531d03a8` |
| `Timeout`, `ConfirmReset`, `ResetFailed` | `msc_abort_unobserved_transfer`, `xhci_halt_and_reset` | a confirmed halt ends device writes; a failed one keeps Device authority and no CPU access follows | the retained token's storage -- modelled elsewhere: `FixedDmaOwnership.PutDma` | `56c40346902d` |
| `FinishInvalidate`, `Finish` | `msc_csw_receive_once` | `dma_finish_owned_rx`'s invalidate ordered after the completion and completed before CPU authority returns | `dsb sy` versus `dsb ish` scope -- irrelevant to `ReadsCurrent`: either completes the maintenance for every Inner Shareable core | `4dc6296f8830` |

Properties: `ReadsCurrent` -- a permitted read returns the latest defined
contents, so a read after a completed receive sees the device's data;
`DeviceDataKept` -- no CPU-dirty line is written over device data before
the finish; `NoReadWhileDeviceActive` -- the composition with
FixedDmaOwnership, reads only with authority; `CoherentCaches` -- a dirty
line is the only copy. `Safety` is their conjunction with `TypeOK`. TLC
covers the whole state space with two cores and one transfer; Apalache
typechecks and runs shallow traces.

The fixed variant passes. Each control removes one step of the lowering:

- `noprepare`: no prepare invalidate. A dirty line from an earlier CPU
  write is evicted over the device's data (`DeviceDataKept`).
- `unpublished`: the prepare's trailing barrier dropped, so the doorbell
  may precede the invalidate (`DeviceDataKept`).
- `nofinish`: no finish invalidate. A clean line speculatively filled
  while the device owned the buffer is read (`ReadsCurrent`).
- `earlyinvalidate`: the finish's leading `dsb sy` dropped, so the
  invalidate may be performed before the completion or reset is observed
  and a later speculative fill brings stale data back (`ReadsCurrent`).
- `lateread`: the finish's trailing barriers dropped, so the read may be
  performed before the invalidate (`ReadsCurrent`).
- `localinvalidate`: the invalidate reaches only the issuing core. A line
  dirty on the other core survives the prepare (`DeviceDataKept`); this is
  why the model has two cores.

What this does not prove: the Arm memory model itself. The barrier
semantics above are assumed, not derived; an abstract interleaving model
can show that each barrier the lowering emits is needed under them, but
not that they describe the silicon. An architecture-level check (for
example an axiomatic Arm model extended with cache maintenance) would be
the evidence for that part. Live metadata refresh (a protocol `refresh` step) is
not modelled; transmit cleaning is DmaTxReadBorrow.tla's.

## DmaTxReadBorrow.tla -- reading a buffer the device is transmitting (#740)

The transmit direction of DmaCacheVisibility.tla, with the question #740's
packet pool needs answered first: may the CPU READ a buffer while the
device owns it for reading (a TCP retransmit queue holding a `TxPosted`
owner)? Same two-core cache environment and assumptions; `sent` is a ghost
of the contents at the doorbell, and the device reads memory only.

The lowering modelled is a `tx` publishing edge (`__protocol_dma_clean`:
`dc cvac` over the region, then `dsb`), the state change and the doorbell.
The maintained consumers are the virtio-net and GEM packet pools (#740).

| Action | Kernel function it abstracts | What is kept | What is dropped, and why that is safe | Reviewed |
| --- | --- | --- | --- | --- |
| `CpuWrite` | `net_transmit_ready`, `virtio_net_send_built` | a write through the Free owner's bytes on any core | which bytes -- irrelevant to `DeviceReadsPosted`: every line of the region is cleaned identically | `908f006cdb9c` |
| `Clean`, `Post` | `virtio_net_send_built`, `net_transmit`, `net_packet_kept_resend` | the generated clean completed before the state change and the doorbell | the descriptor encoding -- irrelevant to `DeviceReadsPosted`: only the doorbell's order after the clean matters to the line | `683db9cd97a4` |
| `DeviceRead`, `Complete` | `virtio_net_tx_finish` | the device reads memory while posted; an observed used entry returns the owner to the CPU | the bounded wait and expiry -- modelled elsewhere: `FixedDmaOwnership.Timeout` | `c7fb3d8cda8a` |

`CpuRead` in the posted phase is the read-only borrow; no kernel function
takes it yet (the pool's retransmit queue will).

Properties: `DeviceReadsPosted` -- the device transmits what the CPU had
written at the doorbell; `ReadsCurrent` -- a CPU read, the borrow while
posted included, returns the latest write; `CoherentCaches`.

The fixed variant passes: a read while posted is safe, because the device
writes nothing, the clean left every line equal to memory, and no write
can happen while posted. Controls:

- `writewhileposted`: a write while posted, then an eviction, changes what
  the device reads (`DeviceReadsPosted`). This is why a device state has
  no write accessor and the borrow is read-only.
- `noclean`: the doorbell without the clean; the device reads stale memory
  (`DeviceReadsPosted`).

The result holds for a `tx` device state only. In an `rx` state the device
writes, and a read there is DmaCacheVisibility's `NoReadWhileDeviceActive`
violation; a snapshot is the only read of an `rx` state.

## PacketReserve.tla -- kept packets starve neither RX nor TX (#740)

The TCP retransmit queue keeps a sent segment in its pool buffer
(`net_transmit_keep`): the completion parks it Kept instead of Free, a
retransmission resends it in place and parks it Kept again
(`net_packet_kept_resend`), and its free (`net_packet_free`) runs on any
core without the RX capability and only returns the buffer to its pool
slot. The ring is refilled only by the capability's holder, and it fills
every empty descriptor before a buffer stays Free. If kept packets took too
many buffers, either no RX descriptor would be posted (no frame arrives, no
acquire runs, nothing refills: a stall), or the refill would post every
buffer left and a kernel-built frame (`net_transmit_ready`) would find none.
The model counts buffers by where they are (posted, free, held by the turn,
kept, in TX) and checks `RingNeverDrains` (at least one RX descriptor is
posted in every state) and `TxNeverStarves` (between turns a Free buffer is
left).

| Action | Kernel function it abstracts | What is kept | What is dropped, and why that is safe | Reviewed |
| --- | --- | --- | --- | --- |
| `Acquire`, `Poll` | `net_rx_acquire`, `virtio_net_rx_refill`, `gem_rearm_rx` | a used entry's buffer becomes the turn's packet and the ring is refilled in the same call; with no frame, the call still refills | the used-ring snapshot and descriptor ids -- irrelevant to `RingNeverDrains`: only how many buffers are posted matters; `gem_rearm_rx` recording the posted index only after the arm (#959) -- irrelevant to `RingNeverDrains`: the count posted per call is unchanged | `fac8322c4969` |
| `Release` | `net_rx_release` | the buffer returns Free and the ring is refilled | nothing | `666fb798b7de` |
| `Reply`, `TxComplete` | `net_rx_send_reply`, `net_tx_complete`, `virtio_net_tx_finish`, `gem_tx_finish` | the turn's packet goes out as TX; completion returns it Free, or Kept for a kept send, and refills | the transmit itself and its bounded wait -- modelled elsewhere: `FixedDmaOwnership.Timeout` | `07f0dc30d13f` |
| `SendBuilt` | `net_transmit_ready` | a kernel-built frame takes a Free buffer; completion refills | the payload copy -- irrelevant to `RingNeverDrains`: it does not move a buffer | `eaed3f557a5d` |
| `SendKept` | `net_transmit_keep`, `net_tx_keep_slot`, `virtio_pkt_out_count`, `gem_pkt_out_count` | keeping is refused when fewer than RESERVE buffers would stay outside the kept set; a refused keep is a `SendBuilt` | the slot choice and the length record -- irrelevant to `TxNeverStarves`: only how many buffers are kept matters | `e7b342a860c9` |
| `Resend` | `net_packet_kept_resend`, `net_packet_kept_claim` | a kept buffer goes out again and its completion parks it kept | the claim's slot lookup -- irrelevant to `TxNeverStarves`: it does not move a buffer between sets | `e2baff14c957` |
| `FreeKept` | `net_packet_free`, `net_packet_kept_claim` | a kept buffer returns Free off-turn, the ring untouched | the claim's slot lookup -- irrelevant to `RingNeverDrains`: it does not move a buffer between sets | `d061be08ffd2` |

An unconfirmed transmit is not modelled: it disables both queues
(`FixedDmaOwnership.Timeout`), after which no RX is expected and no frame is
kept.

Variants: `fixed` (virtio-net's 10 buffers, 8 descriptors, RESERVE 9) and
`gem` (4 buffers, 1 descriptor, RESERVE 2) pass: RESERVE is D + 1, every
descriptor plus one spare, so virtio-net keeps one segment and GEM two.
Controls on a 4-buffer pool: `reserved` (2 descriptors, RESERVE D) starves
the transmit (`TxNeverStarves`), and `noreserve` (GEM's shape, RESERVE 0)
drains the ring (`RingNeverDrains`).

## PacketReserveScan.tla -- the reserve scan against off-turn frees (#740)

PacketReserve.tla with per-slot states and the reserve check's scan made
concurrent. Between turns the capability holder walks the slots one lock at
a time (`net_tx_keep_slot`), counting empty and Kept slots, and then sends,
kept or plain. Meanwhile any other core may claim a Kept packet or free a
claimed one. `RingNeverDrains` and `TxNeverStarves` as before, and
`ScanNeverLow`: at the decision, the scanned count is at least the true
number of buffers the stack has. A free can only lower the true count after
the scan has read the slot.

| Action | Kernel function it abstracts | What is kept | What is dropped, and why that is safe | Reviewed |
| --- | --- | --- | --- | --- |
| `ScanStart`, `ScanStep` | `virtio_pkt_out_count`, `gem_pkt_out_count` | one slot read under its lock per step; empty and Kept slots count | the take-and-park of each slot -- irrelevant to `ScanNeverLow`: the slot's state is the same before and after | `5f7693c9a6a9` |
| `KeepDecide` | `net_tx_keep_slot`, `net_transmit_keep` | a Free buffer sent and kept when the count leaves the reserve, else sent plainly | the kept length record -- irrelevant to `RingNeverDrains`: it does not move a buffer | `6977aecfb5a8` |
| `Resend` | `net_packet_kept_resend` | a Kept buffer sent again by the holder, Kept at completion | nothing | `163bd62663ff` |
| `Claim`, `FreeKept` | `net_packet_kept_claim`, `net_packet_free` | off-turn, under the slot's lock only, interleaving with every holder step | nothing | `e96c6e52906d` |
| `Acquire`, `Poll`, `Release`, `Reply`, `SendBuilt`, `TxComplete` | `net_rx_acquire`, `net_rx_release`, `net_rx_send_reply`, `net_transmit_ready`, `net_tx_complete` | as in PacketReserve.tla, by slot | the transmit's wait -- modelled elsewhere: `FixedDmaOwnership.Timeout` | `0be7c68881ac` |

Variants: `fixed` (5 buffers, 3 descriptors, RESERVE 4) and `gem` (4, 1,
RESERVE 2) pass. The state space is per slot, so these pools are smaller
than virtio-net's 10; PacketReserve.tla covers 10/8 by counts. Control (2
buffers, 1 descriptor, RESERVE 1, for a short trace): `skipempty`, a scan
that does not count empty slots (claimed packets), undercounts
(`ScanNeverLow`) and keeps past the reserve.
