# Kernel protocol models

TLA+ models of the kernel's multicore protocols (GitHub issue #601). A model
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

## How the models are written

Plain TLA+, not PlusCal, with Apalache type annotations (`\* @type: ...;`
comments) from the first line. TLC checks every model over its whole state
space, safety and liveness. Apalache type-checks it and runs a shallow check,
so a model can move to Apalache, whose symbolic search scales past what TLC
can enumerate, without a rewrite.

Each action is one critical section under the process-run lock in the
kernel. An action is atomic in the model exactly because it is atomic there,
and a window between two critical sections is a place where another action
can run. That is the whole point of writing the model: #550's defect is such
a window.

Every model has two variants, fixed and unfixed, selected by a constant. The
unfixed one must violate its property, or the model has stopped modelling the
defect it was written for, and `make modelcheck` fails.

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

Two cores; a parent, its child, and one other runnable process.

| Action | Kernel function it abstracts | What is kept | What is dropped, and why that is safe |
| --- | --- | --- | --- |
| `Wait4Decide` | the wait4 arm of `kernel_syscall_dispatch_action` | the zombie check and the decision to block, under one hold of the run lock (#571) | the pid, the status copy and ECHILD -- irrelevant to `NoLostWakeup`: none of them changes which process is Blocked or Exited |
| `Wait4Block` | `kernel_process_block_current`, `kernel_process_block_reserved` | successor choice and the Blocked publication in one critical section; `RECHECK` is the zombie re-check there | ASID preparation and the lock drop around it -- irrelevant to `NoLostWakeup`: the drop comes after Blocked is published and re-checked, and the successor it crosses with is already reserved Running |
| `ChildExit` | `kernel_process_child_exit` | the child becomes a zombie and wakes the parent only if the parent is Blocked in ChildExit | zombie draining -- irrelevant to `NoLostWakeup`: it reaps the exiting child's own children, never this parent or this child; SIGCHLD -- irrelevant to `NoLostWakeup`: it makes no process Blocked or Exited, and only such a step can break the property; the direct parent start -- modelled elsewhere: `StackOwnership.ChildExitStart` |
| `Wait4Resume` | `kernel_syscall_wait4_deliver` | the woken parent reaps | the user-memory status write -- irrelevant to `NoLostWakeup`: it runs after the reap, when the child is no longer Exited |
| `Preempt` | `kernel_process_timer_schedule` | the timer takes a process off its core, never inside the parent's wait4 syscall (`KERNEL_PREEMPTIBLE` is 0) | nothing |
| `Dispatch` | `kernel_process_secondary_start`, `kernel_process_schedule` | an idle core takes a Ready process | affinity -- irrelevant to `NoLostWakeup`: it only forbids some dispatches, and the model already allows each one it forbids; stack ownership -- modelled elsewhere: `StackOwnership.Dispatch` |

Properties:

- `NoLostWakeup` (safety): the parent is never Blocked while its child is a
  zombie. The unfixed variant violates it in four steps: decide, child exits,
  block.
- `Wait4Finishes` (liveness, TLC only): wait4 eventually completes, under the
  fairness the kernel's scheduler rotation provides.
- `TypeOK`, `RunningMatchesCores`: bookkeeping sanity.

## StackOwnership.tla -- kernel stacks across switch, exit and idle

Two cores; a parent and the child it clones. A core's logical current
process and the stack it physically stands on are separate variables, as
they are in the kernel, and `owner` records each process stack's physical
owner.

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
  two steps.
- `WAKE_START_CHECKS_STACK = FALSE` is #609's shared stack. Once wait4 ran
  on a peer, a parent could block there, publishing Blocked while that peer
  still stood on its stack. The child's exit on core 0 woke the parent and
  started it at once, on the same stack. TLC and Apalache both report
  `StartsOnFreeStack`, in six steps: clone, switch, the parent dispatched
  to the other core, switch, block, exit.

| Action | Kernel function it abstracts | What is kept | What is dropped, and why that is safe |
| --- | --- | --- | --- |
| `Clone` | `kernel_process_clone_begin`, `kernel_syscall_clone_child_return` | the child's first return runs first, on its parent's stack | fork's fd and VM copies -- irrelevant to `StackSafety`: they touch no kernel stack and no core's current process |
| `SwitchComplete` | `kernel_process_stack_switch_complete` | the physical handoff at exception return: release the stack stood on, own the current process's | nothing |
| `Wait4Block` | the wait4 arm of `kernel_syscall_dispatch_action`, `kernel_process_block_current` | a parent blocks before its child exits, with no successor | the #550 window -- modelled elsewhere: `Wait4Block.Wait4Decide`; a block that switches straight to a successor, leaving the core on the parent's stack -- guarded: `scheduled_process_start` fail-stops with `start-on-owned-stack` |
| `ChildExit` | `kernel_process_child_exit`, `kernel_syscall_exit_current_process` | the child becomes a zombie and wakes a Blocked parent, leaving it Ready with its continuation; the core still stands on the zombie's stack | zombie draining -- guarded: `scheduled_process_exited_take` fail-stops with `reap-on-owned-stack`; SIGCHLD -- irrelevant to `StackSafety`: it moves no stack and no core's current process |
| `ChildExitStart` | `kernel_process_child_exit`, `kernel_process_exit_reserved` | the same exit starting the woken parent on this core at once, only when no core owns the parent's stack | affinity -- irrelevant to `StartsOnFreeStack`: it only forbids some starts, and the model already allows each one it forbids |
| `IdleEnter` | `kernel_process_stack_idle_complete`, `kernel_process_stack_idle_blocked` | a core with no current process moves to its idle stack and releases the one it stood on | nothing |
| `Dispatch` | `kernel_process_secondary_start`, `scheduled_process_ready_take` | a core takes a Ready process whose stack no core owns, and a parent with a continuation only once the child's stack is free too | affinity -- irrelevant to `StartsOnFreeStack`: it only forbids some dispatches, and the model already allows each one it forbids |
| `Wait4Reap` | `kernel_syscall_wait4_deliver` | the parent reaps once the child's stack is free | nothing |
| `Leave` | `kernel_process_core0_leave_excluded`, `kernel_process_migrate_current`, `kernel_process_stack_idle_yield` | a running process leaves its core and the stack the core stands on is released and made Ready | why it leaves (affinity, a refused syscall, the tick) -- irrelevant to `StackSafety`: the model lets a running process leave at any step, which covers every reason |

Properties:

- `StackSafety` (#601's safety property, TLC): a core stands only on a stack
  it owns, and since `owner` names one core per stack, no stack is used by
  two cores at once.
- `RunningMatchesCores`: a Running process is some core's current process,
  on one core. The lost child violates it.
- `StartsOnFreeStack`: a core's current process has a stack no other core
  owns. The direct start of #609 violates it. Apalache's shallow check is
  given `CoreInvariants`, this and `RunningMatchesCores` together.
- `ChildReaped` (liveness, TLC only): the parent's wait4 completes.
- Deadlock freedom: TLC's own check, which the exit variant fails.

## RecordLifetime.tla -- a process record read while another CPU reaps it (#482)

One record, one reader, one reaper. The reader is a scheduler walk or an
interrupt-side wake: it holds the process-run lock, probes the record live,
lets the pool's view go, and reads through the pointer. The reaper tears down
what the exited process owned, then removes the record from the pool.

Three variants:

- `REMOVE_UNDER_LOCK = FALSE` is the kernel before #482. The removal ran
  outside the run lock, and TLC finds a read of a freed record in five
  steps: exit, probe, teardown, remove, read.
- `REMOVE_UNDER_LOCK = TRUE` is the fix, and `ReadsOnlyLiveRecords` holds.
- `READER_HOLDS_LOCK = FALSE`, with the fix in place, breaks the assumption
  the fix rests on: that a reader of another process's record holds the run
  lock from probe to read. The type system enforces the removal's half, the
  guard `scheduled_process_slot_remove` requires. It does not enforce the
  reader's half, and this variant shows the fix alone is not enough.

| Action | Kernel function it abstracts | What is kept | What is dropped, and why that is safe |
| --- | --- | --- | --- |
| `ReaderProbe`, `ReaderMiss`, `ReaderRead` | `kernel_process_secondary_start`, `kernel_process_next_ready`, `kernel_process_deadline_wake_all`, via `scheduled_process_record_at` | the probe returns a pointer and drops the pool's view; the read comes later, under the run lock the walk already holds | which walk reads and what it reads -- irrelevant to `ReadsOnlyLiveRecords`: the property depends only on whether the record was freed before the read |
| `ReaperTeardown` | `scheduled_process_reap_teardown` | frees what only the exited process owned; no lock | nothing |
| `ReaperRemove` | `scheduled_process_reap_remove`, `scheduled_process_slot_remove` | resets and removes the record, under the run-lock guard since #482 | nothing |
| `Exit` | `kernel_process_child_exit` | the process becomes a zombie | the rest of exit -- irrelevant to `ReadsOnlyLiveRecords`: only the zombie state lets a reaper start, and nothing else in exit frees the record |

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

`scripts/check_model_function_map.py` fails the build when a function or
action named in these tables no longer exists, or when a dropped entry has
none of the three forms or names something that does not exist. A rename or
removal forces the table, and a look at the model, to be updated.

## Keeping models and the kernel in step

A model and the `.tkb` code drift apart silently: nothing compiles them
together. What exists today, and what is proposed:

1. **The table above.** Each action names the functions it abstracts and
   what it deliberately leaves out. A reviewer of a change to one of those
   functions reads the row and asks whether the model's claim still holds.
2. **A build check that the named functions exist and every drop is
   justified** (in place). It catches a rename, a removal and a path left
   out with no reason, not a change of behaviour.
3. **Proposed, not built:** record a hash of each mapped function's body in
   the table, and fail when the code changes until someone re-reviews the row
   and updates the hash. That turns "the model may be stale" into a failing
   check at the moment it becomes true, at the cost of a stamp to update on
   every edit to those functions.
