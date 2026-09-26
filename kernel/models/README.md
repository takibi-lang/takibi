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

`scripts/check_model_function_map.py` fails the build when a function named
in this table no longer exists, so a rename or removal forces the table,
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
