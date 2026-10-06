# Kernel concurrency

Authoritative for how this kernel synchronizes today, what each mechanism is
for, and which questions to ask before adding another one. Historical
narrative for any single decision belongs in `HISTORY.md`; this file states
current behavior and must be correct without reading it.

## Where the kernel stands

`kernel/lib/execution_model.tkb` holds two numbers, and most unsynchronized
state in this kernel is safe *because of* them:

- `KERNEL_ACTIVE_CORES` -- maximum cores the scheduler admits; it is 4. The
  runtime online prefix is 2 in maintained QEMU lanes and 4 on RPi5. Every
  online core takes timer interrupts and enters the syscall and scheduler
  paths. A process with no affinity mask is eligible on every online core;
  a peer syscall runs where it was called unless `syscall_peer_refused`
  names it (GitHub issue #583; since #612 only the payload fixture's
  parent report, with its reason) or `syscall_peer_safe` narrows it by
  descriptor; those are rerun on core 0. syslog reads the retained log on
  any CPU with no lock: core 0 publishes each record with release stores,
  and a reader drops and counts a record reused while it copied
  (`kernel/models/LogReader.tla`). The busy-pair fixture pins its workers during the
  staged boot checks, then widens them for the measured phase and alternates
  explicit CPU 0/1 affinity requests to observe actual migrations. The
  filesystem boundary is now a LOCK rather than an
  admission claim -- ext2 mutation excludes itself through
  `kernel/fs/ext2/mutation_lock.tkb`, and a reader that finds a mutation
  in flight is rerun: on core 0 from a peer, after an interrupt on core 0
  (GitHub issues #533 and #9). mkdirat, unlinkat and renameat run on any
  core since #597: each takes the guard before its path lookup, and a
  mutation waits for every CPU's counted readers, including a child
  execve's until its exec prepare has read the image.
  A `write` to an ext2 file runs on any core since #602: it reads the file
  position, checks its bound, writes, and advances the position all under
  the guard, so two writers sharing one open file serialize. A reader's
  position update is not under the guard: a `read` and a `write` through
  one shared open file on two CPUs can still race the position word, as
  two readers could before.
- `KERNEL_PREEMPTIBLE` -- 0. A timer interrupt taken at EL1 sets a flag and the
  switch happens at syscall return. That is `CONFIG_PREEMPT_NONE`, and it is
  why many field accesses need no lock.

Raising either prints a worklist: files assert the constant they depend on
with a per-site message. `scripts/check_execution_model_coverage.py` requires
every file with a mutable global to name a constant or appear in its exempt
list with a reason, because two files that depended on the core count without
saying so were each found by accident.

An assertion message is prose and nothing checks it stays true. Three went
stale within days of their subject being fixed. Re-read the assertion when you
change what it is about.

## Exec argument handoff

A child's exec reserves its argv page before committing to ChildExec. The
linear PageOwner crosses the assembly action boundary through a stable slot
for the executing CPU; exec is admitted on every active CPU. Each slot has
its own mutex and owner field, and the compile-time stable-place check ties
an exchange to that same slot's guard. The slots' distinct identities are
also exercised by a boot probe that holds all CPU reservations simultaneously
and checks every page and emptied slot. This is regression evidence rather
than a static proof that an arbitrary handoff layout separates CPUs.

Reserve and prepare are one non-preemptible EL1 action. Prepare takes the
page before returning to EL0, so the process cannot migrate while the page
remains in the slot. KERNEL_PREEMPTIBLE == 0 is asserted for this contract as
well as the existing per-core syscall scratch. Enabling kernel preemption
requires revisiting both contracts.

## Clone publication

A new clone stays `Constructing` while its VM, descriptors and copied frame
are installed. Neither a Ready claim nor the successor walk may select it.
The install transition consumes that state into Running under the run lock;
the parent's saved frame is stored before the same section makes it Ready.
Cancellation consumes Constructing directly into Exited. These are logical
publication boundaries, not proof that the old CPU has left a process stack.
Rollback validates the still-Running parent and its child-list head under the
run lock, restores that head to the cancelled child's next sibling, and only
then reaps the cancelled record. Older live children and zombies remain linked.

## Core 0's idle context

Core 0 idles on `core0_idle_stack_*` (GitHub issue #592), not on its boot
stack, which still holds `main()`'s suspended frames. It goes there only
from a syscall return that found no other process core 0 may run while the
returning process's affinity excludes core 0, and only when core 0 stands
on that process's own kernel stack -- a clone child's first return still
stands on its parent's. The hand-off is the peers' ordering: publish no
current process, move SP off the process stack, then make the process
Ready with its stack unowned under the run lock. The idle loop takes a Ready
process core 0 may run, PID 1 (slot 0) included: once peer dispatch is
enabled, just before `run_initial_user`, a Ready PID 1 always has a saved
EL0 frame, and skipping it left init Ready and never run whenever its child
exited on a peer. An exit with no
successor idles the same way (the exited process's stack is released by
`kernel_process_stack_idle_complete`), and so does a wait: a block with no
Ready successor publishes Blocked under the run lock, after the same last
looks a switching block takes (`kernel_process_block_would_miss`), and the
CPU idles; the stack is released by `kernel_process_stack_idle_blocked`,
and until then `scheduled_process_ready_take` will not start the process
even if a wake has made it Ready (GitHub issue #583). wait4's ChildExit
blocks this way too since #550.

A child's exit that wakes its parent may start the parent at once, on the
exiting CPU, without passing through `scheduled_process_ready_take`. Since
wait4 runs on a peer (GitHub issue #609) that parent may have blocked on
another CPU that still stands on its stack, so the direct start checks the
stack's owner itself and otherwise leaves the parent Ready with its wait4
rewound. `scheduled_process_start`, which every start passes, fail-stops
with activity `start-on-owned-stack` if any path starts a process on a
stack another CPU owns (`StartsOnFreeStack` in
`kernel/models/StackOwnership.tla`). A zombie is likewise not collectable
while the CPU that ran its exit still stands on its stack: the zombie
searches skip it, and wait4 waits for an interrupt and asks again;
`scheduled_process_exited_take`, which every reap passes, fail-stops with
activity `reap-on-owned-stack` if a path does not.

`kernel_process_block_would_miss` is where every wait reason answers the
decide-then-sleep question (GitHub issue #550): a wait decides in one
critical section and publishes Blocked in a later one, so an event can
arrive between them and find no Blocked waiter. Each reason either
re-checks its event there, under the lock its waker takes -- UartRx,
UartTx, ChildExit (the awaited child, by the pid wait4 recorded), Signal --
or names what delivers the event again: core 0's tick wakes every NetRx
waiter and every waiter whose deadline has passed. The function is one
`match` with no default arm, so a wait reason added later does not compile
until its answer is written there. `kernel/models/Wait4Block.tla` checks
the ChildExit re-check.

A timer tick taken from EL0 idles a CPU too, on any core, when the
interrupted process's mask no longer names that CPU and nothing else Ready
may run there (GitHub issue #582). The ordering is the same, but the entry
has already done its first two steps: the lower-EL IRQ entry runs its
handler on the IRQ stack and has released the process's stack
(`kernel_process_stack_interrupt_depart`). The handler therefore publishes
no current process and makes the process Ready under the run lock. It
acknowledges the interrupt, and only then leaves the IRQ stack for the
idle loop (`kernel_timer_tick_leave`).

## State transitions and the run guard

The spread fixture observes the timer's no-successor leave through a
test-only rendezvous. Its parent stays on CPU 1 and arms its Ready child
under the run guard, publishing the child's CPU 0 mask in the same section.
The next lower-EL timer for that exact child's generation on CPU 0 changes
the mask to CPU 1. Only the successful tick leave, after publishing Ready,
records completion. Parent polling checks both generation-bearing handles
under the same guard; it permits wait4 only after that observation. Fixed
sleep durations and ordinary syscall migration cannot establish success.
The child's arithmetic is finite, and polling has a failure watchdog.
Premature polls, non-child requests, wrong-CPU requests and repeated arming
are refused. The observation is idempotent, and a completed rendezvous can
be reused only after its previous child's handle becomes stale.

This is runtime evidence, not a static proof of timer progress. The trusted
points are the timer's entry/leave hooks and the private run-guard-protected
rendezvous state. Both platforms exercise the shared implementation. The
QEMU negative control removes the actual tick leave and requires the
fixture's missing-ToIdle diagnosis even if a later syscall migrates the child.

Every take that mints a process's linear state -- Ready, Running,
Blocked, Exited -- borrows the process-run guard (GitHub issue #589), so a
transition out of any of them without the lock is a compile error. The
Blocked take was the gap #587's three unlocked interrupt-side wakes went
through. Code that must run the real transition without the lock does so
only by forging a guard with `process_run_guard_forge_unlocked`, which is
`unsafe` and counted in the trusted base: the two-core probes, and the
`#587` negative control that `scripts/build_qemu_net_wake_control.py`
builds. `kernel_process_reap_zombie` takes the lock for the child-list
unlink and the Exited take only; the teardown after it runs outside,
because a world stop reached from there needs peers able to acknowledge
it.

## ProcessRecord pointer lifetimes

Ordinary record pointers borrow the process-run guard, the scheduled owner, or
Running evidence. The owner and Running paths need no additional run lock or
pin. These authority indices have different meanings (generation, slot, lock
address); they are not proof of different physical records.

`scheduled_process_slot_remove` declares
`record_mutates_ProcessRunGuard`; `scheduled_process_reap_remove` declares
`record_mutates_ScheduledProcessOwner`. The compiler rejects a live record loan
at either boundary, including through helpers or another authority kind. End
the pointer's lexical scope before destruction. Scalar snapshots can survive.
This catches removal by the same lock holder as well as use after unlock.

The owner lookup validates the indexed allocation generation under the
existing pool lock and uses a private `loan_transfer` before releasing its
pool view. Its returned loan remains tied to the owner. The pool generation
is preserved into the creating owner's index rather than copied through an
unindexed mutable temporary. Run-lock and current-process accessors retain
that same locked pool proof in a private indexed wrapper, transfer its loan
to the existing guard or erased current view, then consume the wrapper.
There is no bare production lookup; only the diagnostic peek drops its proof.
The current lookup uses a generation-checked probe under the pool lock.
The private wrapper mint associates that probe with the borrowed lifetime
authority; that allocation/domain association remains reviewed trust.
The run lock excludes peer removal, ownership excludes removal without consuming
that owner, and Running processes cannot be reaped. This is not a proof of the
scheduler/allocator or a reason to remove field locks. Kernel preemption must
revisit whether Running authority can survive suspension and migration.

The destructive-loan contracts add no instruction or lock section. Owner
lookup keeps one existing pool acquire/release and adds the expected-generation
comparison; there is no extra run lock or pin. This does not reduce existing
run-lock contention. Unlocked retained
readers without these authorities would need a separate reclamation protocol.

## Signal words

`pending_signals` and `signal_mask` are read-modify-written by a sender on
whichever CPU it runs on and by the target on its own (GitHub issue #570).
Outside a record's construction and teardown every access holds the
process-run lock: raising and clearing go through
`process_signal_pending_raise` and `process_signal_pending_clear`, which
take its guard, and delivery takes the guard its caller holds -- the exit
path's own, or `kill`'s, taken around the delivery only. Nothing delivery
calls takes that lock again. `kernel/kernel/signal_contention_evidence.tkb`
shows the lost update with a forged guard and none under the lock.
Reporters (DDB, the oops) read the words without it, as reporters do.

## Connected sockets on a peer

`read` and `write` on a connected TCP descriptor are admitted on any CPU
(GitHub issue #581), and so is the rest of the socket group since #598;
the inetd response mode is not. Every `TcpConnection` field those two calls read or
write is accessed under the connection's owner: `tcp_connection_take` takes
the connection's `TaskMutex` and revalidates the pool generation after the
acquire, and the open check happens after that, not before. Receive and
transmit additionally hold the sole network capability, which is behind a
`Mutex`, so two connections serialize there. Poll's pending-read probe takes
no connection lock on purpose -- it must not wait behind a receive -- and the
read that follows re-decides open and available bytes under the owner.

The rest of the group, and what each relies on (GitHub issue #598):

- **Closing a connected descriptor** -- `close`, `dup3` over one, and an
  exiting process's reap -- goes through `kernel_connected_descriptor_close`.
  It takes the connection's owner first, then reads the object's reference
  count, then closes the transport if this is the last reference, and
  clears the descriptor before giving the owner back. Two holders closing
  on two CPUs therefore serialize, and exactly one of them closes the
  transport. The count cannot rise under the owner, because only a holder
  can duplicate a descriptor. Before #598 the count was read before the
  owner was taken, and a peer exit's reap could race a close on core 0.
- **`shutdown`** closes the transport under the owner, as the connected
  write does. A holder that closes afterwards finds the connection gone
  and only clears its descriptor.
- **`bind`, `listen`, `accept`, `accept4`** run while holding the
  listener's claim (`unified_listener_claim` in
  `kernel/kernel/fd_table.tkb`): one call at a time per listener, for one
  syscall and never across a Block. A second CPU that finds the claim held
  waits for an interrupt and reruns. The claim covers the listener's port,
  its state and the pending handshake, which two processes sharing a
  listener through fork would otherwise interleave on. An accepted
  connection's open flag and buffer position are written under its owner
  before it is published.
- **`socket`** allocates a descriptor in the caller's own table and an
  object from the pool, whose lock covers the allocation.
- **`getpeername`, `setsockopt`** touch only the caller's memory.
- **`sendfile`** is an ext2 reader (counted at syscall entry, as `read` is).
  It writes through `uart_user_write`, the queue `write(1)` uses, which is shared by all CPUs under the console lock. It advances the file position only by the bytes
  the queue took.
- The socket evidence counters in
  `kernel/kernel/syscall_test_evidence.tkb`, and the listener-ready flag in
  `syscall_test_lifecycle.tkb`, are read and written under the process-run
  lock, since the fixture's own calls may now run on any CPU.

## Lock classes

Two, and the distinction is which contexts may take them.

- `Mutex` (`kernel/lib/mutex.tkb`) masks interrupts around a spinlock, so it is
  safe from both thread and interrupt context -- Linux's `spin_lock_irqsave`.
  Allocator-class locks are this, not because the mask is needed but because of
  NESTING: a pool lock is held across `page_alloc_contiguous`, so interrupts are
  already masked when the inner lock is taken, and taking a sleeping lock under
  a mask is the shape that hangs.
- `TaskMutex` (`kernel/lib/task_mutex.tkb`) does not mask. It exists for a lock
  held across a user copy or a frame transmit, where masking for the duration
  would bound interrupt latency by the longest such operation.

A global `Mutex` needs no `mutex_init`: `.bss` is zeroed by both entry paths
and a zeroed word is free. Calling `mutex_init` on one is worse than
redundant, because it FORCE-FREES -- on two cores it releases a lock somebody
else holds. `scripts/check_lock_discipline.py` makes that a build failure, and
also holds the allowlist of files permitted to use raw atomic intrinsics.

## Lock order

`run -> fd -> pool -> page`, with `asid` a leaf. The scheduler's lock is the
outermost. Nothing takes an outer lock while holding an inner one.

The console lock (`kernel/printk/console_lock.tkb`, GitHub issue #663) sits
inside the run lock: whole output chunks are admitted, and the receive handler
echoes, under the run guard, and nothing is taken while the console lock is
held. The transmit interrupt lets go of it before it takes the run lock for
its wake; keeping it across the wake is the deadlock `kernel/models/ConsoleTx.tla`
finds (the NESTED variant). Nothing under it logs, since a Mutex has no owner
and a log call would take it again.

Two locks carry a RANK the compiler checks, rather than an order held by
convention (GitHub issue #466): `ext2_mutation` at 20 and `block_device` at
30, so a filesystem mutation may take the device lock underneath it and the
reverse is a type error. `kernel/fs/ext2/mutation_lock.tkb` is the outer one
and states why readers do not take it at all.

This order is held by how the functions happen to be written; no checker
enforces it in the kernel. `linux_user/intrusive_pool/pool_lock_check.tkb`
checks order between POOL locks only, in the tier that can afford to look, and
its table is finite -- which is why a lock that is not a pool's must use
`mutex_acquire` directly rather than `pool_lock_acquire`, whose tag registers
an entry and pushed real acquires out as untracked once.

## Before adding a lock

1. **Ask whether it is shared at all.** Three of eight candidates were per-core
   state stored as though global; a lock would have made two cores agree on
   something that should have two answers. `execution_here()` and the per-core
   address-space slot are the shape that replaced them.
2. **The MMU-off window cannot lock.** `spin_lock` is `!{requires_mmu}` because
   AArch64 has no exclusives on Device-typed memory, and everything is Device
   until the MMU is on. Locking a boot-reachable subsystem is a build error
   naming the call chain. Give that window a `_boot` entry point; it is correct
   as well as forced, since it runs before PSCI has started a second core.
3. **Put the lock in its own global, never as a field of an `align(16)`
   aggregate.** An 8-byte field at the front shifts every array behind it to
   8-mod-16 and LLVM may then emit a 128-bit store the MMU-off window cannot
   use. A container whose VALUE is the first field is safe, because it inherits
   the payload's alignment.
4. **A lock without a probe is not done.** A lock added correct-by-audit
   changed nothing any lane could see, because the second core never reached
   the subsystem. See "Two-core probes" below.

## Binding a lock to what it protects

A comment saying "this lock protects that global" is not checkable, and on one
core it is true and unfalsifiable in the same breath. Two mechanisms make it a
type:

- `LockedCell(T)` (`kernel/lib/locked_cell.tkb`) -- one value beside one lock.
  The value is a private field of a struct declared in that file, so no other
  file can name it; the only accessor needs `borrow LockedCellGuard[id]`, and
  the pointer it returns dies with the guard.
- `GuardedUsize` plus `GuardedFieldGuard` -- one lock covering a field of every
  object in a pool, where a per-object lock word would cost more than the
  critical section is worth.

`private` is per FILE. A guard type and an accessor written in the same file as
the data leave the data reachable from the rest of that file, which for a
2000-line file is where the next unguarded read will be written. The field's
TYPE has to live elsewhere.

Counters in these cells store how many values have been HANDED OUT rather than
which value comes next, so `.bss` zero is already the correct initial state and
no initializer is needed. That is not tidiness: the alternative is a lazy
initializer, and a lazy initializer is what raced before the lock existed.

## Liveness proofs for pooled objects

`IntrusivePool` hands out a linear `IntrusiveSlotView` on a successful probe,
and an `IntrusiveOwner` on a successful allocation. Both are proofs that a slot
is occupied. The payload accessors take them as `borrow` and return `*T @ id`,
so a payload pointer cannot outlive the proof.

This is the at-view discipline: the VALUE (a handle) stays copyable and
storable in a tree, the PROOF is linear and cannot be stored, and dereferencing
requires the proof. Ownership is the wrong tool for a process tree, which needs
many non-owning references to one record; proof-separation is not.

`intrusive_pool_payload_unproven_of` and `intrusive_pool_ref_unproven` are the
named escapes for a caller that must return the pointer. They are `!{unsafe}`
so each one is counted in the trusted-base inventory, and they still require a
successful probe -- what they drop is the lifetime relation, not the occupancy
check. Laundering is not forbidden; it is a number.

A normal view is also the pool-lock owner, so another core cannot free or
replace its occupant until the view is consumed. A slot-only probe answers for
whoever occupies that slot and therefore cannot compare the generation a
caller expected; handle-based callers use `intrusive_pool_probe_handle` for
that check. The explicitly unsafe unproven accessors discard the lifetime
relation and leave exclusion to their stopped-world or caller-owned contract.

## Reporters must not take locks

A reporter that can block cannot report the deadlock it is in. The diagnostic
ring, the crash trace ring, the retained log and the DDB read path are all in
this class, and all of them use per-CPU storage plus release/acquire
publication rather than a lock.

This is not local caution. Linux moved printk to a lock-free ringbuffer so
printing from NMI, panic and kdb contexts cannot deadlock, and keeps
`bust_spinlocks()` so an oops can pass a console lock. NetBSD's DDB reads every
kernel structure through `db_read_bytes` and takes nothing, after stopping the
other CPUs by IPI; its `machine cpu N` refuses to inspect a CPU it has not
stopped. FreeBSD makes every mutex a no-op under `SCHEDULER_STOPPED()`. All
three accept that a structure read mid-update prints garbage: the read is
best-effort, non-deadlock is absolute.

The crash trace ring uses one GLOBAL atomic sequence with per-CPU storage,
unlike the diagnostic ring's per-CPU sequences, because on two cores the
interesting version of "what was the kernel doing when it died" is the
interleaving.

Ordinary peer log lines use a bounded per-CPU publication ring. A peer builds
one complete line locally and publishes its sequence with release ordering;
core 0 copies a stable record with acquire ordering and alone updates the
retained log. Before admitting that complete record to the shared UART queue,
core 0 reserves room for its bytes, optional wire boundary and truncation suffix,
then enqueues them under one console guard. A terminal chunk cannot enter in
the middle of that record. Core-0 diagnostics assembled across separate calls
still have separate admission boundaries. Overwrite and truncation are reported. Fatal and DDB paths bypass this channel and never wait for its
consumer.

Userspace terminal output on every CPU appends to one queue under the console
lock, with room measurement, ONLCR encoding, enqueue, FIFO drain and TX interrupt
mask update in the same section. The guard is IRQ-masking and innermost under
the process-run lock. A process's successive writes preserve their accepted
chunk order across CPU migration. Concurrent writers may interleave between
bounded chunks, not inside an admitted chunk or a CR/LF pair. A writer that
cannot admit any byte waits on UartTx on any CPU; the room recheck and wake scan
are under the run lock, and the drain releases the console lock before waking.
The maintained peer writer verifies peer/core0/peer migration and an alternating
parent/child sequence on distinct CPUs, with getcpu bracketing each real write.
It then writes seventeen 63-byte lines, reports the actual first count, and
retries until all 1071 input bytes are accepted. Common views compare the
ordering sequence, all seventeen lines and the completion verdict on both
platforms. A kernel log verdict crosses a separate channel and need not follow
the last terminal record physically.

The UART-BREAK DDB lanes retain the peer writer with
`kernel_ddb_console_test_enabled`, then arm `kernel_ddb_console_hold_armed`
only after the ordinary UART wake and other prerequisites. The writer sleeps
until that late arm. Outside the process-run guard it takes the real console
guard, publishes its held phase, and waits for a world-stop request, the
physical UART BREAK flag, or a five-second recovery deadline. The release decision is published before unlocking restores its IRQ state,
so a pending stop can park it without hiding that decision. Complete world-stop
and the actual unlocked mutex confirm the release.
The deadline prevents a fixture from abandoning a lock; it is not a latency
verdict. Ordinary boots exit the writer after its ordering verdict.

QEMU stops at the peer's hold checkpoint and independently reads both the
phase and actual mutex word before injecting a real serial BREAK while the
CPUs remain stopped. It then resumes the CPUs and requires complete world-stop,
DDB inspection, queue restoration and workload resume. The board arms after
its newline wake, waits for the holder's polling UART marker, and requires
either the holder's physical BREAK observation or DDB's held-at-entry
observation, as well as release and resume. A deadline-only release does not
satisfy the board witness. No ordinary terminal ring or DDB ring rendezvous
remains. The retained peer kernel-log ring stays a separate publication stream;
its completed records now supply the peer drain count and wait statistics.

This tests a finite holder. UART BREAK and the stop SGI are IRQ-dependent:
a permanently IRQ-masked CPU can prevent entry or complete world-stop. DDB
refuses shared-state inspection without all required acknowledgements. Such
failures need the existing external SWD or QEMU host diagnostics; an independent
exception-based entry route is outside the maintained debugger guarantee.

Terminal input (GitHub issue #547) goes the other way: the RX interrupt is
routed to core 0, and the reader may be on another CPU. One lock orders it,
the process-run lock that publishes Blocked:
- the interrupt holds it across its search for a Blocked UartRx reader and,
  when none takes the byte, its push into the receive ring;
- a reader takes a byte out of the ring under it;
- a reader about to sleep looks at the ring once more inside
  kernel_process_block_reserved, in the critical section that publishes
  Blocked, and runs its read again if a byte is there.
So for any byte and any reader, either the interrupt comes first and the
reader's later look sees the byte, or the reader's Blocked comes first and
the interrupt finds it. The lock's release and acquire order the ring's
contents between CPUs; the ring's own fences are compiler-only. #546's look
with local interrupts masked stays as a cheap early exit, since a local mask
cannot hold off an interrupt taken on another CPU.
Termios settings and canonical editing use the same guard. A canonical-to-raw
change wakes retrying readers if buffered input becomes readable without a
new interrupt. Whole user-output chunks are admitted under this guard too,
so TCSETSW cannot apply between a peer's settings snapshot and publication.
Echo operations and the tagged TX queue are covered by the console lock
(which masks interrupts, as the bare mask it replaced did); a signal flush
cannot interrupt a debug-record peek/retire pair. Terminal producers on every
CPU append to the same queue under the guard. Single-word atomic
publication carries output pause and input-throttle requests to TX paths
that cannot acquire the process-run lock. See `TERMINAL.md`.

`/bin/peer-tty` is the admitted reader on the secondary. The deterministic
`peer` mode of kernelcheck-uart-wake-qemu uses gdb to hold CPU1 after the
reader's last lockless look. It starts `/bin/peer-spin` first, waits for its
CPU-1 affinity confirmation, and requires the reader to revisit the blocking
window; the init-managed HTTPd can sleep in `accept` and cannot supply this
contention. While the reader is held, CPU0 alone takes the RX
interrupt and pushes the byte, and then both CPUs run. The reader has to come
back for the next byte. The UART-BREAK DDB lane breaks in while that reader
is asleep on the secondary. DDB's live wait graph must then show exactly one
uart-rx waiter, and `ps` must show it Blocked on UartRx under a shell that
waits for a child. After `continue` the same reader takes its typed line.

## Stopping the other cores

`kernel/lib/occupancy.tkb` also owns the machine-wide `WorldStop` controller.
An initiator publishes a stop request, and each platform sends GIC SGI 1 to
every other active CPU. The SGI handler acknowledges in its own per-CPU word
before entering a holding spin; release clears the request and every held CPU
returns through its interrupted frame.

A successful request returns a linear `WorldStopped[controller]`. Readers that
substitute machine quiescence for a lock accept that type, so a request which
did not stop every target cannot call them. A bounded incomplete request
returns the distinct linear `WorldStopPartial[controller]`; it records which
CPUs acknowledged only so release can remain mandatory, not as inspection
permission. A nonblocking test-and-set gate refuses concurrent initiators
without changing the owner's identity. Each request has a fresh nonzero
generation, and an acknowledgement must match it. A handler leaving an older
request cannot acknowledge a new stop or remain held by it. Generations never
wrap: exhaustion refuses subsequent requests.

The maintained contention lane proves the distinction on QEMU and RPi5. Its
positive phase stops the live secondary through the real SGI, observes that
its timer count stays fixed, and resumes it. Its negative phase suppresses the
test notification to make that same live CPU deliberately fail to acknowledge;
only a partial token is produced and the guarded inspection count stays one.
It also repeats sixteen immediate stop/release pairs with the online peer,
checks nested requests are refused, and injects a stale nonzero acknowledgement
into a private controller to prove it cannot mint a complete token.

## Two-core probes

A probe lives in `kernel/kernel/*_contention_evidence.tkb`, is armed by the
platform init, and is driven from the secondary core's loop in
`kernel/arch/arm64/kernel/secondary.tkb`. Rules learned by getting each one
wrong:

- **The detector uses the probe's OWN atomics**, never a counter on the racing
  path. A counter being measured loses increments to the race it is measuring,
  and two racy counters losing the same amount report success.
- **Both cores need work OUTSIDE the critical section**, or the measurement is
  of a monopoly. A locked phase that reports the second core completed one
  round to the first core's 4096 has proved nothing.
- **Two-sided where the race can be produced**: phase 1 unlocked must SHOW the
  defect, phase 2 locked must not. A probe with only the locked phase goes
  quietly green the day the window stops reproducing.
- **The start is a TWO-WAY handshake, and one half alone is worse than none.**
  The secondary completes one round, publishes it, and then waits for the
  primary to have run one of its own; the primary waits for that completed
  round before starting. Neither core can finish its work before the other has
  begun, which is what makes the reported overlap an arrangement rather than a
  hope. Each half was tried alone and each failed differently: waiting for a
  completed round without holding the secondary back hands it a head start and
  closes the window phase 1 needs, and letting it announce itself without
  holding it back lets it run every round and leave -- and an `active` flag is
  a LEVEL the secondary clears on its way out, so a primary polling that level
  reports a core that did all of its work as a core that never arrived.
  A probe whose verdict is about a primitive's GIVE-UP path rather than about
  overlap needs neither half: `kernel/kernel/occupancy_drain_evidence.tkb`
  has the second core hold the region open and keep holding it, so the drain
  it is testing cannot succeed whatever its bound is, and the counts come out
  the same on QEMU and on the board.
- **A window narrower than a scheduling slice wants a RENDEZVOUS, not more
  rounds.** `kernel/kernel/pool_walk_contention_evidence.tkb` needs a walk to
  be holding an address into a chunk at the instant that chunk is released.
  Chased statistically it cost 12.4 seconds of boot time per 2048 rounds --
  enough to break an unrelated network self-test in the same boot -- and still
  never landed once on RPi5 across two boots. Stopping the walker at the
  boundary and holding it there until the other core has released the chunk
  produces the same hazard every round on both targets, in 64 rounds. The rule
  generalises: when a probe finds itself tuning round counts against a
  deadline, the window is telling it to synchronise instead of to spend more.
- **Every wait is bounded by the counter, never by a spin count.** A spin
  bound is a duration only if this core's speed is fixed, and on a busy host
  4096 empty iterations expire before the other core has been scheduled at
  all. `read_cntfrq()`-derived windows are the same duration on both boards
  and on an emulator.
- **Make phase 1 reproduce the race, rather than hoping it does.** Whether the
  window opens is otherwise a property of the machine the boot landed on, and
  a probe that reports `failed` because a host was busy sends its reader to
  the wrong subsystem. Two answers, in order of preference:
  1. **Split the production read from its write-back and rendezvous both
     cores between them**, so the unlocked phase loses exactly one update per
     round by construction. `kernel/kernel/freelist_contention_evidence.tkb`
     and its pid sibling do this; it costs a test-only begin/commit/cancel
     escape in the primitive being measured, which is linear so every path
     commits or cancels, and it is worth that where the racing window is one
     word.
  2. **Retry phase 1**, bounded by attempts and by a wall-clock budget, where
     splitting the primitive is a larger change than the flakiness has
     earned -- `schedule_contention` claims a whole state transition under
     the run lock. Report only the attempt that is reported, so a view
     comparing exactly still sees one stage line, and print the attempt count
     so the cost is visible.
- **Print the counts on every exit path**, including the give-ups, and say
  WHICH term of the verdict went false. A run that could not set itself up
  otherwise looks identical to one whose counter raced, and one word covering
  "the lock leaked", "the race did not reproduce" and "one core never ran"
  sends the reader to the wrong subsystem -- only the first is about the
  kernel.
- **The verdict needs a term that is FALSE when the probe did no work, and
  that term has to be asserted rather than printed.** Printing it is what
  keeps failing: `pool_walk_contention`'s first draft reported a clean run
  over `steps=0` -- 2048 walks and not one slot visited -- and the number was
  on the screen the whole time. It became a real verdict only when the probe
  compared it, as `met != POOL_WALK_ROUNDS` returning false. The same term
  under other names: `overlap > 0` in `asid_contention_evidence.tkb`,
  `primary == CONTENTION_ROUNDS && secondary == CONTENTION_ROUNDS` in the
  pool probe. Pick the count that goes to zero when the probe never ran, not
  the count of what it found: a probe that legitimately finds no duplicate
  still walked, and it is the walking that has to be proved. A verdict that
  cannot tell "the property holds" from "I never looked" is worth less than
  no verdict, because it is read as the first.
- **A probe that destroys what it raced for must wait for the other core to
  have LEFT**, which `kernel/lib/occupancy.tkb` makes a linear value rather
  than a flag.
- **A probe that allocates a process record needs
  `scheduled_process_table_init()`, not `scheduled_process_pool_init_for_probe()`**:
  the pool-only call leaves three other slot-keyed tables holding a previous
  life's state.

The verdict rule above -- assert a term that is false when the probe did no
work -- is not a build check, and that is a judgement rather than an omission. The scripts side of the same defect is mechanised -- every
`scripts/check_*.py` reports through `scripts/pass_line.py`, which refuses to
print PASS when a count the verdict rests on is zero, and
`scripts/check_pass_line_counts.py` enforces that no check goes around it.
The probe side does not reduce the same way. It would have to decide two
things a pattern cannot: which of a probe's several `return false` paths is
the verdict rather than a give-up, and which statics the SECOND core
increments, which means following `kernel/arch/arm64/kernel/secondary.tkb`
into each probe's entry point and tracking the atomics it writes across
files. The shapes in the tree are genuinely different -- a trailing
`return advanced == calls && overlap > 0`, a chain of guards ending in
`return true`, a two-phase verdict split across a helper called twice -- so
the obvious cheap approximations produce false positives on correct probes
today, which is the failure mode that gets a check disabled.
`scripts/check_probe_entry_gates.py` is mechanised instead because its rule
is a forbidden token in one recognisable loop, not a relation between a
variable and another core's writes. Revisit this if the probes converge on
one verdict shape.

## What QEMU cannot tell you

Treat any QEMU concurrency result as a lower bound. Measured differences on the
same binary:

- spinlock fairness: RPi5 gave one core 4096 rounds to the other's 1; QEMU gave
  4096 to 4110, because its round-robin vCPU scheduling supplies a fairness the
  hardware does not.
- probe overlap, measured on one binary across both targets: `asid` 11 on RPi5
  against 2035 on QEMU, `fd refcount` 14 against 2038, `page` 31 against 2048,
  `pool` 161 against 4082. Two orders of magnitude, and it is the same code.
  This is the live form of the older note that a lock's second core reached 18
  rounds of 2048 on the board where QEMU reported the full 2048.
- the probes that DO agree across targets are the ones that stopped leaving it
  to chance: `freelist` and `pid` rendezvous inside the production read/write
  pair, `schedule` runs 4095/4096 either way, and
  `pool_walk_contention_evidence` reports an identical 64 of 64 on both. A
  synchronised probe measuring the same number everywhere is evidence that the
  synchronisation works, NOT that the two machines are alike -- the bullets
  above are what they are actually like. Read a matching pair of numbers as a
  statement about the probe, and a diverging pair as a statement about the
  machine.

The freelist double hand-out used to be quoted here as 1349 on RPi5 against 3
on QEMU. That measurement is gone rather than merely old: `df06fc8` made that
probe force the collision at a rendezvous, so it now reports 4096 on both and
no longer measures the gap at all.
- MMU-off exclusives are not enforced by QEMU at all.

## Console lock measurements

The bounded boot workload reports `console lock: acquisitions=... contended=...
acquire_ticks=... acquire_max=... hold_ticks=... hold_max=... cpus=...
tickfreq=...`. Counters are protected by the same console lock. A contended
acquisition means its first atomic try actually failed; it is not a racy
observation of a busy word, nor a count of every retry. Acquisition duration
runs from the clock read before IRQ masking to the clock read after acquiring
the word, including the helper and clock overhead. Hold duration runs from
that latter read to the read before release bookkeeping and unlock; release
and IRQ restoration overhead are excluded.

The window starts at the shared test driver, after startup contention probes,
and ends after the bounded interactive workload. Starting the window's own
hold is excluded. The ending snapshot acquisition is counted, but its hold
is excluded; reporting takes place after releasing the guard. The late
artificial DDB hold is outside the window. The CPU mask and counter consistency
are functional checks on both platforms. Durations are observations only on
QEMU; physical timing evidence comes from RPi5. Maxima are observed samples,
not worst-case bounds or a guarantee of IRQ-independent debugger entry.
