# Kernel resource limits

This is the single authoritative inventory of the fixed-capacity pools and
namespaces used by kernel runtime code, per GitHub issue #295. Each fixed
`_MAX`/`_COUNT` constant that bounds a real runtime resource (a process, a
descriptor, a page, a connection, ...) is listed here with its scope,
allocation/release path, and its *current* exhaustion behavior. Constants
that only bound a syscall argument (not a shared pool) are listed separately
under "Argument bounds (not pools)" for completeness, since `grep -r MAX`
does not distinguish the two.

This file records the state of the kernel as of 2026-08-13 (commit
`98fe441`). When a limit or its exhaustion behavior changes, update this
file in the same commit -- do not let it drift into a stale snapshot.
Individual source files still carry the detailed sizing rationale (issue
numbers, workload history); this file exists to answer "what is the actual
number and what happens when it runs out" for every pool from one place,
per issue #295's "single authoritative capacity definition" constraint.

## Resource pools

| Resource | Constant | Value | Scope | Alloc / release | Exhaustion result |
|---|---|---|---|---|---|
| Scheduled process slots | `KERNEL_PROCESS_MAX` (`kernel/kernel/process.tkb`) | 16 | Global | `scheduled_process_alloc()` / `scheduled_process_reap()`; SlotMap-backed, generation-checked | `ScheduledProcessAllocResult::Full`, correctly rolled back on every partial-failure branch. **Fixed (2026-08-13):** the two backing-resource failures below (kernel stack, address-space root) now each log their specific cause via `kernel_boot_log_resource_exhausted` before returning `Full`, instead of that distinction being silently discarded. |
| Kernel stacks (per process slot) | `KERNEL_PROCESS_STACK_SIZE` × up to `KERNEL_PROCESS_MAX` chunks, via `GrowablePool` | 4096 B/slot, lazily grown | Global, indexed by process slot | `growable_pool_ensure()` inside `scheduled_process_alloc()` | **Fixed (2026-08-13):** `growable_pool_ensure()` now returns `GrowablePoolEnsureResult{IndexOutOfRange;ChunkLimitReached;OutOfMemory;Ok}` instead of a bare `bool`, so "this pool's own ceiling" is distinguishable from "the global physical page allocator is out of memory" at every caller, not just internally. |
| Address-space roots | `ADDRESS_SPACE_MAX` (`kernel/mm/address_space.tkb`) | 16 (must equal `KERNEL_PROCESS_MAX`) | Global, indexed by process slot | `address_space_ensure_root()` / `address_space_release_root()` | **Fixed (2026-08-13):** `address_space_ensure_root()`/`_allocate_root()` now return `AddressSpaceEnsureResult{SlotOutOfRange;OutOfMemory;AsidExhausted;Ok}` / `AddressSpaceAllocateResult{OutOfMemory;AsidExhausted;Ok}` instead of `bool`, so a bad slot, ASID-pool exhaustion, and page-table allocation failure are three distinct results at every call site (`scheduled_process_alloc`, `user_memory.tkb`, `process_image.tkb`). |
| User virtual address space (per address-space root) | `USER_SPACE_PAGE_COUNT` (`kernel/mm/address_space.tkb`) | 262144 pages (1 GiB) | Per-process | Bounds check only (`slot >= ADDRESS_SPACE_MAX \|\| index >= USER_SPACE_PAGE_COUNT`) | Not a depletable pool in practice (no workload maps close to 1 GiB); out-of-range access returns `false` from the relevant accessor. Static bound, intentional; no change needed. |
| ASIDs | `ASID_MAX` (`kernel/arch/arm64/mm/asid.tkb`) | 16 (matches `ADDRESS_SPACE_MAX`) | Global | `asid_alloc()` / `asid_free()`, SlotMap-backed | `AsidAllocResult::Full`, explicit variant. **Fixed (2026-08-13):** now surfaces as `AddressSpaceAllocateResult::AsidExhausted` up through `scheduled_process_alloc`'s diagnostic log, instead of being downgraded to a generic `bool false`. |
| Process page-table root registration | `PROCESS_IMAGE_ROOT_MAX` (`kernel/mm/process_image.tkb`) | 16 (must equal `KERNEL_PROCESS_MAX`) | Global, indexed by process slot | Plain bookkeeping array, not a separate allocator (real backing cost lives in `address_space.tkb`) | Same slot space as `KERNEL_PROCESS_MAX`; no independent exhaustion path. No change needed. |
| Physical pages | `BOOT_PAGE_COUNT` (`kernel/mm/page.tkb`) | 204800 pages (800 MiB) | Global | `page_alloc()` / `page_free()`, SlotMap-backed | `PageAllocResult::OutOfMemory`, explicit, well-named variant -- already the best-diagnosed pool in the kernel. Its downstream callers (`growable_pool_ensure`, `address_space_allocate_root`) no longer discard this distinction (see above); the allocator itself needed no change. |
| Page-metadata refcount table | `PAGE_MAP_REF_MAX` (`kernel/mm/page.tkb`) | 4194304 | Global | Sized independently of `BOOT_PAGE_COUNT`; not yet traced to a runtime exhaustion path | Not yet audited (see below). |
| Per-process descriptor namespace | `PROCESS_FD_MAX` (`kernel/kernel/fd_table.tkb`) | 16 | Per-process | `unified_fd_alloc()` / `unified_fd_close()` | `UnifiedFdAllocResult::Full`, explicit variant. **Fixed (2026-08-13):** the `openat` and `fcntl(F_DUPFD/F_DUPFD_CLOEXEC)` syscall handlers now return `LINUX_EMFILE` (not `LINUX_EBADF`) on `Full`, and log the resource name + capacity via `kernel_boot_log_resource_exhausted`. |
| Process contexts (fd table + heap state) | `PROCESS_CONTEXT_MAX` (`kernel/kernel/fd_table.tkb`) | 16 (must equal `KERNEL_PROCESS_MAX`) | Global | Same slot space as the process table | No independent exhaustion path observed. No change needed. |
| Shared kernel objects (files, dirs, listeners, connections, terminals) | `SHARED_OBJECT_MAX` (`kernel/kernel/fd_table.tkb`) | 16 | Global | `unified_object_alloc_first()` via `RefcountSlotMap` | **Fixed (2026-08-13), this was the exact failure mode issue #295 was filed over.** `unified_file_open`/`unified_directory_open`/`unified_terminal_stdio_open`/`unified_listener_create`/`unified_connection_create` now return `UnifiedOpenResult{Invalid;Full;Ok}` instead of collapsing `Full` into the same `Invalid` used for a genuinely bad argument. The `openat` syscall handler now returns `LINUX_ENFILE` (not `LINUX_EBADF`) on `Full`; the socket/accept paths (which already used the more defensible `LINUX_EAGAIN`) now also log the specific cause. Covered by the new `unified_object_pool_exhaustion_probe` boundary test. |
| Shared-object reference count ceiling | `SHARED_OBJECT_MAX_REFS` (`kernel/kernel/fd_table.tkb`) | 256 (= `PROCESS_CONTEXT_MAX` × `PROCESS_FD_MAX`, duplicated as a literal because top-level consts can't reference each other arithmetically) | Global | Passed to `RefcountSlotMap`'s ref-take path | Not yet traced to a distinct exhaustion result; likely shares `UnifiedObjectResult::Full`. Not yet audited. |
| Per-process socket fd range | `KERNEL_SOCKET_FD_MAX` (`kernel/kernel/syscall.tkb`) | 16 (was 8) | Per-process | `kernel_socket_fd_alloc()`/`kernel_listener_fd_lookup()`/etc., all of which range-check against this ceiling and then delegate to `unified_fd_alloc`/`unified_socket_lookup` (the same `PROCESS_FD_MAX`-sized table) | **Fixed (2026-08-13).** This constant had no backing storage array of its own -- confirmed by exhaustive grep -- it was a pure numeric-range ceiling layered under the real 16-wide unified fd table. At 8 it silently refused socket fd numbers 8-15 even when `PROCESS_FD_MAX`'s real table had free slots there (e.g. a shell whose first 8 descriptors were already busy with inherited terminal/job fds), reporting resource exhaustion (`LINUX_EAGAIN`) that did not actually exist. Raised to 16 to match `PROCESS_FD_MAX`; it is no longer a second, independent capacity, just a legacy name for the same one. |
| TCP connections | `TCP_CONNECTION_MAX` (`kernel/net/tcp.tkb`) | 2 (deliberately tiny, issue #189) | Global | `tcp_connection_alloc()` / `tcp_connection_free()`, SlotMap-backed | `TcpConnectionAllocResult::Full`, explicit variant. **Partially fixed (2026-08-13):** `kernel_syscall_inetd_accept` and the `accept4` syscall handler now log "TCP connection pool" exhaustion distinctly via `kernel_boot_log_resource_exhausted` before returning the existing `TimedOut`/`LINUX_EAGAIN` result -- the *externally visible* retry behavior was deliberately left unchanged (this accept path's timing is a recurring flake source, see `kernel_tcp_retry_timing` history; only logging was added, not control flow). An operator reading the boot log can now tell pool exhaustion from a genuine timeout; a userspace caller still sees the same retryable result either way, which matches correct TCP behavior (dropping a SYN under resource pressure). Covered by the new `tcp_connection_pool_exhaustion_probe` boundary test, which proves the pool reports `Full` at exactly 2 concurrently held connections (the existing QEMU network fixture only ever exercised reuse sequentially). |
| Pending (unacked) TCP segments | `PENDING_TCP_MAX` (`kernel/net/tcp.tkb`) | 4, per connection | Per-connection | Retry/retransmit bookkeeping array indexed by connection slot | Not yet traced; likely silently drops/ignores excess pending segments rather than surfacing a distinct result. Not yet audited. |

## Argument bounds (not pools)

These constants cap a single syscall's argument (vector length, poll fd
count, transfer chunk size) rather than a shared, allocatable resource. They
do not have "exhaustion" in the pool sense -- they reject an individual call
with an explicit errno and there is nothing to leak or roll back. No changes
needed for any of these.

| Constant | Value | Location | Behavior |
|---|---|---|---|
| `IOV_MAX` | 1024 | `kernel/kernel/syscall.tkb` | `readv`/`writev` with `iovcnt >= IOV_MAX` returns `LINUX_EINVAL`, matching Linux `UIO_MAXIOV` semantics. Already correctly diagnosable. |
| `POLL_MAX` | 1024 | `kernel/kernel/syscall.tkb` | Same pattern for `ppoll`'s `nfds`. |
| `MSC_MAX_TRANSFER_SECTORS` | 128 | `kernel/platform/rpi5/usb_xhci.tkb` | Caps a single USB mass-storage transfer; larger requests are split into multiple transfers by the caller, not rejected. |
| `EXT2_MAX_DIRECT_BLOCKS` | 12 | `kernel/fs/ext2/ext2.tkb` | On-disk format constant (ext2 direct-block count), not a runtime allocator. |
| `WAIT_POLL_MAX` | 10000 | `kernel/arch/arm64/kernel/user_payload.tkb` | Bounded retry-loop iteration count for `--forbid-trap`, not a resource capacity. |
| `MMU_TABLE_ENTRY_COUNT` | 512 | `kernel/arch/arm64/mm/mmu.tkb` | Hardware-fixed page-table entry count (AArch64 architectural constant). |

## Diagnosability fixes landed 2026-08-13

All six gaps found by the initial audit pass were fixed in this same session
(commits `6c85779`, `98fe441`), rather than split into follow-up issues, per
explicit direction to complete issue #295 without filing separate issues.
`make kernelbuild-qemu` and `make kernelcheck-qemu` (33 views, up from 31)
are green after every step, including a clean rebuild. RPi5 hardware
verification was intentionally **not** run this session (deferred per the
project's hardware-notification rule) -- run `make kernelcheck-rpi5` (or
`kernelcheck`, which includes it) before treating this as verified on real
hardware.

1. Shared-object pool exhaustion (`SHARED_OBJECT_MAX`) no longer reads as
   `EBADF` -- fixed via `UnifiedOpenResult` and `LINUX_ENFILE`.
2. TCP connection-pool exhaustion (`TCP_CONNECTION_MAX`) now logs distinctly
   from an ordinary accept timeout, without changing retry behavior.
3. Per-process fd-table exhaustion (`PROCESS_FD_MAX`) no longer reads as
   `EBADF` -- fixed via `LINUX_EMFILE`.
4. `growable_pool_ensure` no longer discards its richer result type -- fixed
   via `GrowablePoolEnsureResult`.
5. `address_space_ensure_root` no longer collapses three failure causes into
   one bool -- fixed via `AddressSpaceEnsureResult`.
6. `KERNEL_SOCKET_FD_MAX` was an unexplained, too-small second fd-capacity
   ceiling -- fixed by raising it to match `PROCESS_FD_MAX` (it never had
   backing storage of its own).

## Not yet audited

These were out of scope for this pass (no workload has hit them, and they
were not implicated in the issue's motivating failure):

- `PAGE_MAP_REF_MAX` (`kernel/mm/page.tkb`) exhaustion path.
- `SHARED_OBJECT_MAX_REFS` distinct exhaustion result (vs. `SHARED_OBJECT_MAX`).
- `PENDING_TCP_MAX` overflow behavior (per-connection retransmit queue).
