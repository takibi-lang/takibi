# Kernel runtime state ownership

This is the inventory GitHub issue #294 asked for: every module-level
mutable global (`let mut`/`private let mut`) retained under `kernel/`
after the #302-#307 consolidation pass, grouped by what actually owns it
and why it stays a global instead of moving behind a per-process/
per-connection/per-slot record.

This file records the state of the kernel as of 2026-08-21 (issue #392's
first three stages). Like `RESOURCE_LIMITS.md`, treat this as a living document:
when a global is added, removed, or its ownership rationale changes,
update this file in the same commit rather than letting it drift into a
stale snapshot.

#294's own motivation was diagnosability: an interactive-ash-plus-
background-HTTPd stall required correlating state scattered across
unrelated globals with no coherent single-process view. #302-#307 fixed
the specific unowned/duplicated cases that caused that -- this file
documents what is left and argues each retained category is either
already record-owned per-slot (just implemented as an array of structs,
not a single scalar) or genuinely singleton by nature (one physical
core, one UART, one boot-time filesystem mount).

## Consolidated behind an explicit owner (#302-#307)

| Issue | What moved | New owner | Why it mattered |
|---|---|---|---|
| #302 | `syscall_block_reason`/`syscall_wait4_status_ptr` (syscall.tkb module globals relaying a block decision across the one-way `.Lsyscall_block` asm tail branch) | The blocking process's own `ProcessRecord` (`kernel/kernel/process.tkb`) | Real bug, not just style: `wait4_status_ptr` was a single global shared by every blocked parent -- a second parent blocking in `wait4()` before an earlier one woke would overwrite the first parent's still-pending status pointer. |
| #303 | 10 pure test/evidence counters (clone/exit/UART-block/scheduler-switch counts) mixed into `process.tkb`'s `execution_*` globals | `kernel/kernel/process_test_evidence.tkb` | Made it possible to tell "state a diagnostic snapshot needs" (`execution_scheduler_enabled`/`execution_reschedule_pending`, left in `process.tkb`) apart from "state only a test assertion reads," which used to be indistinguishable siblings in the same declaration block. |
| #304 | 16 syscall-call-count evidence counters mixed into `syscall.tkb` | `kernel/kernel/syscall_test_evidence.tkb` | Same split, one file over. |
| #305 | `fd_table.tkb`'s 9 parallel `object_*` arrays (kind/offset/inode/readable/writable/listener_state/port/transport_slot/transport_generation), all indexed by the same shared-object slot | One `SharedObject` struct array (`object_records`), mirroring `ProcessFdContext`'s own issue-#264 precedent in the same file | The file's own header comment had already named this exact "globals indexed in lockstep" problem for the per-process case; the shared-object pool right below it had never gotten the same treatment. |
| #306 | N/A (build-tooling, not kernel state) | `--emit-depfile` (`bin/main.ml`) + `-include` in the Makefile | Exposed by #305: the Makefile's hand-written `.tkb` prerequisite list had silently drifted from the compiler's own `use` closure, so a `fd_table.tkb`-only change didn't trigger a rebuild. Fixed for `KERNEL_QEMU_MAIN_O`; other targets still carry hand-written lists (see that commit). |
| #307 | 12 test-driver-bounded lifecycle fields (foreground-server bounding, persistent-shell #289 checkpoints) mixed into `syscall.tkb` | `kernel/kernel/syscall_test_lifecycle.tkb`, with named predicate/mutator functions (`_should_bound()`, `_listener_ready_label()`, ...) replacing direct field access from real dispatch code | Some of this state gates real control flow (whether `accept4()` exits the process early), which is why it needed predicate functions instead of #303/#304's plain counters. |

## Retained as global, by category

### Process/scheduler core (`kernel/kernel/process.tkb`)

`scheduled_process_pool` (`IntrusivePool(ProcessRecord)`, private) and the
static `scheduled_process_boot_record` beside it, and
`execution_state: [ExecutionState; KERNEL_MAX_CORES]` -- the four
former `execution_*` scalars (`current_handle`, `current_live`,
`scheduler_enabled`, `reschedule_pending`), grouped and made an array by
issue #222.

**Why global:** there is exactly one scheduler, because only core 0 ever
runs one (see the file's own "SINGLE-CORE SCHEDULER" limitation header --
core 1 stopped parking at issue #447 and still never enters here, because
its dispatch returns before every path that reaches kernel state).

`execution_state` is no longer global in the sense this section means:
issue #479 made `execution_here()` ask `cpu_id()` and index the array, and
it is sized by `KERNEL_MAX_CORES` rather than by the active count -- which
is Linux's `NR_CPUS` versus `cpu_online_mask`, storage for the most cores a
build could have against participation counted separately. The pid counter
beside it is minted under `scheduled_process_pid_lock`. `ProcessRecord` is already the per-process owner (#264) -- every
process's state, wait reason, parent/child links, and saved SP live in one
record, not scattered scalars. Since #392 that record is a pool allocation
and a process slot is its ADDRESS; the bootstrap is the one static, because
root 0 exists before the MMU is on. Issue
#392 folded the kernel stack's page run in as a field and put the handles
for the three pooled per-process records (fd context, image record,
address-space backing) there too, so the parallel arrays those replaced
are gone. The former `scheduled_process_kernel_stacks` `GrowablePool` no
longer exists: kernel stacks are page runs (#377) and that primitive left
`kernel/` entirely (#381). `scheduled_process_store` is gone too, the same
way `tcp_connection_store` went: it was the parking lot, somewhere for a
linear `ScheduledProcessOwner` to live between syscalls, and with the
SlotMap already recording who is live an owner is minted from a handle's
(slot, generation) pair on demand and discharged when the operation ends.
`ExecutionState.current_handle`/`.current_live` name which slot is
"current", and `.scheduler_enabled`/`.reschedule_pending` gate real
scheduling decisions (`kernel_process_schedule`/
`kernel_process_syscall_return_schedule`), so all four stay with the
scheduler they control rather than moving into a per-process record they
are not scoped to.

Issue #222 changed WHERE they live without changing that: they were four
sibling scalars, which assumed not that there is one core but that there
is one SET of them with nowhere to put a second. They are now
`ExecutionState`, held in an array sized by `KERNEL_ACTIVE_CORES`
(`kernel/lib/execution_model.tkb`), reached through one private
`execution_here()`. That function returns slot 0 and carries the
`static_assert` that fails when the constant is raised, so the 176
references that used to name a scalar each are now one function to teach
`cpu_id()` -- see issue #453 for the worklist that assertion joins.

### Diagnostic/trace infrastructure (`kernel/kernel/process.tkb`)

`kernel_crash_trace`/`kernel_crash_trace_next`,
`kernel_process_trace_probe_parent_frame`/`_child_frame`,
`kernel_process_trace_boot_enabled`/`_fail_after_exec`/`_enabled`.

**Why global:** this is #288's bounded process/scheduler trace and #293's
oops-snapshot infrastructure -- deliberately allocation-free,
single-writer, and readable from a fail-stop path that cannot assume a
working scheduler. A ring buffer's write cursor is definitionally one
global counter, not a per-process field. The same committed chronology can
also be snapshotted and printed without a crash by
`kernel_process_trace_report()`; that entry point and the oops path share one
row formatter, and neither prints from a scheduler or interrupt writer.

`exception_evidence.tkb`'s `crash_snapshot`/`crash_snapshot_capturing` and
`ddb_snapshot`.

**Why global:** the terminal crash record must survive the failing context,
while resumable DDB must retain one bounded trace/FD/VM/process-table copy
and the current compiler-defined IRQ-frame pointer while its polled command
loop is active.
Neither record owns scheduler or process resources. IRQ masking prevents a
nested entry on the servicing CPU; the current scheduler and UART IRQ route
remain confined to core 0.

### VM / address-space (`kernel/mm/`, `kernel/arch/arm64/mm/`)

**Locked and per-core since issue #479 (2026-08-30).** Four of this
section's entries stopped being plain unsynchronized globals:

| what | what changed |
|---|---|
| `page.tkb`'s `boot_page_pool` | one acquire of `page_allocator_lock` covers each allocator entry point; `page_alloc_boot`/`page_free_boot` are the MMU-off window's lock-free path, because AArch64 has no exclusives on Device memory |
| `asid.tkb`'s `asid_next`/`asid_generation` | minted under `asid_lock`; the file's execution-model assertion was deleted, since nothing there is left to assert |
| `address_space.tkb`'s `address_space_active_slot` | now `[usize; KERNEL_MAX_CORES]` indexed by `cpu_id()` -- it was never shared state, it was PER-CORE state stored as one global |
| `process_image.tkb`'s `process_image_target_root` | same, and the same shape: per-operation state, which on two cores means per-core |

The last two are the distinction this section should keep: five subsystems
this week were missing exclusion, and three were not shared at all. A lock
on either of those would have made two cores agree on something that has
two correct answers.

`mm/process_image.tkb`'s `process_image_pool`/`_ready` and its counted
fallback pair `process_image_record_missing`/`_count` (issue #392 -- the
per-root `ProcessImageRecord` array of #258/#264 is now pooled, keyed by a
handle in `ProcessRecord`; `process_image_exec_stores`, the per-root
parking lot for a linear exec image, is gone the same way
`tcp_connection_store` went -- the root's own record holds what the reap
path asks of an installed image), the ext2-image-loading staging fields
(`process_image_ext2_*`/`process_image_pair_ext2_*`), and
`clone_last_reaped_count`; `mm/address_space.tkb`'s
`address_space_backing_pool`/`_ready`, its counted fallback pair
`address_space_backing_missing`/`_count`, the static
`address_space_backing_root0`, and `address_space_active_slot`;
`mm/page.tkb`'s `boot_page_pool`;
`arch/arm64/mm/asid.tkb`'s `asid_pool`.

**Why global:** investigated for #294 and found already well-scoped --
`ProcessImageRecord`'s own header comment states the "one managed
thing, one struct" rule this file already follows (a future
per-address-space field belongs in the struct, not a new parallel
array). What used to sit here and no longer does is the
clone-in-flight group -- a mutex-guarded `process_clone_vm_store`
holding one linear owner, plus a source root, a destination root and a
page count. They were singleton by design, and the design was wrong:
one clone in flight is a ceiling, not a fact, and a second `fork()`
taken before the first child had `execve`d was refused with `-EAGAIN`.
They live in the destination's own `ProcessImageRecord` now, following
that struct's own rule. `clone_last_reaped_count` stayed, because it
reports on the last reap rather than on a process. The physical pools
(`boot_page_pool`, `asid_pool`) are genuinely global machine resources,
already SlotMap-backed with explicit exhaustion results (see
`RESOURCE_LIMITS.md`).

Found and left alone (not #294 material): `process_image.tkb`'s 3-field
`process_image_exec_reap_count`/`_clean_count`/`_stack_growth_count` is a
small test-evidence group (read only by
`init/test_driver.tkb`'s `process_image_exec_reap_evidence()`), but it
already sits immediately next to its one incrementing function
(`process_image_exec_reap`) and its one reader -- splitting it into a new
file would be ceremony, not a diagnosability improvement, unlike the
#303/#304 cases where dozens of scattered fields made "real vs. test"
state genuinely hard to see.

### FD / socket (`kernel/kernel/fd_table.tkb`)

**Locked since issue #479.** `unified_object_retain`/`_release` take
`object_refcount_lock`, and the acquire covers the handle MATCH as well as
the arithmetic -- checking that a handle still names a live occupant and
then incrementing its counter is two steps, and a core that frees the
object in between leaves the other adding to a recycled slot. Measured
before the lock: two cores took a refcount from a baseline of 2 to 0, so
the object was freed while both still held it, and 978 later operations
found a handle naming nothing. `fd_slot_total` and the per-process block
chain are still unlocked, which is what the file's assertion now says.

`fd_context_pool`/`fd_context_pool_ready` (issue #392 -- the per-process
`ProcessFdContext` array of #264 is now pooled, keyed by a handle in
`ProcessRecord`), `object_pool` + `object_records` (per-shared-object,
#305).

**Why global:** already record-owned; what changed in #392 is that the
records are allocations rather than array elements, which is why the
per-process ones no longer need a table keyed by process slot. The pool
allocators themselves are inherently global namespaces (a file descriptor
number is meaningless without the one context it indexes into; a shared
object handle is meaningless without the one kernel-wide object table it
indexes into).

The two `_ready` flags are one-shot initialisation guards, not state:
their entry points are reachable per process configure, and
re-initialising a pool would forget its pages while records still hold
addresses into them (the hazard #257 hit).

### Network (`kernel/net/`)

`net/tcp.tkb`'s `tcp_connection_pool` (`IntrusivePool(TcpConnection)`,
private), `tcp_frame_pool`, `tcp_retx_pool` and `tcp_retx_chain`;
`net/socket_capability.tkb`'s `network_capability_store` (the kernel owns
exactly one physical RX capability, by hardware design, not by choice).

**Updated by issue #257 (2026-08-20/21).** What stood here before --
`tcp_connection_store` and the `conn_*` parallel arrays -- no longer
exists. `tcp_connection_store` was the parking lot: somewhere for a linear
owner to live between syscalls. A pool removes the NEED rather than the
mechanism (the connection IS the slot, the fd table holds its (address,
generation), and an owner is minted on demand), so it was deleted rather
than ported, along with `TcpConnectionValue`, `TcpConnectionGuard` and
`TcpConnectionPutResult`. The `conn_*` arrays are fields of one
`TcpConnection`, which lives in the pool.

**Investigated and explicitly NOT split for #294:**

- `tcp.tkb`'s fault-injection state (`tcp_drop_next_syn_ack`/
  `tcp_injected_syn_*`/`tcp_drop_data_segment_index`/`tcp_injected_data_*`/
  `tcp_drop_next_fin`/`tcp_injected_fin_*`/`tcp_ack_each_stream_segment`/
  `tcp_split_request_segments`) looked like #303/#304 material from the
  outside, but is read AND written throughout the real TCP retransmit/
  drop state machine, not incremented-then-read-once. Extracting it would
  require threading many call sites back and forth between two files for
  no diagnosability gain -- this is delicate, load-bearing protocol logic
  wearing test-injection clothing, not unowned state.
- The `conn_*` parallel arrays initially looked like a duplicate of
  `tcp_connection_store`. They were not: `tcp_connection_store` held only
  linear ownership/locking bookkeeping (mutex + `TcpConnectionValue`),
  the same ownership-record-vs-data-record split `process.tkb` uses
  deliberately. The `conn_*`-into-one-struct consolidation this bullet
  called "legitimate future work needing its own fresh proposal" is what
  issue #257 did -- and it went further, since a pooled connection needs
  no ownership record beside it at all. Both are gone; see the paragraph
  above.

### Filesystem (`kernel/fs/`)

`ext2/ext2.tkb`'s `ext2_metadata_block`/`ext2_file_block` (one-block
staging buffers); `elf64.tkb`'s `ELF_IDENT_MAGIC` (a constant table, not
mutable runtime state in practice).

**Why global:** the kernel mounts exactly one ext2 filesystem at boot.
Per-block scratch buffers for a single-mount filesystem are legitimately
global scratch space, not per-process state.

### Driver / platform singletons (`kernel/drivers/`, `kernel/platform/`, `kernel/arch/`)

virtio-blk/virtio-net/rp1_gem/usb_xhci device state, QEMU/RPi5 UART ring
buffers, the RPi5 mailbox, `exception_evidence.tkb`'s `crash_snapshot`/
`crash_snapshot_capturing`. `CrashSnapshot` itself now also carries
`wait4_status_ptr` and the current process's `fd_kind`/`fd_object`
arrays (closing #294's own diagnostic-snapshot acceptance criterion --
process/parent/wait-reason/address-space identity/syscall continuation/
descriptor ownership are all now one allocation-free, read-only capture,
populated via the same `kernel_process_crash_*()`/
`kernel_fd_table_crash_*()` accessor pattern, never touching a linear
owner or lock from a fail-stop path).

**Why global:** #294's own design constraints say so explicitly --
"Interrupt paths and early boot may need explicitly scoped global
state." Each of these names one physical device this kernel has exactly
one of. An interrupt handler cannot acquire a per-process lock to reach
"its" device state; it needs a fixed, always-valid address, which is
what a global provides.

### Test-only state, already isolated

`init/test_driver.tkb` (the original precedent this whole pass followed),
`kernel/kernel/process_test_evidence.tkb` (#303),
`kernel/kernel/syscall_test_evidence.tkb` (#304),
`kernel/kernel/syscall_test_lifecycle.tkb` (#307),
`kernel/kernel/workload_evidence.tkb` (the CPU-bound pair `/etc/inittab`
starts, and the fairness and per-core EL0/EL1/IRQ/idle, scheduler-event,
syscall, and I/O-volume numbers taken about its post-warm-up interval -- the
one piece of this group the scheduler, exception paths, syscall dispatch, and
device boundaries call into, with each hook returning before reading a counter
when no interval is active),
`kernel/kernel/profile_samples.tkb` (the bounded per-core PC samples the PMU
overflow interrupt records over that same interval, plus the flags saying
whether the interval is open and whether this CPU has a PMUv3 at all).

**Why global:** test fixtures are inherently singleton within one boot
(there is one QEMU/RPi5 integration run at a time). The point of these
six files is that test-only state is now physically separated from
production state at the file level, satisfying #294's "test-only
lifecycle state is clearly separated from ordinary kernel state"
acceptance criterion -- not that it stopped being global.
