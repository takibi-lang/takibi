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
  minutes. Leave out what the property does not depend on, and say so in the
  action table's "dropped" column rather than silently.
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

| Action | Kernel function it abstracts | What is kept, what is dropped |
| --- | --- | --- |
| `Wait4Decide` | the wait4 arm of `kernel_syscall_dispatch_action` | the zombie check and the decision to block, under one hold of the run lock (#571); the pid, the status copy and ECHILD are dropped |
| `Wait4Block` | `kernel_process_block_current`, `kernel_process_block_reserved` | successor choice and the Blocked publication in one critical section; `RECHECK` is the proposed zombie re-check there; ASID preparation and the lock drop around it are dropped |
| `ChildExit` | `kernel_process_child_exit` | the child becomes a zombie and wakes the parent only if the parent is Blocked in ChildExit; zombie draining, SIGCHLD and the direct parent start are dropped |
| `Wait4Resume` | `kernel_syscall_wait4_deliver` | the woken parent reaps; the user-memory status write is dropped |
| `Preempt` | `kernel_process_timer_schedule` | the timer takes a process off its core, never inside the parent's wait4 syscall (`KERNEL_PREEMPTIBLE` is 0) |
| `Dispatch` | `kernel_process_secondary_start`, `kernel_process_schedule` | an idle core takes a Ready process; affinity and stack ownership are dropped here and belong to the next slice |

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

Two constants re-introduce the two past defects #601 asked the model to
find. Each is one variant, and `make modelcheck` requires both to fail:

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

| Action | Kernel function it abstracts | What is kept, what is dropped |
| --- | --- | --- |
| `Clone` | `kernel_process_clone_begin`, `kernel_syscall_clone_child_return` | the child's first return runs first, on its parent's stack; fork's fd and VM copies are dropped |
| `SwitchComplete` | `kernel_process_stack_switch_complete` | the physical handoff at exception return: release the stack stood on, own the current process's |
| `Wait4Block` | the wait4 arm of `kernel_syscall_dispatch_action`, `kernel_process_block_current` | a parent blocks before its child exits, with no successor; the #550 window is Wait4Block.tla's, not this model's |
| `ChildExit` | `kernel_process_child_exit`, `kernel_syscall_exit_current_process` | the child becomes a zombie and wakes a Blocked parent, leaving it Ready with its continuation; the core still stands on the zombie's stack |
| `IdleEnter` | `kernel_process_stack_idle_complete`, `kernel_process_stack_idle_blocked` | a core with no current process moves to its idle stack and releases the one it stood on |
| `Dispatch` | `kernel_process_secondary_start`, `scheduled_process_ready_take` | a core takes a Ready process whose stack no core owns, and a parent with a continuation only once the child's stack is free too; affinity is dropped |
| `Wait4Reap` | `kernel_syscall_wait4_deliver` | the parent reaps once the child's stack is free |
| `Leave` | `kernel_process_core0_leave_excluded`, `kernel_process_migrate_current`, `kernel_process_stack_idle_yield` | a running process leaves its core and the stack the core stands on is released and made Ready; why it leaves (affinity, a refused syscall, the tick) is dropped |

Properties:

- `StackSafety` (#601's safety property, TLC): a core stands only on a stack
  it owns, and since `owner` names one core per stack, no stack is used by
  two cores at once.
- `RunningMatchesCores`: a Running process is some core's current process,
  on one core. The lost child violates it.
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

| Action | Kernel function it abstracts | What is kept, what is dropped |
| --- | --- | --- |
| `ReaderProbe`, `ReaderMiss`, `ReaderRead` | `kernel_process_secondary_start`, `kernel_process_next_ready`, `kernel_process_deadline_wake_all`, via `scheduled_process_record_at` | the probe returns a pointer and drops the pool's view; the read comes later, under the run lock the walk already holds |
| `ReaperTeardown` | `scheduled_process_reap_teardown` | frees what only the exited process owned; no lock |
| `ReaperRemove` | `scheduled_process_reap_remove`, `scheduled_process_slot_remove` | resets and removes the record, under the run-lock guard since #482 |
| `Exit` | `kernel_process_child_exit` | the process becomes a zombie; the rest of exit is dropped |

`scripts/check_model_function_map.py` fails the build when a function named
in these tables no longer exists, so a rename or removal forces the table,
and a look at the model, to be updated.

## Keeping models and the kernel in step

A model and the `.tkb` code drift apart silently: nothing compiles them
together. What exists today, and what is proposed:

1. **The table above.** Each action names the functions it abstracts and
   what it deliberately leaves out. A reviewer of a change to one of those
   functions reads the row and asks whether the model's claim still holds.
2. **A build check that the named functions exist** (in place). It catches a
   rename or a removal, not a change of behaviour.
3. **Proposed, not built:** record a hash of each mapped function's body in
   the table, and fail when the code changes until someone re-reviews the row
   and updates the hash. That turns "the model may be stale" into a failing
   check at the moment it becomes true, at the cost of a stamp to update on
   every edit to those functions.
