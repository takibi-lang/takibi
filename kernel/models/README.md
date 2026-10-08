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

| Action | Kernel function it abstracts | What is kept | What is dropped, and why that is safe | Reviewed |
| --- | --- | --- | --- | --- |
| `Wait4Decide` | the wait4 arm of `kernel_syscall_dispatch_action` | the zombie check and the decision to block, under one hold of the run lock (#571) | the pid, the status copy and ECHILD -- irrelevant to `NoLostWakeup`: none of them changes which process is Blocked or Exited | `452fac029ff2` |
| `Wait4Block` | `kernel_process_block_current`, `kernel_process_block_reserved` | successor choice and the Blocked publication in one critical section; `RECHECK` is the zombie re-check there | ASID preparation and the lock drop around it -- irrelevant to `NoLostWakeup`: the drop comes after Blocked is published and re-checked, and the successor it crosses with is already reserved Running | `a8ba9c669fc3` |
| `ChildExit` | `kernel_process_child_exit` | the child becomes a zombie and wakes the parent only if the parent is Blocked in ChildExit | zombie draining -- irrelevant to `NoLostWakeup`: it reaps the exiting child's own children, never this parent or this child; SIGCHLD -- irrelevant to `NoLostWakeup`: it makes no process Blocked or Exited, and only such a step can break the property; the direct parent start -- modelled elsewhere: `StackOwnership.ChildExitStart` | `e0d1e49628e4` |
| `Wait4Resume` | `kernel_syscall_wait4_deliver` | the woken parent reaps | the user-memory status write -- irrelevant to `NoLostWakeup`: it runs after the reap, when the child is no longer Exited | `85c0812b045d` |
| `Preempt` | `kernel_process_timer_schedule` | the timer takes a process off its core, never inside the parent's wait4 syscall (`KERNEL_PREEMPTIBLE` is 0) | the test-only spread rendezvous -- irrelevant to `NoLostWakeup`: it changes affinity before scheduling and observes an existing leave, without changing a wait or wake | `4504ff8d98f0` |
| `Dispatch` | `kernel_process_secondary_start`, `kernel_process_schedule` | an idle core takes a Ready process | affinity -- irrelevant to `NoLostWakeup`: it only forbids some dispatches, and the model already allows each one it forbids; the debugger-armed starvation injection of the busy-pair control -- irrelevant to `NoLostWakeup`: like affinity it only forbids some dispatches; stack ownership -- modelled elsewhere: `StackOwnership.Reserve` | `c58a40944a7a` |

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

| Action | Kernel function it abstracts | What is kept | What is dropped, and why that is safe | Reviewed |
| --- | --- | --- | --- | --- |
| `CloneBegin` | `kernel_process_clone_begin` | the child becomes the core's current process while still Constructing; the core stands on the parent's stack | fork's fd, VM and inherited session copies -- irrelevant to `StackSafety`: they touch no kernel stack and no core's current process | `8aa37a93d1a7` |
| `CloneFinish` | `kernel_process_clone_context_install` | the child is Running and the parent Ready, in a later hold | nothing | `c3436ff2e327` |
| `SwitchComplete` | `kernel_process_stack_switch_complete` | the physical handoff at exception return: release the stack stood on, own the current process's | the deferred reap it runs after the release -- modelled elsewhere: `Wait4Reap` | `876f585839f4` |
| `Reserve` | `kernel_process_schedule`, `kernel_process_secondary_start`, `kernel_process_block_current` | a core takes a Ready process whose stack no core owns, and a parent with a continuation only once the child's stack is free too, and marks it Running before it is current | affinity -- irrelevant to `StartsOnFreeStack`: it only forbids some reservations, and the model already allows each one it forbids; the debugger-armed starvation injection of the busy-pair control -- irrelevant to `StartsOnFreeStack`: like affinity it only forbids some reservations; the unlocked ASID preparation before the commit -- irrelevant to `StackSafety`: it moves no stack, and the reserved process is Running, so no other core can take it | `8db25f91f770` |
| `Commit` | `kernel_process_secondary_start_reserved`, `kernel_process_exit_reserved` | the reserved successor becomes current on a core with no running current process | Ready wait4 marker consumption -- irrelevant to `StackSafety`: it changes no physical owner, and the reservation already checked the child stack before clearing the marker | `f426ea6d85a6` |
| `SwitchAway` | `kernel_process_schedule_reserved`, `kernel_process_block_reserved` | the reserved successor replaces a running current process, which is preempted, naps, or blocks in wait4; the core still stands on the outgoing stack, or on its IRQ stack inside an interrupt from EL0 | which child a wait4 waits for, and whether it has exited -- modelled elsewhere: `Wait4Block.Wait4Block` | `fdab4558bd2c` |
| `Wait4Block` | the wait4 arm of `kernel_syscall_dispatch_action`, `kernel_process_block_to_idle` | a parent blocks before its child exits, with no successor | the #550 window -- modelled elsewhere: `Wait4Block.Wait4Decide` | `d9ba37325532` |
| `Nap` | `kernel_process_block_to_idle` | a process blocks for anything but a child's exit, with no successor | what it waits for -- irrelevant to `StackSafety`: every other wait reason blocks and wakes the same way | `951f98d886ed` |
| `Wake` | `kernel_process_deadline_wake_all` | a napping process becomes Ready wherever its stack is | the other wakers (UART, network, signal) -- irrelevant to `StackSafety`: each makes a Blocked process Ready and moves no stack | `a497ac0a9a53` |
| `ChildExit` | `kernel_process_child_exit`, `kernel_syscall_exit_current_process` | the child becomes a zombie and wakes a Blocked parent, leaving it Ready with its continuation; the core still stands on the zombie's stack | zombie draining -- guarded: `scheduled_process_exited_take` fail-stops with `reap-on-owned-stack`; SIGCHLD -- irrelevant to `StackSafety`: it moves no stack and no core's current process | `de2fb95920fb` |
| `ChildExitStart` | `kernel_process_child_exit` | the same exit reserving the woken parent for this core at once, only when no core owns the parent's stack; `Commit` makes it current | affinity -- irrelevant to `StartsOnFreeStack`: it only forbids some starts, and the model already allows each one it forbids | `e0d1e49628e4` |
| `IdleEnter` | `kernel_process_stack_idle_complete`, `kernel_process_stack_idle_blocked` | a core with no current process moves to its idle stack and releases the one it stood on | nothing | `0212e375f13a` |
| `Wait4Reap` | `kernel_syscall_wait4_deliver` | the parent reaps once the child's stack is free | which process reaps (a deferred reap, an exiting parent's drain) -- guarded: `scheduled_process_exited_take` fail-stops with `reap-on-owned-stack` | `aac051325a18` |
| `LeaveBegin` | `kernel_process_core0_leave_excluded`, `kernel_process_migrate_current` | a running process stops being its core's current process and stays Running | why it leaves (affinity, a refused syscall, the tick) -- irrelevant to `StackSafety`: the model lets a running process leave at any step, which covers every reason | `d14ffb3abaef` |
| `LeaveComplete` | `kernel_process_stack_idle_yield` | on the idle stack, the process the core stood on is made Ready and its stack released | nothing | `8dbc6a03b274` |
| `InterruptDepart` | `kernel_process_stack_interrupt_depart` | an interrupt from EL0 moves the core to its IRQ stack and releases the interrupted process's stack; the process stays current and Running, and `SwitchComplete` takes it back at the return | which interrupt it was -- irrelevant to `StackSafety`: every lower-EL IRQ enters through the same hook | `04a9f7a9734e` |
| `TickLeave` | `kernel_process_tick_leave_excluded` | inside that interrupt, a process that may no longer run here is made Ready, its stack already free, and the core idles | why it may not run here (its mask), including the spread test hook, and the hook's observation after Ready publication -- irrelevant to `StackSafety`: the model lets it leave at any interrupt, and the observation changes neither stack ownership nor process state | `287a8a966652` |

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
  exited_take, and the trace replay below, watch it.
- `ChildReaped` (liveness, TLC only): the parent's wait4 completes.
- Deadlock freedom: TLC's own check, which the exit variant fails.

### Checked against real runs

`/bin/protocol-trace` opens a window in which the kernel diffs this
model's state -- each process's state and stack owner, each core's current
process and the stack it stands on -- at every release of the run lock
(`kernel/kernel/protocol_trace.tkb`), and prints the changes when the window
closes. `scripts/validate_protocol_trace.py` replays them against these
actions, written again there with the same names, generalized to every core
and process, on every QEMU and RPi5 kernel lane. It fails on a hold no
action describes, on an action whose enabling condition does not hold, on a
broken invariant, and on a required action the window never exercised.

What a PASS claims is narrow: every transition the kernel made in that
window is one the model has. It says nothing about paths the window did not
run, and nothing about whether the model is right. What it catches is a
path the model lacks that runs routinely: #609's direct start ran on every
ordinary wait4 wake, and replaying the recorded window without
`ChildExitStart` fails on the first one.

### Checked against real runs

The protocol-trace replay of StackOwnership.tla (below) also holds its steps
to this model, using the parent pid each process line carries (#647). A
process only becomes Blocked in ChildExit while none of its children is a
zombie, which is the `RECHECK` the fix adds; a child's exit wakes exactly its
parent; and `NoLostWakeup` holds after every step. The controls plant #550's
two shapes, a block with a zombie child and an exit that wakes nobody, and
a wake of the wrong process.

Narrower than StackOwnership's tie. The "decided" window between wait4's two
critical sections is not a state the trace can see, so what is checked is
that the publication closing it re-checks, not that the window is closed.
Blocking needs the child's nap to have started before the parent reaches
wait4, which a stalled vCPU can spoil, so a window may never block a parent
and then says nothing about this model. One awaited child at a time is
assumed, as `/bin/protocol-trace` runs: a parent that waits for one pid
while another child is already a zombie would be flagged although the kernel
is right.

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
| `ReaderProbe`, `ReaderMiss`, `ReaderRead` | `kernel_process_secondary_start`, `kernel_process_next_ready`, `kernel_process_deadline_wake_all`, `scheduled_process_diagnostic_snapshot`, `kernel_process_session_get`, via `scheduled_process_record_locked` (including the snapshot under the same run lock) | the probe retains its pool view, transfers the pointer loan to the existing run guard, and releases the view; the read comes later under that same guard | which reader reads and what it reads besides the command line -- irrelevant to `ReadsOnlyLiveRecords`: the property depends only on whether the record was freed before the read; the monitor's `ps` and `proc`, which read with no lock -- irrelevant to `ReadsOnlyLiveRecords`: they run with every other CPU stopped, so no reap can land during the read | `70c1b50d55ac` |
| `ReaperTeardown` | `scheduled_process_reap_teardown` | frees what only the exited process owned; no lock | nothing | `c5b54284cd3d` |
| `ReaperRemove` | `scheduled_process_reap_remove`, `scheduled_process_slot_remove` | resets and removes the record, under the run-lock guard since #482 | nothing | `94ce0e27c389` |
| `Exit` | `kernel_process_child_exit` | the process becomes a zombie | the rest of exit -- irrelevant to `ReadsOnlyLiveRecords`: only the zombie state lets a reaper start, and nothing else in exit frees the record | `e0d1e49628e4` |
| `ExecWrite`, `ExecWriteEnd` | `syscall_execve_current`, `scheduled_process_set_command_line` | the live process's command line is replaced in one critical section under the run lock; `ExecWriteEnd` is the second half only the unfixed variant takes | the argument count, inode and pending flag written in the same hold -- irrelevant to `NoTornRead`: no reader copies them | `45cdfe350e20` |

### Checked against real runs

The same replay holds the reaper's half of this model (#647): a record is
removed only once it is Exited, and the removal is a step of its own hold of
the run lock, never made with none held (`REMOVE_UNDER_LOCK`). The controls
plant a removal with no lock held and the removal of a live record.

Much narrower than the model. The reader's half, the probe and the read
through the pointer, changes no protocol state, so nothing is recorded and a
PASS says nothing about `READER_HOLDS_LOCK`. Nor is execve's command-line
rewrite (`EXEC_WRITES_UNDER_LOCK`) observed: the record carries no image
generation. The teardown is not observed either, since it is not a change of
process state, pool membership or core.

## LogReader.tla -- the kernel log read on one CPU while core 0 appends (#612)

One writer, core 0, appends records to a ring of two slots, and publishes
the count of records it has begun. A reader on another CPU, syslog(2) on a
peer, takes no lock: it loads the count, then the record's slot length,
copies that many bytes, and loads the count again. A record whose slot was
reused in between is dropped and counted lost.

The model is sequentially consistent. That the kernel's stores and loads
keep this order on ARMv8 is argued at the top of `kernel/printk/log.tkb`:
the count is published first, every later store to a slot is a release, and
every reader load is an acquire.

Two variants:

- `SECOND_CHECK = TRUE` is the kernel, and `NoTornRead` holds.
- `SECOND_CHECK = FALSE` skips the second load of the count. TLC reports
  `NoTornRead` in thirteen steps: the reader copies a record while the
  writer wraps round and overwrites it.

The first version had the reader copy whole slots, without the length. TLC
found the record just begun still holding the bytes of the record it
replaces. They were copied as the new record, and since nothing had been
reused, the check passed them.

| Action | Kernel function it abstracts | What is kept | What is dropped, and why that is safe | Reviewed |
| --- | --- | --- | --- | --- |
| `WriterStart` | `kernel_log_start_line` | the count is published, then the slot's length reset and its stamp set | the tick and the core column -- irrelevant to `NoTornRead`: they are published the same way as the length and read the same way | `c18fa6bf1368` |
| `WriterByte` | `kernel_log_capture_retained_byte` | one byte's word, then the length that admits it | the truncated mark -- irrelevant to `NoTornRead`: it travels in the length word itself; console locking -- irrelevant to `NoTornRead`: only the writer takes it and the reader still observes the separate release stores | `7257f536df64` |
| `ReaderBegin`, `ReaderLength`, `ReaderByte`, `ReaderCopied`, `ReaderCheck`, `ReaderAgain` | `kernel_log_snapshot_build`, `kernel_log_snapshot_record` | the count, the stamp and the length, the byte copies, the second count, and dropping a reused record | the snapshot's headers and timestamp formatting -- irrelevant to `NoTornRead`: they are derived from the fields copied, not further reads of the ring | `0fbed2bd1511` |

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

## FixedDmaOwnership.tla -- a fixed receive allocation across DMA (#596)

One allocation and one explicit linear authority. A guarded stable-slot
exchange gives the CPU token to a synchronous request. Submission turns it
into a DMA token. An observed completion, including a completed error, or a
confirmed reset allows recovery; an unobserved timeout does not. A failed
reset leaves Device authority in the slot and no CPU access can follow. The
unfixed variant permits recovery on timeout and reaches a CPU access while
the device may still write.

| Action | Kernel function it abstracts | What is kept | What is dropped, and why that is safe | Reviewed |
| --- | --- | --- | --- | --- |
| `TakeCpu`, `PutCpu`, `PutDma` | the guarded exchanges in `virtio_blk_receive_take`, `virtio_blk_receive_put`, `msc_csw_take`, `msc_csw_put`, `msc_data_take`, `msc_data_put`, `xhci_control_take`, and `xhci_control_put` | one serialized slot exchange and unique token storage, including a Device token stored after failed reset | lock instructions -- irrelevant to `UniqueAuthority`: the action assumes the exchange is serialized, which the driver lock must establish; buffer bytes -- irrelevant to `UniqueAuthority`: they hold no authority | `841b505738cf` |
| `Submit` | `virtio_blk_submit_owned`, `msc_csw_receive_attempt`, `msc_data_receive_once`, `xhci_receive_configuration`, `usb_bulk_xfer`, `usb_bulk_in`, `usb_ctrl_in` | preparation and submission transfer authority to the device | descriptor layout and cache instructions -- irrelevant to `UniqueAuthority`: neither can create another token; the device span -- irrelevant to `UniqueAuthority`: it only bounds which bytes the device may write | `c85423599f90` |
| `ObserveCompletion` | `virtio_blk_submit_owned`, `msc_csw_receive_attempt`, `msc_data_receive_once`, `xhci_receive_configuration`, `usb_bulk_xfer` | an observed final completion, including a completed error, ends writes to the request buffer | completion code values -- irrelevant to `NoCpuAccessWhileDeviceMayWrite`: every final completion ends device writes to this request buffer | `31a4a0b675d7` |
| `Timeout` | `virtio_blk_submit_owned`, `msc_csw_receive_attempt`, `msc_data_receive_once`, `xhci_receive_configuration`, `usb_bulk_xfer` | a missing completion leaves device activity possible | timer arithmetic -- irrelevant to `NoCpuAccessWhileDeviceMayWrite`: elapsed time alone does not end device writes | `31a4a0b675d7` |
| `ConfirmReset` | `virtio_blk_reset`, `msc_abort_unobserved_transfer`, `xhci_halt_and_reset` | confirmed reset ends device writes | register polling details -- irrelevant to `NoCpuAccessWhileDeviceMayWrite`: this action is enabled only after quiescence is confirmed | `5303dcfa2399` |
| `ResetFailed` | `virtio_blk_reset`, `msc_abort_unobserved_transfer`, `xhci_halt_and_reset` | failure preserves possible device writes and forbids recovery | controller-specific failure codes -- irrelevant to `NoCpuAccessWhileDeviceMayWrite`: every failed reset leaves authority with the device | `5303dcfa2399` |
| `Disabled` | `virtio_blk_submit`, `disk_status` | later requests are refused while Device authority remains stored | error reporting -- irrelevant to `NoCpuAccessWhileDeviceMayWrite`: it does not touch the allocation | `f5b58d30075c` |
| `Finish` | `virtio_blk_submit_owned`, `msc_csw_receive_attempt`, `msc_data_receive_once`, `xhci_receive_configuration`, `usb_bulk_xfer` | RX finish returns CPU authority after completion or reset; the unfixed variant also permits timeout | cache instructions -- irrelevant to `UniqueAuthority`: they do not create a token | `31a4a0b675d7` |
| `CpuAccess` | `virtio_blk_submit_owned`, `msc_csw_receive_attempt`, `disk_read_sectors`, `usb_disk_initialize_stages`, `xhci_configure` | one CPU read or write through the protected allocation, permitted only with CPU authority | alias syntax and provenance -- irrelevant to `UniqueAuthority`: they cannot create another token, while their access safety requires the separate compiler checks | `26ecc059b80a` |

`UniqueAuthority` checks that the only token is either in the slot or held by
the request, including a retained Device token after reset failure.
`NoCpuAccessWhileDeviceMayWrite` checks the DMA safety property.
This model does not prove the compiler's direct/alias access rule, cache
maintenance, or the hardware reset contract; those require separate evidence.

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

| Action | Kernel function it abstracts | What is kept | What is dropped, and why that is safe | Reviewed |
| --- | --- | --- | --- | --- |
| `WriterEnter` | `syscall_write_segment` | a terminal write is admitted whole under the run lock | fd lookup and the user-memory copy -- irrelevant to `ProgramOrder`: they run before the chunk is admitted and change no queue or lock | `bdce608d46fb` |
| `WriterAppend` | `uart_user_write`, `uart_terminal_write_chunk`, `uart_user_write_locked`, `uart_user_write_room_locked`, `syscall_write_segment`, `kernel_log_peer_record_emit`, `kernel_log_peer_record_byte_locked`, `console_lock`, `console_unlock`, `mutex_acquire_measured` | the append to the queue under the console lock, or the decision that there is no room; on every CPU the same queue, and the run lock let go | short counts and partial chunks -- irrelevant to `ProgramOrder`: a partial chunk is a shorter chunk, and the model already appends each whole; nonterminal fd paths -- irrelevant to `ProgramOrder`: they do not append terminal bytes; peer diagnostic bytes -- irrelevant to `ProgramOrder`: they share the FIFO order without changing a terminal writer's chunk order; measurement counters -- irrelevant to `ProgramOrder`: they are updated under the same lock and never select queue contents, admission or ownership | `519d647caabe` |
| `BlockWriter` | `kernel_process_block_uart_tx` | the writer publishes itself asleep under the run lock; `RECHECK` is the room re-check there | successor choice and the switch -- modelled elsewhere: `Wait4Block.Wait4Block` | `626ecddbdacc` |
| `TxTake` | `uart_tx_service`, `uart_tx_drain_into_fifo` | one chunk leaves the queue onto the wire under the console lock and makes room; `NESTED` keeps the lock | the FIFO's capacity and the byte-by-byte drain -- irrelevant to `ProgramOrder`: bytes leave the queue in order, so a chunk taken whole is the same order | `c682c0a9957c` |
| `TxWake` | `kernel_process_uart_tx_wake_all` | under the run lock, a writer asleep on room becomes runnable | which other processes wait on UartTx -- irrelevant to `NoLostWakeup`: the model has one writer, and each waiter is woken by the same scan | `32be155fdd7c` |
| `Drain` | Retired terminal ring; negative variant only | the former route delays peer chunks independently of the shared queue | the retired implementation -- irrelevant to `ProgramOrder`: this action is reachable only in the unfixed variant and remains its negative control | `e3b0c44298fc` |
| `Migrate` | `kernel_process_timer_schedule` | the process changes CPU between writes, never inside one (`KERNEL_PREEMPTIBLE` is 0) | affinity -- irrelevant to `ProgramOrder`: it only forbids some moves, and the model already allows each one it forbids | `4504ff8d98f0` |

Where the kernel stands against the model: terminal writers on every CPU,
the shared queue and FIFO drain use the console lock, with order run -> console.
The TX interrupt (`uart_tx_service`) releases it before the wake. Writer-room
rechecks also take the console lock. The maintained terminal follows
`LOCKED = TRUE`, `RECHECK = TRUE`, `NESTED = FALSE`. The terminal ring and
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
claim follows from this model. Physical holding, firmware status truthfulness,
ARM ordering, interrupt decoding and raw mint correctness remain trusted.
The model treats owner-side reads as indivisible and does not model owner IRQ
mutation. The implementation now saves and masks owner IRQs before claiming
the gate, retaining that exclusion in full/partial stop and CPU-start guards.
Compiler tests reject IRQ re-enablement while those guards or derived pool
views remain live; this is separate evidence from the bounded model.

| Action | Kernel function it abstracts | What is kept | What is dropped, and why that is safe | Reviewed |
| --- | --- | --- | --- | --- |
| `StartReserve` | `cpu_start_reserve` | claim before adding the possible target, sharing the stop gate | exact bit encoding -- irrelevant to `NoUnstoppedRead`: the set is the mask's membership relation | `06a8d157cda7` |
| `StartFirmware`, `CpuArrive` | `qemu_psci_cpu_on`, `rpi5_psci_cpu_on`, `kernel_secondary_main` | reserved target can execute before or after the firmware call returns | entry assembly and PSCI encoding -- irrelevant to `NoUnstoppedRead`: a CPU may arrive at any step after reservation | `4fc98849f791` |
| `StartFinish`, `StartAbsent` | `cpu_start_finish`, `cpu_start_gate_release` | uncertain targets stay possible; only definitive absence removes a new reservation before releasing the gate | scheduler's contiguous online prefix -- irrelevant to `NoUnstoppedRead`: the full stop uses the independent possible-participant mask | `c7ad7be29562` |
| `Claim`, `Publish` | `world_stop_claim`, `world_stop_begin_claimed`, `world_stop_machine_begin` | one initiator; set capture under the gate; fresh request generation | generation exhaustion -- irrelevant to `NoUnstoppedRead`: two generations are never reused and exhaustion only refuses another request; subset probe API -- irrelevant to `NoUnstoppedRead`: its distinct WorldStopped type cannot enter a whole-machine reader | `e18a66a33afb` |
| `Ack`, `PenExit`, `ToggleIrq` | `world_stop_hold`, `kernel_world_stop_serve`, `kernel_ddb_stopped_root_publish`, `kernel_ddb_stopped_root_retire` | ack current request only after entering the pen; exit only when request changes; masked IRQs can delay ack | physical instruction timing -- irrelevant to `NoUnstoppedRead`: arbitrary scheduling allows every delay; stopped-root sequence parity -- irrelevant to `NoUnstoppedRead`: an unsettled root is refused, while the repeated real-stop fixture checks usable publication separately | `63e3d5eea895` |
| `Complete`, `Timeout` | `world_stop_begin_claimed` | all captured targets must ack the current generation; timeout yields no complete authority | spin count -- irrelevant to `NoUnstoppedRead`: timeout may happen at any waiting step | `4912d7384d61` |
| `Release` | `world_stop_resume`, `machine_stop_release`, `machine_stop_partial_release` | end the local authority before clearing request and releasing claim, then restore saved initiator IRQs | terminal keep-forever -- irrelevant to `NoUnstoppedRead`: it never resumes or releases the gate | `df9505f592f5` |
| `Read` | `kernel_process_ddb_copy`, `kernel_ddb_enter_stopped`, `machine_pool_probe`, `machine_pool_payload`, `scheduled_process_record_stopped`, `scheduled_process_slot_remove`, `address_space_inspect_stopped`, `fd_context_inspect_stopped`, `fd_block_inspect_stopped`, `kernel_fd_table_stopped_entry`, `process_image_inspect_stopped`, `scheduled_process_diagnostic_copy`, `crash_snapshot_shared_stopped`, `crash_console_dispatch_stopped` | inspection requires the borrowed machine authority; scoped pool loans cannot cross resume or slot destruction | pool metadata Busy/Stale refusals and which record fields and memory commands are inspected -- irrelevant to `NoUnstoppedRead`: every successful inspection is gated by the same machine authority, while metadata consistency is a separate trusted mint condition checked before inspection | `d80cfb1cfb90` |

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
   the bodies of the functions the row maps and of the guards its dropped
   paths name, comments and whitespace stripped. Any change to that code
   fails the build until someone re-reads the row against the model and runs
   `python3 scripts/check_model_function_map.py --restamp`; the commit that
   restamps says what was reviewed. A comment-only edit keeps the stamp. The
   stamp says only "look again", not what is wrong, and it fires whether or
   not any test exercises the change.
