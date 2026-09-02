# Kernel concurrency

Authoritative for how this kernel synchronizes today, what each mechanism is
for, and which questions to ask before adding another one. Historical
narrative for any single decision belongs in `HISTORY.md`; this file states
current behavior and must be correct without reading it.

## Where the kernel stands

`kernel/lib/execution_model.tkb` holds two numbers, and most unsynchronized
state in this kernel is safe *because of* them:

- `KERNEL_ACTIVE_CORES` -- cores that run kernel code. Core 1 boots, takes its
  own timer interrupts and idles; its dispatch returns before every path that
  reaches kernel state.
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

Two things a proof does NOT give you. It says the slot was occupied at PROBE
time, not that another core cannot free it while you hold it. And the probe
compares nothing against the generation the caller was expecting, so a
recycled slot still answers Live -- which is why a stale handle can read a
different live record in silence.

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
- **Wait for the secondary to have COMPLETED A ROUND**, not merely to have
  announced itself, before the primary starts -- except where phase 1 needs the
  cores to collide inside a few instructions, in which case gate on presence.
  The rule is: gate on a completed round when the verdict needs overlap, gate
  on presence when phase 1 needs a collision.
- **Print the counts on every exit path**, including the give-ups. A run that
  could not set itself up otherwise looks identical to one whose counter raced.
- **A probe that destroys what it raced for must wait for the other core to
  have LEFT**, which `kernel/lib/occupancy.tkb` makes a linear value rather
  than a flag.
- **A probe that allocates a process record needs
  `scheduled_process_table_init()`, not `scheduled_process_pool_init_for_probe()`**:
  the pool-only call leaves three other slot-keyed tables holding a previous
  life's state.

## What QEMU cannot tell you

Treat any QEMU concurrency result as a lower bound. Measured differences on the
same binary:

- freelist double hand-out: 1349 on RPi5, 3 on QEMU.
- spinlock fairness: RPi5 gave one core 4096 rounds to the other's 1; QEMU gave
  4096 to 4110, because its round-robin vCPU scheduling supplies a fairness the
  hardware does not.
- probe overlap: a lock's second core reached 18 rounds of 2048 on RPi5 where
  QEMU reported the full 2048.
- MMU-off exclusives are not enforced by QEMU at all.
