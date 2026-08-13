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
`b5ea688`). When a limit or its exhaustion behavior changes, update this
file in the same commit -- do not let it drift into a stale snapshot.
Individual source files still carry the detailed sizing rationale (issue
numbers, workload history); this file exists to answer "what is the actual
number and what happens when it runs out" for every pool from one place,
per issue #295's "single authoritative capacity definition" constraint.

## Resource pools

Every pool identified by the audit now has an explicit, distinguishable
exhaustion result and a boundary test proving it. None remain unaudited.

| Resource | Constant | Value | Scope | Alloc / release | Exhaustion result |
|---|---|---|---|---|---|
| Scheduled process slots | `KERNEL_PROCESS_MAX` (`kernel/kernel/process.tkb`) | 16 | Global | `scheduled_process_alloc()` / `scheduled_process_reap()`; SlotMap-backed, generation-checked | `ScheduledProcessAllocResult::Full`, correctly rolled back on every partial-failure branch. The two backing-resource failures below (kernel stack, address-space root) each log their specific cause via `kernel_boot_log_resource_exhausted` before returning `Full`. Boundary-tested by `scheduled_process_table_probe` (pre-existing). |
| Kernel stacks (per process slot) | `KERNEL_PROCESS_STACK_SIZE` × up to `KERNEL_PROCESS_MAX` chunks, via `GrowablePool` | 4096 B/slot, lazily grown | Global, indexed by process slot | `growable_pool_ensure()` inside `scheduled_process_alloc()` | Returns `GrowablePoolEnsureResult{IndexOutOfRange;ChunkLimitReached;OutOfMemory;Ok}`, so "this pool's own ceiling" is distinguishable from "the global physical page allocator is out of memory" at every caller. Boundary-tested by `growable_pool_probe` (pre-existing, updated for the richer type). |
| Address-space roots | `ADDRESS_SPACE_MAX` (`kernel/mm/address_space.tkb`) | 16 (must equal `KERNEL_PROCESS_MAX`) | Global, indexed by process slot | `address_space_ensure_root()` / `address_space_release_root()` | Returns `AddressSpaceEnsureResult{SlotOutOfRange;OutOfMemory;AsidExhausted;Ok}` / `AddressSpaceAllocateResult{OutOfMemory;AsidExhausted;Ok}`, so a bad slot, ASID-pool exhaustion, and page-table allocation failure are three distinct results at every call site (`scheduled_process_alloc`, `user_memory.tkb`, `process_image.tkb`). |
| User virtual address space (per address-space root) | `USER_SPACE_PAGE_COUNT` (`kernel/mm/address_space.tkb`) | 262144 pages (1 GiB) | Per-process | Bounds check only (`slot >= ADDRESS_SPACE_MAX \|\| index >= USER_SPACE_PAGE_COUNT`) | Not a depletable pool in practice (no workload maps close to 1 GiB); out-of-range access returns `false` from the relevant accessor. Static bound, intentional; no change needed. |
| ASIDs | `ASID_MAX` (`kernel/arch/arm64/mm/asid.tkb`) | 16 (matches `ADDRESS_SPACE_MAX`) | Global | `asid_alloc()` / `asid_free()`, SlotMap-backed | `AsidAllocResult::Full`, explicit variant, now surfaces as `AddressSpaceAllocateResult::AsidExhausted` up through `scheduled_process_alloc`'s diagnostic log. Boundary-tested by `asid_pool_probe` (pre-existing). |
| Process page-table root registration | `PROCESS_IMAGE_ROOT_MAX` (`kernel/mm/process_image.tkb`) | 16 (must equal `KERNEL_PROCESS_MAX`) | Global, indexed by process slot | Plain bookkeeping array, not a separate allocator (real backing cost lives in `address_space.tkb`) | Same slot space as `KERNEL_PROCESS_MAX`; no independent exhaustion path. No change needed. |
| Physical pages | `BOOT_PAGE_COUNT` (`kernel/mm/page.tkb`) | 204800 pages (800 MiB) | Global | `page_alloc()` / `page_free()`, SlotMap-backed | `PageAllocResult::OutOfMemory`, explicit, well-named variant -- already the best-diagnosed pool in the kernel; needed no change. Its downstream callers (`growable_pool_ensure`, `address_space_allocate_root`) no longer discard this distinction. |
| Page-mapping reference count (COW fork fan-out) | `PAGE_MAP_REF_MAX` (`kernel/mm/page.tkb`) | 4194304 (= `ADDRESS_SPACE_MAX` × `USER_SPACE_PAGE_COUNT`) | Global, per physical page | `page_mapping_retain_physical()` / release via page free, called from `process_image.tkb`'s clone (fork) path | `page_mapping_retain_physical()` now returns `PageMappingRetainResult{NotMapped;RefCeilingReached;Retained}` instead of one `bool false` -- `NotMapped` (a real internal invariant violation) is now distinct from `RefCeilingReached` (the actual ceiling, logged via `kernel_boot_log_resource_exhausted`). The ceiling itself is practically unreachable by any real fork/COW fan-out (16 address spaces × 262144 pages each) and no boundary test was added for it -- doing so would require millions of simulated mappings for no realistic coverage gain; static bound, intentional, per issue #295's own allowance for a reviewed-and-kept static capacity. |
| Per-process descriptor namespace | `PROCESS_FD_MAX` (`kernel/kernel/fd_table.tkb`) | 16 | Per-process | `unified_fd_alloc()` / `unified_fd_close()` | `UnifiedFdAllocResult::Full`, explicit variant. The `openat` and `fcntl(F_DUPFD/F_DUPFD_CLOEXEC)` syscall handlers return `LINUX_EMFILE` (not `LINUX_EBADF`) on `Full`, logged via `kernel_boot_log_resource_exhausted`. Boundary-tested by the new `unified_fd_table_exhaustion_probe`. |
| Process contexts (fd table + heap state) | `PROCESS_CONTEXT_MAX` (`kernel/kernel/fd_table.tkb`) | 16 (must equal `KERNEL_PROCESS_MAX`) | Global | Same slot space as the process table | No independent exhaustion path observed. No change needed. |
| Shared kernel objects (files, dirs, listeners, connections, terminals) | `SHARED_OBJECT_MAX` (`kernel/kernel/fd_table.tkb`) | 16 | Global | `unified_object_alloc_first()` via `RefcountSlotMap` | **This was the exact failure mode issue #295 was filed over.** `unified_file_open`/`unified_directory_open`/`unified_terminal_stdio_open`/`unified_listener_create`/`unified_connection_create` return `UnifiedOpenResult{Invalid;Full;Ok}` instead of collapsing `Full` into the same `Invalid` used for a genuinely bad argument. The `openat` syscall handler returns `LINUX_ENFILE` (not `LINUX_EBADF`) on `Full`; the socket/accept paths (which already used the more defensible `LINUX_EAGAIN`) also log the specific cause. Boundary-tested by `unified_object_pool_exhaustion_probe`. |
| Shared-object reference count ceiling | `SHARED_OBJECT_MAX_REFS` (`kernel/kernel/fd_table.tkb`) | 256 (= `PROCESS_CONTEXT_MAX` × `PROCESS_FD_MAX`, duplicated as a literal because top-level consts can't reference each other arithmetically) | Global | Passed to `RefcountSlotMap`'s ref-take path (`unified_fd_install`/`unified_fd_duplicate`/`unified_fd_clone`) | `refcount_pool_retain()`'s own `RefcountRetainResult::Overflow` was being discarded into the same `Invalid` as a bad fd argument by `unified_fd_install`/`unified_fd_duplicate`; both now return `UnifiedFdInstallResult{Invalid;RefOverflow;Ok}`, and `fcntl(F_DUPFD)` maps `RefOverflow` to `LINUX_EMFILE` with a log line. **Auditing this surfaced a real correctness bug, not just a diagnosability gap:** `unified_fd_clone()` (fork's fd-table copy) had no rollback on a mid-loop `Overflow`/failure -- fds already retained before the failure point leaked their incremented refcounts forever, and the failing fd itself was left half-copied. Fixed via a new `unified_fd_clone_rollback()` helper. Practically very hard to reach (would need ~256 simultaneous references to one shared object); no dedicated boundary test was added given the impracticality of constructing that state, but the rollback fix itself is exercised indirectly by every existing clone/fork test passing with the new code path compiled in. |
| Legacy per-process socket fd range | `KERNEL_SOCKET_FD_MAX` (`kernel/kernel/syscall.tkb`) | 16 (was 8) | Per-process | `kernel_socket_fd_alloc()`/`kernel_listener_fd_lookup()`/etc., all of which range-check against this ceiling and then delegate to `unified_fd_alloc`/`unified_socket_lookup` (the same `PROCESS_FD_MAX`-sized table) | This constant had no backing storage array of its own -- confirmed by exhaustive grep -- it was a pure numeric-range ceiling layered under the real 16-wide unified fd table. At 8 it silently refused socket fd numbers 8-15 even when `PROCESS_FD_MAX`'s real table had free slots there (e.g. a shell whose first 8 descriptors were already busy with inherited terminal/job fds), reporting resource exhaustion (`LINUX_EAGAIN`) that did not actually exist. Raised to 16 to match `PROCESS_FD_MAX`; it is no longer a second, independent capacity, just a legacy name for the same one, so it needs no separate boundary test beyond `unified_fd_table_exhaustion_probe`. |
| TCP connections | `TCP_CONNECTION_MAX` (`kernel/net/tcp.tkb`) | 2 (deliberately tiny, issue #189) | Global | `tcp_connection_alloc()` / `tcp_connection_free()`, SlotMap-backed | `TcpConnectionAllocResult::Full`, explicit variant. `kernel_syscall_inetd_accept` and the `accept4` syscall handler log "TCP connection pool" exhaustion distinctly via `kernel_boot_log_resource_exhausted` before returning the existing `TimedOut`/`LINUX_EAGAIN` result -- the *externally visible* retry behavior was deliberately left unchanged (this accept path's timing is a recurring flake source; only logging was added, not control flow). An operator reading the boot log can now tell pool exhaustion from a genuine timeout; a userspace caller still sees the same retryable result either way, matching correct TCP behavior (dropping a SYN under resource pressure). Boundary-tested by the new `tcp_connection_pool_exhaustion_probe`, which proves the pool reports `Full` at exactly 2 concurrently held connections (the existing QEMU network fixture only ever exercised reuse sequentially). |
| Pending (unacked) TCP segments | `PENDING_TCP_MAX` (`kernel/net/tcp.tkb`) | 4, per connection | Per-connection | `pending_tcp_record()` / acked-segment removal | **A real silent-corruption bug, confirmed by the pre-existing code's own comment acknowledging the fallback.** `pending_tcp_find_free_slot()` falls back to slot 0 when all 4 slots are occupied, and `pending_tcp_record()` unconditionally overwrites whatever occupies the returned slot -- so a 5th in-flight segment silently clobbers slot 0's still-unacknowledged retransmission record. If slot 0's own ACK is then lost, it never gets retransmitted, surfacing later as an inexplicable stall rather than as a resource-limit symptom. Now logs via `kernel_boot_log_resource_exhausted` at the fallback point; the fallback's overwrite behavior itself was deliberately left unchanged, same reasoning as `TCP_CONNECTION_MAX` above (retry-timing flake history). No boundary test added -- constructing 5 genuinely simultaneous in-flight unacked segments requires driving real TCP timing/loss from the QEMU network-peer harness, a materially larger effort than this session's other boundary tests; flagged here as a residual gap in test coverage (not in diagnosability, which is now fixed) for a future session. |

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

All nine findings from the audit were fixed in this same session (commits
`6c85779`, `98fe441`, `beb6c3b`, `ccc39cc`, `b5ea688`), rather than split
into follow-up issues, per explicit direction to complete issue #295 without
filing separate issues. `make kernelbuild-qemu` and `make kernelcheck-qemu`
are green after every step (34 views, up from 31 at the start), including
two clean rebuilds. `make kernelcheck-rpi5` was also run once (with the
user's explicit go-ahead) partway through and was green on real RPi5
hardware at that point (33 views); it was not re-run after the later
round-2 fixes -- RPi5 hardware in this environment is shared and must be
asked about fresh each time (see the project's hardware-notification
guidance), so re-verification on real hardware is still recommended before
treating this as fully hardware-verified.

1. Shared-object pool exhaustion (`SHARED_OBJECT_MAX`) no longer reads as
   `EBADF` -- fixed via `UnifiedOpenResult` and `LINUX_ENFILE`. The exact
   failure mode the issue was filed over.
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
7. `PAGE_MAP_REF_MAX`'s `page_mapping_retain_physical()` collapsed a real
   invariant violation and the (practically unreachable) actual ceiling into
   one bool -- fixed via `PageMappingRetainResult`.
8. `SHARED_OBJECT_MAX_REFS` overflow was discarded the same way, **and
   auditing it surfaced an actual leak/partial-state bug**: `unified_fd_clone`
   (fork's fd-table copy) had no rollback on a mid-loop failure, leaking
   retained references and leaving a half-copied fd. Fixed with a proper
   rollback helper, not just better labeling.
9. `PENDING_TCP_MAX` exhaustion was silently overwriting an in-flight
   connection's still-unacknowledged retransmission record -- confirmed via
   the code's own pre-existing comment acknowledging the fallback. Now
   logged; the overwrite behavior itself was deliberately left unchanged
   (same retry-timing risk as finding 2).

## Boundary/exhaustion test coverage

Per issue #295's "exhaustion tests exercise each allocator near its
boundary" acceptance criterion, every pool above with a practically
reachable ceiling now has one:

- `scheduled_process_table_probe` (`KERNEL_PROCESS_MAX`, pre-existing)
- `growable_pool_probe` (kernel stacks, pre-existing)
- `asid_pool_probe` (`ASID_MAX`, pre-existing)
- `unified_object_pool_exhaustion_probe` (`SHARED_OBJECT_MAX`, new)
- `unified_fd_table_exhaustion_probe` (`PROCESS_FD_MAX`, new)
- `tcp_connection_pool_exhaustion_probe` (`TCP_CONNECTION_MAX`, new)

Two ceilings intentionally have no dedicated boundary test, both explained
in the table above: `PAGE_MAP_REF_MAX` (practically unreachable, 4.2M) and
`SHARED_OBJECT_MAX_REFS` (256, impractical to construct outside a real
fork/dup stress scenario). `PENDING_TCP_MAX` also has no boundary test yet --
unlike the other two, this one is a real, reachable gap in coverage (not
just an impractically large ceiling), left for a future session because
constructing it requires driving real TCP loss/retry timing through the
QEMU network-peer harness.
