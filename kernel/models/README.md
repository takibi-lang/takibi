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
| `Wait4Decide` | the wait4 arm of `kernel_syscall_dispatch_action` | the zombie check and the decision to block, under one hold of the run lock (#571) | the pid, the status copy and ECHILD -- irrelevant to `NoLostWakeup`: none of them changes which process is Blocked or Exited | `922161c2323b` |
| `Wait4Block` | `kernel_process_block_current`, `kernel_process_block_reserved` | successor choice and the Blocked publication in one critical section; `RECHECK` is the zombie re-check there | ASID preparation and the lock drop around it -- irrelevant to `NoLostWakeup`: the drop comes after Blocked is published and re-checked, and the successor it crosses with is already reserved Running | `a5833111b50b` |
| `ChildExit` | `kernel_process_child_exit` | the child becomes a zombie and wakes the parent only if the parent is Blocked in ChildExit | zombie draining -- irrelevant to `NoLostWakeup`: it reaps the exiting child's own children, never this parent or this child; SIGCHLD -- irrelevant to `NoLostWakeup`: it makes no process Blocked or Exited, and only such a step can break the property; the direct parent start -- modelled elsewhere: `StackOwnership.ChildExitStart` | `11cfcf76aa70` |
| `Wait4Resume` | `kernel_syscall_wait4_deliver` | the woken parent reaps | the user-memory status write -- irrelevant to `NoLostWakeup`: it runs after the reap, when the child is no longer Exited | `7eee22656d13` |
| `Preempt` | `kernel_process_timer_schedule` | the timer takes a process off its core, never inside the parent's wait4 syscall (`KERNEL_PREEMPTIBLE` is 0) | nothing | `6e9c1a975798` |
| `Dispatch` | `kernel_process_secondary_start`, `kernel_process_schedule` | an idle core takes a Ready process | affinity -- irrelevant to `NoLostWakeup`: it only forbids some dispatches, and the model already allows each one it forbids; the debugger-armed starvation injection of the busy-pair control -- irrelevant to `NoLostWakeup`: like affinity it only forbids some dispatches; stack ownership -- modelled elsewhere: `StackOwnership.Reserve` | `5991d8deb86d` |

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
| `CloneBegin` | `kernel_process_clone_begin` | the child becomes the core's current process while still Constructing; the core stands on the parent's stack | fork's fd, VM and inherited session copies -- irrelevant to `StackSafety`: they touch no kernel stack and no core's current process | `18a59219f2e9` |
| `CloneFinish` | `kernel_process_clone_context_install` | the child is Running and the parent Ready, in a later hold | nothing | `5eede8468b0e` |
| `SwitchComplete` | `kernel_process_stack_switch_complete` | the physical handoff at exception return: release the stack stood on, own the current process's | the deferred reap it runs after the release -- modelled elsewhere: `Wait4Reap` | `65c121a7b22d` |
| `Reserve` | `kernel_process_schedule`, `kernel_process_secondary_start`, `kernel_process_block_current` | a core takes a Ready process whose stack no core owns, and a parent with a continuation only once the child's stack is free too, and marks it Running before it is current | affinity -- irrelevant to `StartsOnFreeStack`: it only forbids some reservations, and the model already allows each one it forbids; the debugger-armed starvation injection of the busy-pair control -- irrelevant to `StartsOnFreeStack`: like affinity it only forbids some reservations; the unlocked ASID preparation before the commit -- irrelevant to `StackSafety`: it moves no stack, and the reserved process is Running, so no other core can take it | `e5c013957406` |
| `Commit` | `kernel_process_secondary_start_reserved`, `kernel_process_exit_reserved` | the reserved successor becomes current on a core with no running current process | Ready wait4 marker consumption -- irrelevant to `StackSafety`: it changes no physical owner, and the reservation already checked the child stack before clearing the marker | `214487a4e007` |
| `SwitchAway` | `kernel_process_schedule_reserved`, `kernel_process_block_reserved` | the reserved successor replaces a running current process, which is preempted, naps, or blocks in wait4; the core still stands on the outgoing stack, or on its IRQ stack inside an interrupt from EL0 | which child a wait4 waits for, and whether it has exited -- modelled elsewhere: `Wait4Block.Wait4Block` | `ed5db36000b3` |
| `Wait4Block` | the wait4 arm of `kernel_syscall_dispatch_action`, `kernel_process_block_to_idle` | a parent blocks before its child exits, with no successor | the #550 window -- modelled elsewhere: `Wait4Block.Wait4Decide` | `9ff189380182` |
| `Nap` | `kernel_process_block_to_idle` | a process blocks for anything but a child's exit, with no successor | what it waits for -- irrelevant to `StackSafety`: every other wait reason blocks and wakes the same way | `d514a4753153` |
| `Wake` | `kernel_process_deadline_wake_all` | a napping process becomes Ready wherever its stack is | the other wakers (UART, network, signal) -- irrelevant to `StackSafety`: each makes a Blocked process Ready and moves no stack | `bbf0e8d69dc2` |
| `ChildExit` | `kernel_process_child_exit`, `kernel_syscall_exit_current_process` | the child becomes a zombie and wakes a Blocked parent, leaving it Ready with its continuation; the core still stands on the zombie's stack | zombie draining -- guarded: `scheduled_process_exited_take` fail-stops with `reap-on-owned-stack`; SIGCHLD -- irrelevant to `StackSafety`: it moves no stack and no core's current process | `8be750a6598c` |
| `ChildExitStart` | `kernel_process_child_exit` | the same exit reserving the woken parent for this core at once, only when no core owns the parent's stack; `Commit` makes it current | affinity -- irrelevant to `StartsOnFreeStack`: it only forbids some starts, and the model already allows each one it forbids | `11cfcf76aa70` |
| `IdleEnter` | `kernel_process_stack_idle_complete`, `kernel_process_stack_idle_blocked` | a core with no current process moves to its idle stack and releases the one it stood on | nothing | `dfe9912c0db0` |
| `Wait4Reap` | `kernel_syscall_wait4_deliver` | the parent reaps once the child's stack is free | which process reaps (a deferred reap, an exiting parent's drain) -- guarded: `scheduled_process_exited_take` fail-stops with `reap-on-owned-stack` | `1ee2f13d18ee` |
| `LeaveBegin` | `kernel_process_core0_leave_excluded`, `kernel_process_migrate_current` | a running process stops being its core's current process and stays Running | why it leaves (affinity, a refused syscall, the tick) -- irrelevant to `StackSafety`: the model lets a running process leave at any step, which covers every reason | `2debf6d7809d` |
| `LeaveComplete` | `kernel_process_stack_idle_yield` | on the idle stack, the process the core stood on is made Ready and its stack released | nothing | `ce19a54c76bf` |
| `InterruptDepart` | `kernel_process_stack_interrupt_depart` | an interrupt from EL0 moves the core to its IRQ stack and releases the interrupted process's stack; the process stays current and Running, and `SwitchComplete` takes it back at the return | which interrupt it was -- irrelevant to `StackSafety`: every lower-EL IRQ enters through the same hook | `fa897c653001` |
| `TickLeave` | `kernel_process_tick_leave_excluded` | inside that interrupt, a process that may no longer run here is made Ready, its stack already free, and the core idles | why it may not run here (its mask) -- irrelevant to `StackSafety`: the model lets it leave at any interrupt | `136bd8158a72` |

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
  reader's half, and this variant shows the fix alone is not enough.
  procfs's snapshot was such a reader until #618.
- `EXEC_WRITES_UNDER_LOCK = FALSE` is execve rewriting the command line
  outside the run lock. The rewrite is then two steps, and a locked reader
  copies between them: TLC reports `NoTornRead` in three steps.

| Action | Kernel function it abstracts | What is kept | What is dropped, and why that is safe | Reviewed |
| --- | --- | --- | --- | --- |
| `ReaderProbe`, `ReaderMiss`, `ReaderRead` | `kernel_process_secondary_start`, `kernel_process_next_ready`, `kernel_process_deadline_wake_all`, `scheduled_process_diagnostic_snapshot`, `kernel_process_session_get`, via `scheduled_process_record_at` | the probe returns a pointer and drops the pool's view; the read comes later, under the run lock the reader already holds | which reader reads and what it reads besides the command line -- irrelevant to `ReadsOnlyLiveRecords`: the property depends only on whether the record was freed before the read; the monitor's `ps` and `proc`, which read with no lock -- irrelevant to `ReadsOnlyLiveRecords`: they run with every other CPU stopped, so no reap can land during the read | `201cc738b2b5` |
| `ReaperTeardown` | `scheduled_process_reap_teardown` | frees what only the exited process owned; no lock | nothing | `cb5d9162eac3` |
| `ReaperRemove` | `scheduled_process_reap_remove`, `scheduled_process_slot_remove` | resets and removes the record, under the run-lock guard since #482 | nothing | `0804bbb466af` |
| `Exit` | `kernel_process_child_exit` | the process becomes a zombie | the rest of exit -- irrelevant to `ReadsOnlyLiveRecords`: only the zombie state lets a reaper start, and nothing else in exit frees the record | `11cfcf76aa70` |
| `ExecWrite`, `ExecWriteEnd` | the execve arm of `kernel_syscall_dispatch_action`, `scheduled_process_set_command_line` | the live process's command line is replaced in one critical section under the run lock; `ExecWriteEnd` is the second half only the unfixed variant takes | the argument count, inode and pending flag written in the same hold -- irrelevant to `NoTornRead`: no reader copies them | `7f2e5c5e193d` |

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
| `WriterStart` | `kernel_log_start_line` | the count is published, then the slot's length reset and its stamp set | the tick and the core column -- irrelevant to `NoTornRead`: they are published the same way as the length and read the same way | `e522396d26e2` |
| `WriterByte` | `kernel_log_capture_uart_byte` | one byte's word, then the length that admits it | the truncated mark -- irrelevant to `NoTornRead`: it travels in the length word itself | `4cde3d847cb5` |
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
| `Submit` | `virtio_blk_submit_owned`, `msc_csw_receive_attempt`, `msc_data_receive_once`, `xhci_receive_configuration`, `usb_bulk_xfer` | preparation and submission transfer authority to the device | descriptor layout and cache instructions -- irrelevant to `UniqueAuthority`: neither can create another token | `7ae352561a66` |
| `ObserveCompletion` | `virtio_blk_submit_owned`, `msc_csw_receive_attempt`, `msc_data_receive_once`, `xhci_receive_configuration`, `usb_bulk_xfer` | an observed final completion, including a completed error, ends writes to the request buffer | completion code values -- irrelevant to `NoCpuAccessWhileDeviceMayWrite`: every final completion ends device writes to this request buffer | `7ae352561a66` |
| `Timeout` | `virtio_blk_submit_owned`, `msc_csw_receive_attempt`, `msc_data_receive_once`, `xhci_receive_configuration`, `usb_bulk_xfer` | a missing completion leaves device activity possible | timer arithmetic -- irrelevant to `NoCpuAccessWhileDeviceMayWrite`: elapsed time alone does not end device writes | `7ae352561a66` |
| `ConfirmReset` | `virtio_blk_reset`, `msc_abort_unobserved_transfer`, `xhci_halt_and_reset` | confirmed reset ends device writes | register polling details -- irrelevant to `NoCpuAccessWhileDeviceMayWrite`: this action is enabled only after quiescence is confirmed | `5303dcfa2399` |
| `ResetFailed` | `virtio_blk_reset`, `msc_abort_unobserved_transfer`, `xhci_halt_and_reset` | failure preserves possible device writes and forbids recovery | controller-specific failure codes -- irrelevant to `NoCpuAccessWhileDeviceMayWrite`: every failed reset leaves authority with the device | `5303dcfa2399` |
| `Disabled` | `virtio_blk_submit`, `disk_status` | later requests are refused while Device authority remains stored | error reporting -- irrelevant to `NoCpuAccessWhileDeviceMayWrite`: it does not touch the allocation | `78e15bcf0908` |
| `Finish` | `virtio_blk_submit_owned`, `msc_csw_receive_attempt`, `msc_data_receive_once`, `xhci_receive_configuration`, `usb_bulk_xfer` | RX finish returns CPU authority after completion or reset; the unfixed variant also permits timeout | cache instructions -- irrelevant to `UniqueAuthority`: they do not create a token | `7ae352561a66` |
| `CpuAccess` | `virtio_blk_submit_owned`, `msc_csw_receive_attempt`, `disk_read_sectors`, `usb_disk_initialize_stages`, `xhci_configure` | one CPU read or write through the protected allocation, permitted only with CPU authority | alias syntax and provenance -- irrelevant to `UniqueAuthority`: they cannot create another token, while their access safety requires the separate compiler checks | `46354a7287af` |

`UniqueAuthority` checks that the only token is either in the slot or held by
the request, including a retained Device token after reset failure.
`NoCpuAccessWhileDeviceMayWrite` checks the DMA safety property.
This model does not prove the compiler's direct/alias access rule, cache
maintenance, or the hardware reset contract; those require separate evidence.

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
