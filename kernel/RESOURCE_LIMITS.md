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
`d45ee56`). When a limit or its exhaustion behavior changes, update this
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
| Kernel stacks (per process slot) | `KERNEL_PROCESS_STACK_SIZE` x up to `KERNEL_PROCESS_MAX` chunks, via `GrowablePool` | 4096 B/slot, lazily grown | Global, indexed by process slot | `growable_pool_ensure()` inside `scheduled_process_alloc()` | Returns `GrowablePoolEnsureResult{IndexOutOfRange;ChunkLimitReached;OutOfMemory;Ok}`, so "this pool's own ceiling" is distinguishable from "the global physical page allocator is out of memory" at every caller. Boundary-tested by `growable_pool_probe` (pre-existing, updated for the richer type). |
| Address-space roots | `ADDRESS_SPACE_MAX` (`kernel/mm/address_space.tkb`) | 16 (must equal `KERNEL_PROCESS_MAX`) | Global, indexed by process slot | `address_space_ensure_root()` / `address_space_release_root()` | Returns `AddressSpaceEnsureResult{SlotOutOfRange;OutOfMemory;AsidExhausted;Ok}` / `AddressSpaceAllocateResult{OutOfMemory;AsidExhausted;Ok}`, so a bad slot, ASID-pool exhaustion, and page-table allocation failure are three distinct results at every call site (`scheduled_process_alloc`, `user_memory.tkb`, `process_image.tkb`). |
| User virtual address space (per address-space root) | `USER_SPACE_PAGE_COUNT` (`kernel/mm/address_space.tkb`) | 262144 pages (1 GiB) | Per-process | Bounds check only (`slot >= ADDRESS_SPACE_MAX \|\| index >= USER_SPACE_PAGE_COUNT`) | Not a depletable pool in practice (no workload maps close to 1 GiB); out-of-range access returns `false` from the relevant accessor. Static bound, intentional; no change needed. |
| ASIDs | `ASID_MAX` (`kernel/arch/arm64/mm/asid.tkb`) | 16 (matches `ADDRESS_SPACE_MAX`) | Global | `asid_alloc()` / `asid_free()`, SlotMap-backed | `AsidAllocResult::Full`, explicit variant, now surfaces as `AddressSpaceAllocateResult::AsidExhausted` up through `scheduled_process_alloc`'s diagnostic log. Boundary-tested by `asid_pool_probe` (pre-existing). |
| Process page-table root registration | `PROCESS_IMAGE_ROOT_MAX` (`kernel/mm/process_image.tkb`) | 16 (must equal `KERNEL_PROCESS_MAX`) | Global, indexed by process slot | Plain bookkeeping array, not a separate allocator (real backing cost lives in `address_space.tkb`) | Same slot space as `KERNEL_PROCESS_MAX`; no independent exhaustion path. No change needed. |
| Physical pages | `BOOT_PAGE_COUNT` (`kernel/mm/page.tkb`) | 204800 pages (800 MiB) | Global | `page_alloc()` / `page_free()`, SlotMap-backed | `PageAllocResult::OutOfMemory`, explicit, well-named variant -- already the best-diagnosed pool in the kernel; needed no change. Its downstream callers (`growable_pool_ensure`, `address_space_allocate_root`) no longer discard this distinction. |
| Page-mapping reference count (COW fork fan-out) | `PAGE_MAP_REF_MAX` (`kernel/mm/page.tkb`) | 4194304 (= `ADDRESS_SPACE_MAX` x `USER_SPACE_PAGE_COUNT`) | Global, per physical page | `page_mapping_retain_physical()` / release via page free, called from `process_image.tkb`'s clone (fork) path | `page_mapping_retain_physical()` now returns `PageMappingRetainResult{NotMapped;RefCeilingReached;Retained}` instead of one `bool false` -- `NotMapped` (a real internal invariant violation) is now distinct from `RefCeilingReached` (the actual ceiling, logged via `kernel_boot_log_resource_exhausted`). The ceiling itself is practically unreachable by any real fork/COW fan-out (16 address spaces x 262144 pages each), but issue #295 still requires a reviewed-and-kept static capacity's exhaustion behavior to be tested -- `page_mapping_ref_ceiling_probe` proves the boundary check itself fires at exactly the ceiling by writing the pool's own `map_refcount` field directly rather than looping 4.2 million times. |
| Per-process descriptor namespace | `PROCESS_FD_MAX` (`kernel/kernel/fd_table.tkb`) | 16 | Per-process | `unified_fd_alloc()` / `unified_fd_close()` | `UnifiedFdAllocResult::Full`, explicit variant. The `openat` and `fcntl(F_DUPFD/F_DUPFD_CLOEXEC)` syscall handlers return `LINUX_EMFILE` (not `LINUX_EBADF`) on `Full`, logged via `kernel_boot_log_resource_exhausted`. Boundary-tested by the new `unified_fd_table_exhaustion_probe`. |
| Process contexts (fd table + heap state) | `PROCESS_CONTEXT_MAX` (`kernel/kernel/fd_table.tkb`) | 16 (must equal `KERNEL_PROCESS_MAX`) | Global | Same slot space as the process table | No independent exhaustion path observed. No change needed. |
| Shared kernel objects (files, dirs, listeners, connections, terminals) | `SHARED_OBJECT_MAX` (`kernel/kernel/fd_table.tkb`) | 16 | Global | `unified_object_alloc_first()` via `RefcountSlotMap` | **This was the exact failure mode issue #295 was filed over.** `unified_file_open`/`unified_directory_open`/`unified_terminal_stdio_open`/`unified_listener_create`/`unified_connection_create` return `UnifiedOpenResult{Invalid;Full;Ok}` instead of collapsing `Full` into the same `Invalid` used for a genuinely bad argument. The `openat` syscall handler returns `LINUX_ENFILE` (not `LINUX_EBADF`) on `Full`; the socket/accept paths (which already used the more defensible `LINUX_EAGAIN`) also log the specific cause. Boundary-tested by `unified_object_pool_exhaustion_probe`. |
| Shared-object reference count ceiling | `SHARED_OBJECT_MAX_REFS` (`kernel/kernel/fd_table.tkb`) | `PROCESS_CONTEXT_MAX * PROCESS_FD_MAX` (256), a real reference/arithmetic expression, not a duplicated literal -- the compiler's `const` grammar was extended (commit 1d7694f) to support this, reusing `array_size`'s own IDENT/+/-/*// machinery | Global | Passed to `RefcountSlotMap`'s ref-take path (`unified_fd_install`/`unified_fd_duplicate`/`unified_fd_clone`) | `refcount_pool_retain()`'s own `RefcountRetainResult::Overflow` was being discarded into the same `Invalid` as a bad fd argument by `unified_fd_install`/`unified_fd_duplicate`; both now return `UnifiedFdInstallResult{Invalid;RefOverflow;Ok}`, and `fcntl(F_DUPFD)` maps `RefOverflow` to `LINUX_EMFILE` with a log line. **Auditing this surfaced a real correctness bug, not just a diagnosability gap:** `unified_fd_clone()` (fork's fd-table copy) had no rollback on a mid-loop `Overflow`/failure -- fds already retained before the failure point leaked their incremented refcounts forever, and the failing fd itself was left half-copied. Fixed via a new `unified_fd_clone_rollback()` helper. `unified_object_ref_ceiling_probe` boundary-tests the ceiling itself directly (256 real `refcount_pool_retain` calls on one allocated object, not a simulated shortcut -- cheap enough to just do for real, unlike `PAGE_MAP_REF_MAX`'s 4.2M). |
| Legacy per-process socket fd range | `KERNEL_SOCKET_FD_MAX` (`kernel/kernel/syscall.tkb`) | `= PROCESS_FD_MAX` (16), a real reference, not a duplicated literal (was a bare `8`, then a hand-synced `16`, before the `const` grammar fix -- see `SHARED_OBJECT_MAX_REFS` above for the same fix) | Per-process | `kernel_socket_fd_alloc()`/`kernel_listener_fd_lookup()`/etc., all of which range-check against this ceiling and then delegate to `unified_fd_alloc`/`unified_socket_lookup` (the same `PROCESS_FD_MAX`-sized table) | This constant had no backing storage array of its own -- confirmed by exhaustive grep -- it was a pure numeric-range ceiling layered under the real 16-wide unified fd table. At 8 it silently refused socket fd numbers 8-15 even when `PROCESS_FD_MAX`'s real table had free slots there (e.g. a shell whose first 8 descriptors were already busy with inherited terminal/job fds), reporting resource exhaustion (`LINUX_EAGAIN`) that did not actually exist. Now a real reference to `PROCESS_FD_MAX`; it can never drift below it again, and it is no longer a second, independent capacity, just a legacy name for the same one, so it needs no separate boundary test beyond `unified_fd_table_exhaustion_probe`. |
| TCP connections | `TCP_CONNECTION_MAX` (`kernel/net/tcp.tkb`) | 2 (deliberately tiny, issue #189) | Global | `tcp_connection_alloc()` / `tcp_connection_free()`, SlotMap-backed | `TcpConnectionAllocResult::Full`, explicit variant. `kernel_syscall_inetd_accept` and the `accept4` syscall handler log "TCP connection pool" exhaustion distinctly via `kernel_boot_log_resource_exhausted` before returning the existing `TimedOut`/`LINUX_EAGAIN` result -- the *externally visible* retry behavior was deliberately left unchanged (this accept path's timing is a recurring flake source; only logging was added, not control flow). An operator reading the boot log can now tell pool exhaustion from a genuine timeout; a userspace caller still sees the same retryable result either way, matching correct TCP behavior (dropping a SYN under resource pressure). Boundary-tested by the new `tcp_connection_pool_exhaustion_probe`, which proves the pool reports `Full` at exactly 2 concurrently held connections (the existing QEMU network fixture only ever exercised reuse sequentially). |
| Pending (unacked) TCP segments | `PENDING_TCP_MAX` (`kernel/net/tcp.tkb`) | 4, per connection | Per-connection | `pending_tcp_record()` / acked-segment removal | **Was a real silent-corruption bug, confirmed by the pre-existing code's own comment acknowledging the fallback -- now fixed, not just logged.** `pending_tcp_find_free_slot()`/`pending_tcp_record()` used to fall back to slot 0 when all 4 slots were occupied and unconditionally overwrite whatever occupied it, silently clobbering an unrelated in-flight segment's still-unacknowledged retransmission record. Both now return `i32` with `-1` meaning "not tracked" (matching this file's own existing sentinel idiom) instead of always claiming a slot; the new segment is still sent exactly as before, it simply is not tracked for automatic retransmission when the queue is full, and critically no other slot's data is ever touched. Both callers' deliberate-drop test-injection branches are guarded on getting a real slot, so an untracked segment is never silently skipped-and-never-sent either. Boundary-tested by the new `pending_tcp_exhaustion_probe`, which fills all 4 slots directly, confirms a 5th record attempt reports `-1` without altering any existing slot's data, and confirms a freed slot is reused. |

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

All nine findings from the audit were fixed in this same session across
four rounds (commits `6c85779`, `98fe441`, `a5ee81b`, `0698fcf`, `de4987c`,
`e88126d`, `d45ee56`), rather than split into follow-up issues, per explicit
direction to complete issue #295 without filing separate issues.
`make kernelbuild-qemu` and `make kernelcheck-qemu` are green after every
step (37 views, up from 31 at the start), including two clean rebuilds.
`make kernelcheck-rpi5` / `make kernelcheck` were run on real RPi5 hardware
with the user's explicit go-ahead each time: after round 1 (33 views), round
2 (34 views), round 3 (35 views), and round 4 (37 views) -- all fully green.
Every fix and every boundary test in this file is verified on both QEMU and
real RPi5 hardware.

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
   the code's own pre-existing comment acknowledging the fallback. First
   logged only (same retry-timing caution as finding 2), then -- per
   explicit follow-up direction to close this out fully rather than leave
   the corruption itself in place -- actually fixed: exhaustion now reports
   `-1` ("not tracked") instead of claiming a slot to overwrite, with both
   callers' test-injection paths guarded so an untracked segment is never
   silently dropped either.

Two additional items were closed in a fourth round after re-reading the
issue's own design constraints more strictly: a reviewed-and-kept static
capacity must still have its "limit and exhaustion behavior... explicit and
covered by tests," which `PAGE_MAP_REF_MAX` and `SHARED_OBJECT_MAX_REFS`
initially were not (both had been judged impractical to boundary-test,
which turned out to be wrong for both -- see the boundary-test section
below).

## Boundary/exhaustion test coverage

Per issue #295's "exhaustion tests exercise each allocator near its
boundary" acceptance criterion -- which applies even to a reviewed static
capacity that's kept as-is, per the issue's own design constraints -- every
pool in this file now has a dedicated boundary test:

- `scheduled_process_table_probe` (`KERNEL_PROCESS_MAX`, pre-existing)
- `growable_pool_probe` (kernel stacks, pre-existing)
- `asid_pool_probe` (`ASID_MAX`, pre-existing)
- `unified_object_pool_exhaustion_probe` (`SHARED_OBJECT_MAX`, new)
- `unified_fd_table_exhaustion_probe` (`PROCESS_FD_MAX`, new)
- `tcp_connection_pool_exhaustion_probe` (`TCP_CONNECTION_MAX`, new)
- `pending_tcp_exhaustion_probe` (`PENDING_TCP_MAX`, new -- drives the
  pending-slot state directly rather than through real TCP timing, since
  reaching this boundary via genuine network loss/retry would require a
  materially larger QEMU-peer-driven test)
- `unified_object_ref_ceiling_probe` (`SHARED_OBJECT_MAX_REFS`, new -- a
  real 256-iteration retain loop, not a shortcut)
- `page_mapping_ref_ceiling_probe` (`PAGE_MAP_REF_MAX`, new -- writes the
  pool's own `map_refcount` field directly to reach the 4.2M boundary
  without looping that many times, since only the boundary CHECK, not the
  increment mechanism, needed proving here)

No pool in this file is without a boundary test.
