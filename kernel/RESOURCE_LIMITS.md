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
`9b5720a`). When a limit or its exhaustion behavior changes, update this
file in the same commit -- do not let it drift into a stale snapshot.
Individual source files still carry the detailed sizing rationale (issue
numbers, workload history); this file exists to answer "what is the actual
number and what happens when it runs out" for every pool from one place,
per issue #295's "single authoritative capacity definition" constraint.

## Resource pools

| Resource | Constant | Value | Scope | Alloc / release | Exhaustion result today |
|---|---|---|---|---|---|
| Scheduled process slots | `KERNEL_PROCESS_MAX` (`kernel/kernel/process.tkb`) | 16 | Global | `scheduled_process_alloc()` / `scheduled_process_reap()`; SlotMap-backed, generation-checked | `ScheduledProcessAllocResult::Full`, explicit variant, correctly rolled back on every partial-failure branch (kernel stack, address-space root, identity-store conflict all unwind). **Gap:** collapses "process table full" and "backing kernel-stack/page-table allocation failed" (see `growable_pool_ensure` below) into the same `Full`. |
| Kernel stacks (per process slot) | `KERNEL_PROCESS_STACK_SIZE` × up to `KERNEL_PROCESS_MAX` chunks, via `GrowablePool` | 4096 B/slot, lazily grown | Global, indexed by process slot | `growable_pool_ensure()` inside `scheduled_process_alloc()` | **Gap:** `growable_pool_ensure()` returns a bare `bool`, discarding the richer `GrowablePoolInsertResult::OutOfMemory` variant that exists one layer down (`growable_pool_grow_one_chunk`/`growable_pool_insert`). A global physical-page shortage (`PageAllocResult::OutOfMemory`) is therefore indistinguishable from "this pool's own `MAX_CHUNKS` ceiling reached" at every current call site. |
| Address-space roots | `ADDRESS_SPACE_MAX` (`kernel/mm/address_space.tkb`) | 16 (must equal `KERNEL_PROCESS_MAX`) | Global, indexed by process slot | `address_space_ensure_root()` / `address_space_release_root()` | Returns bare `bool`. **Gap:** collapses slot-range check, ASID-pool exhaustion, and page-table backing allocation failure into one `false`, which the caller (`scheduled_process_alloc`) further collapses into generic `Full`. |
| User virtual address space (per address-space root) | `USER_SPACE_PAGE_COUNT` (`kernel/mm/address_space.tkb`) | 262144 pages (1 GiB) | Per-process | Bounds check only (`slot >= ADDRESS_SPACE_MAX \|\| index >= USER_SPACE_PAGE_COUNT`) | Not a depletable pool in practice (no workload maps close to 1 GiB); out-of-range access returns `false` from the relevant accessor. Static bound, intentional. |
| ASIDs | `ASID_MAX` (`kernel/arch/arm64/mm/asid.tkb`) | 16 (matches `ADDRESS_SPACE_MAX`) | Global | `asid_alloc()` / `asid_free()`, SlotMap-backed | `AsidAllocResult::Full`, explicit variant. Consumed only from `address_space_allocate_root`, where it is downgraded to the generic `bool false` described above. |
| Process page-table root registration | `PROCESS_IMAGE_ROOT_MAX` (`kernel/mm/process_image.tkb`) | 16 (must equal `KERNEL_PROCESS_MAX`) | Global, indexed by process slot | Plain bookkeeping array, not a separate allocator (real backing cost lives in `address_space.tkb`) | Same slot space as `KERNEL_PROCESS_MAX`; no independent exhaustion path. |
| Physical pages | `BOOT_PAGE_COUNT` (`kernel/mm/page.tkb`) | 204800 pages (800 MiB) | Global | `page_alloc()` / `page_free()`, SlotMap-backed | `PageAllocResult::OutOfMemory`, explicit, well-named variant -- the best-diagnosed pool in the kernel. The problem is downstream callers (e.g. `growable_pool_ensure`) discarding this variant, not the allocator itself. |
| Page-metadata refcount table | `PAGE_MAP_REF_MAX` (`kernel/mm/page.tkb`) | 4194304 | Global | Sized independently of `BOOT_PAGE_COUNT`; not yet traced to a runtime exhaustion path in this pass | Follow-up needed (see below). |
| Per-process descriptor namespace | `PROCESS_FD_MAX` (`kernel/kernel/fd_table.tkb`) | 16 | Per-process | `unified_fd_alloc()` / `unified_fd_close()` | `UnifiedFdAllocResult::Full`, explicit variant at this layer. **Gap:** at the syscall boundary (`kernel/kernel/syscall.tkb`, e.g. the `openat` handler around line 1668-1671) this is mapped to `LINUX_EBADF`, the same errno returned for a genuinely bad fd argument -- Linux uses `EMFILE` for this case, and nothing distinguishes the two in the kernel log. |
| Process contexts (fd table + heap state) | `PROCESS_CONTEXT_MAX` (`kernel/kernel/fd_table.tkb`) | 16 (must equal `KERNEL_PROCESS_MAX`) | Global | Same slot space as the process table | No independent exhaustion path observed. |
| Shared kernel objects (files, dirs, listeners, connections, terminals) | `SHARED_OBJECT_MAX` (`kernel/kernel/fd_table.tkb`) | 16 | Global | `unified_object_alloc_first()` via `RefcountSlotMap` | `UnifiedObjectResult::Full`, explicit variant. **Gap:** every caller (`unified_file_open`, `unified_directory_open`, `unified_listener_create`, `unified_connection_create`) immediately downgrades this to `UnifiedFdResult::Invalid`, which the syscall layer then maps to `LINUX_EBADF` -- identical to the `PROCESS_FD_MAX` gap above, and to a plain "no such fd" error. **This is the exact failure mode issue #295 was filed over**: the interactive HTTPd workload's shared-object exhaustion was reported as an opaque `EBADF`/startup failure, not as "shared object pool exhausted." |
| Shared-object reference count ceiling | `SHARED_OBJECT_MAX_REFS` (`kernel/kernel/fd_table.tkb`) | 256 (= `PROCESS_CONTEXT_MAX` × `PROCESS_FD_MAX`, duplicated as a literal because top-level consts can't reference each other arithmetically) | Global | Passed to `RefcountSlotMap`'s ref-take path | Not yet traced to a distinct exhaustion result; likely shares `UnifiedObjectResult::Full`. |
| Legacy kernel-socket fd namespace | `KERNEL_SOCKET_FD_MAX` (`kernel/kernel/syscall.tkb`) | 8 | Global (appears process-agnostic) | `KernelSocketFdAllocResult::Full`, own variant, own alloc path independent of `PROCESS_FD_MAX`/`unified_fd_*` | **Audit flag, not yet a confirmed bug:** this is a second, independent fd-capacity namespace layered alongside the unified fd table and the TCP connection pool, with no comment in `syscall.tkb` explaining why 8 (not 16, not `TCP_CONNECTION_MAX`) or how it composes with the other two when a single process both opens files and sockets. Needs an explicit relationship writeup or consolidation -- this is exactly the "duplicated limits" pattern issue #295's design constraints call out. |
| TCP connections | `TCP_CONNECTION_MAX` (`kernel/net/tcp.tkb`) | 2 (deliberately tiny, issue #189) | Global | `tcp_connection_alloc()` / `tcp_connection_free()`, SlotMap-backed | `TcpConnectionAllocResult::Full`, explicit variant. **Gap:** at the syscall boundary (`kernel_syscall_inetd_accept`, `kernel/kernel/syscall.tkb:716-719`) this is mapped to `KernelInetdAcceptResult::TimedOut` -- identical to a genuine network timeout. This directly violates issue #295's acceptance criterion "diagnostics can distinguish resource exhaustion from ... network timeout." |
| Pending (unacked) TCP segments | `PENDING_TCP_MAX` (`kernel/net/tcp.tkb`) | 4, per connection | Per-connection | Retry/retransmit bookkeeping array indexed by connection slot | Not yet traced; likely silently drops/ignores excess pending segments rather than surfacing a distinct result. Follow-up needed. |

## Argument bounds (not pools)

These constants cap a single syscall's argument (vector length, poll fd
count, transfer chunk size) rather than a shared, allocatable resource. They
do not have "exhaustion" in the pool sense -- they reject an individual call
with an explicit errno and there is nothing to leak or roll back.

| Constant | Value | Location | Behavior |
|---|---|---|---|
| `IOV_MAX` | 1024 | `kernel/kernel/syscall.tkb` | `readv`/`writev` with `iovcnt >= IOV_MAX` returns `LINUX_EINVAL`, matching Linux `UIO_MAXIOV` semantics. Already correctly diagnosable. |
| `POLL_MAX` | 1024 | `kernel/kernel/syscall.tkb` | Same pattern for `ppoll`'s `nfds`. |
| `MSC_MAX_TRANSFER_SECTORS` | 128 | `kernel/platform/rpi5/usb_xhci.tkb` | Caps a single USB mass-storage transfer; larger requests are split into multiple transfers by the caller, not rejected. |
| `EXT2_MAX_DIRECT_BLOCKS` | 12 | `kernel/fs/ext2/ext2.tkb` | On-disk format constant (ext2 direct-block count), not a runtime allocator. |
| `WAIT_POLL_MAX` | 10000 | `kernel/arch/arm64/kernel/user_payload.tkb` | Bounded retry-loop iteration count for `--forbid-trap`, not a resource capacity. |
| `MMU_TABLE_ENTRY_COUNT` | 512 | `kernel/arch/arm64/mm/mmu.tkb` | Hardware-fixed page-table entry count (AArch64 architectural constant). |

## Confirmed diagnosability gaps (candidates for follow-up issues)

Ranked by how directly each one reproduces the motivating HTTPd-workload
failure mode described in issue #295 (opaque failure instead of a clear
"resource X exhausted" result):

1. **Shared-object pool exhaustion reads as `EBADF`.** `unified_file_open`,
   `unified_directory_open`, `unified_listener_create`, and
   `unified_connection_create` all discard `UnifiedObjectResult::Full` down
   to the generic `UnifiedFdResult::Invalid`, which every syscall handler
   then maps to `LINUX_EBADF`. This is the literal failure mode the issue's
   motivation section describes.
2. **TCP connection-pool exhaustion reads as a network timeout.**
   `kernel_syscall_inetd_accept` maps `TcpConnectionAllocResult::Full` to
   `KernelInetdAcceptResult::TimedOut`, identical to a real accept timeout.
3. **Per-process fd-table exhaustion also reads as `EBADF`.**
   `unified_fd_alloc`'s `Full` result is mapped to `LINUX_EBADF` at the
   `openat` (and other fd-allocating) syscall handlers instead of `EMFILE`.
4. **`growable_pool_ensure` discards its own richer result type.** The
   pool already computes `GrowablePoolInsertResult::OutOfMemory` internally
   but the public `growable_pool_ensure()` entry point (used by the process
   kernel-stack pool, and potentially other growable pools) narrows it to a
   bare `bool`, erasing the distinction between "this pool's chunk ceiling
   reached" and "the global physical page allocator is out of memory."
5. **`address_space_ensure_root` collapses three independent failure
   causes** (out-of-range slot, ASID pool exhaustion, page-table backing
   allocation failure) into one `bool false`.
6. **`KERNEL_SOCKET_FD_MAX` is an unexplained second fd-capacity
   namespace** alongside `PROCESS_FD_MAX` -- needs a documented relationship
   or consolidation, independent of whether it currently causes user-visible
   failures.

## Not yet audited in this pass

- `PAGE_MAP_REF_MAX` (`kernel/mm/page.tkb`) exhaustion path.
- `SHARED_OBJECT_MAX_REFS` distinct exhaustion result (vs. `SHARED_OBJECT_MAX`).
- `PENDING_TCP_MAX` overflow behavior (per-connection retransmit queue).
- Whether any of the above pools' exhaustion is exercised by an existing
  boundary test (issue #295 requires "exhaustion tests exercise each
  allocator near its boundary"); `kernel/tests/` was not yet cross-referenced
  against this table.

## Recommended next steps

Per this project's preference for narrow, independently closeable issues
rather than one large bundle, split the fixes above into separate follow-up
issues instead of implementing all of them together:

- One issue per diagnosability gap (1-5 above), each scoped to: give the
  swallowed variant a name that survives to the syscall boundary, pick the
  correct Linux errno (`EMFILE` for fd/shared-object exhaustion, a distinct
  non-timeout result for TCP connection exhaustion), and add a boundary test
  that exhausts the specific pool and asserts on the new, distinguishable
  result.
- One issue to resolve the `KERNEL_SOCKET_FD_MAX` question (finding 6):
  determine whether it should be unified with `PROCESS_FD_MAX`/
  `unified_fd_*`, or document why it is legitimately separate.
- One issue to finish the "not yet audited" section above.
