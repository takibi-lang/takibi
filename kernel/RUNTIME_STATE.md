# Kernel runtime state ownership

This is the inventory GitHub issue #294 asked for: every module-level
mutable global (`let mut`/`private let mut`) retained under `kernel/`
after the #302-#307 consolidation pass, grouped by what actually owns it
and why it stays a global instead of moving behind a per-process/
per-connection/per-slot record.

This file records the state of the kernel as of 2026-08-14 (commit
`3266f29`). Like `RESOURCE_LIMITS.md`, treat this as a living document:
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

`scheduled_process_store`/`scheduled_process_pool`/`scheduled_process_records`/
`scheduled_process_kernel_stacks`, `execution_current_handle`/
`execution_current_live`, `execution_scheduler_enabled`/
`execution_reschedule_pending`.

**Why global:** there is exactly one scheduler on this single-core kernel
(see the file's own "NOT SYNCHRONIZED, single-core scheduler" limitation
header). `scheduled_process_records` is already the per-slot owner
(#264) -- every process's state, wait reason, parent/child links, and
saved SP live in one `ProcessRecord` per slot, not scattered scalars.
`execution_current_handle`/`_live` name which slot is "current"; that is
inherently a single, global fact on one core. `execution_scheduler_enabled`/
`_reschedule_pending` gate real scheduling decisions
(`kernel_process_schedule`/`kernel_process_syscall_return_schedule`), so
they stay with the scheduler they control rather than moving into a
per-process record they are not scoped to.

### Diagnostic/trace infrastructure (`kernel/kernel/process.tkb`)

`kernel_crash_trace`/`kernel_crash_trace_next`,
`kernel_process_trace_probe_parent_frame`/`_child_frame`,
`kernel_process_trace_boot_enabled`/`_fail_after_exec`/`_enabled`.

**Why global:** this is #288's bounded process/scheduler trace and #293's
oops-snapshot infrastructure -- deliberately allocation-free,
single-writer, and readable from a fail-stop path that cannot assume a
working scheduler. A ring buffer's write cursor is definitionally one
global counter, not a per-process field.

### VM / address-space (`kernel/mm/`, `kernel/arch/arm64/mm/`)

`mm/process_image.tkb`'s `process_image_record` (per-root
`ProcessImageRecord`, #258/#264), `process_clone_vm_store`,
`process_image_exec_stores`, the ext2-image-loading staging fields
(`process_image_ext2_*`/`process_image_pair_ext2_*`), the in-flight-clone
scalars (`clone_page_count`/`clone_last_reaped_count`/`clone_source_root`/
`clone_dest_root`); `mm/address_space.tkb`'s `address_space_backing`/
`_active_slot`; `mm/page.tkb`'s `boot_page_pool`;
`arch/arm64/mm/asid.tkb`'s `asid_pool`.

**Why global:** investigated for #294 and found already well-scoped --
`process_image_record`'s own header comment states the "one managed
thing, one struct" rule this file already follows (a future
per-address-space field belongs in the struct, not a new parallel
array). The clone-in-flight scalars are singleton by design (this
kernel supports exactly one clone operation in flight at a time,
matching `process_clone_vm_store`'s own single-in-flight-clone
protocol -- see that struct's header). The physical pools
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

`process_fd_context` (per-process, #264), `object_pool` + `object_records`
(per-shared-object, #305).

**Why global:** per-slot arrays, already record-owned. The pool
allocators (`RefcountSlotMap`) are inherently global namespaces (a file
descriptor number is meaningless without the one process-slot table it
indexes into; a shared object handle is meaningless without the one
kernel-wide object table it indexes into).

### Network (`kernel/net/`)

`net/tcp.tkb`'s `tcp_connection_store` (linear ownership/locking,
mirrors `process.tkb`'s own deliberate
`scheduled_process_store`/`scheduled_process_records` split) plus the
per-connection `conn_*` parallel arrays (`conn_state`/`conn_remote_ip`/
`conn_remote_mac`/`conn_remote_port`/`conn_local_port`/`conn_snd_nxt`/
`conn_rcv_nxt`); `net/socket_capability.tkb`'s `network_capability_store`
(the kernel owns exactly one physical RX capability, by hardware
design, not by choice).

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
  `tcp_connection_store`. They are not: `tcp_connection_store` holds only
  linear ownership/locking bookkeeping (mutex + `TcpConnectionValue`),
  the same ownership-record-vs-data-record split `process.tkb` uses
  deliberately. A `conn_*`-into-one-struct consolidation (mirroring
  #305's `SharedObject`) could still be legitimate future work, but needs
  its own fresh proposal -- it was not attempted here.

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
`crash_snapshot_capturing`.

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
`kernel/kernel/syscall_test_lifecycle.tkb` (#307).

**Why global:** test fixtures are inherently singleton within one boot
(there is one QEMU/RPi5 integration run at a time). The point of these
four files is that test-only state is now physically separated from
production state at the file level, satisfying #294's "test-only
lifecycle state is clearly separated from ordinary kernel state"
acceptance criterion -- not that it stopped being global.
