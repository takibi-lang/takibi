# Kernel resource limits

This is the single authoritative inventory of the fixed-capacity pools and
namespaces used by kernel runtime code, per GitHub issue #295. Each fixed
`_MAX`/`_COUNT` constant that bounds a real runtime resource (a process, a
descriptor, a page, a connection, ...) is listed here with its scope,
allocation/release path, and its *current* exhaustion behavior. Constants
that only bound a syscall argument (not a shared pool) are listed separately
under "Argument bounds (not pools)" for completeness, since `grep -r MAX`
does not distinguish the two.

This file records the state of the kernel as of 2026-08-24. When a limit or its exhaustion behavior changes, update this
file in the same commit -- do not let it drift into a stale snapshot.
Individual source files still carry the detailed sizing rationale (issue
numbers, workload history); this file exists to answer "what is the actual
number and what happens when it runs out" for every pool from one place,
per issue #295's "single authoritative capacity definition" constraint.

## Resource pools

Every pool identified by the audit now has an explicit, distinguishable
exhaustion result and a boundary test proving it. None remain unaudited.

**No pool below has a hand-picked capacity any more** (2026-08-24, issues
#391/#393/#402 finishing what #257/#392/#401/#406 started). What is left in
the Constant column is one of three things: a per-process limit the process
itself can change (`RLIMIT_NOFILE`), a bound DERIVED from something that
exists (memory, descriptor slots, address spaces), or `BOOT_PAGE_COUNT` --
which is not a ceiling on a pool but this kernel's inventory of the RAM it
manages. Issue #422 owns making that number the RAM that is actually
there; #250 (decode the true installed total on RPi5) and #252 (let a
refinement bound be fixed once at boot) are what it rests on.

| Resource | Constant | Value | Scope | Alloc / release | Exhaustion result |
|---|---|---|---|---|---|
| Scheduled processes | **no constant -- removed** (`kernel/kernel/process.tkb`) | unbounded; the page allocator is the only limit | Global pool | `scheduled_process_alloc()` / `scheduled_process_reap()`; `IntrusivePool(ProcessRecord)`-backed, generation-checked | Was `KERNEL_PROCESS_MAX` = 16 -- the array size of the process table and, through four restatements of the same number, of every per-process table beside it. A process record is a pool allocation now and a process slot is that allocation's ADDRESS, so `ScheduledProcessAllocResult::Full` means the page allocator is empty, not that a sixteenth slot was taken. The bootstrap is the one exception and is a static record named by slot value `0`, because root 0 exists before the MMU is on; `scheduled_process_alloc_bootstrap()` is its own entry point so that nothing else can take it by accident. Boundary-tested by `scheduled_process_table_probe`, which now proves the opposite of what it proved: 24 concurrent processes past the old ceiling, each with its own kernel stack run, and every record given back afterwards. |
| Kernel stacks (per process) | `KERNEL_PROCESS_STACK_SIZE`, one page run per live process | **16384 B/slot** = `KERNEL_STACK_PAGES` x `PAGE_SIZE`, in a 32768 B run allocated on the slot's first use | Global, one per live process | `page_alloc_contiguous(KERNEL_STACK_RUN_PAGES)` inside `scheduled_process_alloc()`, or the one-deep spare a reaped process left behind. A run is PARKED at reap rather than freed: measured, 18 of the 35 reaps in one QEMU boot run ON the stack they are reaping, so returning those pages there hands the allocator the memory under the caller's own feet. Parking a second run gives the first one back, after checking the caller is not standing on it. | Returns `PageRunAllocResult::OutOfMemory`, which `scheduled_process_alloc` reports as physical-page exhaustion -- the pool's own ceiling is gone, since there is no per-pool chunk limit any more, only the page allocator's. Boundary-tested by `scheduled_process_table_probe`, which allocates 24 concurrent processes and checks each stack is distinct and ends exactly on a run boundary. **Measured high-water mark: 4368 B of 16384** (`kernel_stack_watermark_report`), against 3968 of 3968 -- saturated, i.e. a floor rather than a measurement -- before the stack was resized. That 400-byte gap is why issue #373's overflow was real and not bad luck. The stack is the UPPER half of its run; the lower half is poisoned, belongs to the same run, and is handed to nobody, so an overflow is contained instead of reaching a neighbouring page, and `kernel_stack_overflow_bytes` reports how far past the end it went. `kernel_stack_guard_check` fail-stops on either witness. For calibration, Linux's `THREAD_SIZE` is 16K on arm64 and FreeBSD's `kern.kstack_pages` defaults to 4; interrupts still share this stack, so it carries two worst cases. |
| Address-space roots | **no constant -- removed** (`kernel/mm/address_space.tkb`) | unbounded; the page allocator is the only limit | Global pool | `address_space_backing_ensure()` on demand and from `scheduled_process_alloc()`; `IntrusivePool(AddressSpaceBacking)`-backed | Was `ADDRESS_SPACE_MAX` = 16, a restatement of `KERNEL_PROCESS_MAX`. That file is parsed BEFORE `process.tkb`, so it cannot name `KERNEL_PROCESS_MAX` in a bound at all -- it asks `scheduled_process_slot_valid()` instead, which is a function and therefore resolves regardless of file order. `AddressSpaceEnsureResult` lost `AsidExhausted` with issue #402 and is now `{SlotOutOfRange;OutOfMemory;Ok}`: the ASID pool was the only fixed ceiling left on this path, and it rolls over rather than running out. |
| User virtual address space (per address-space root) | `USER_SPACE_PAGE_COUNT` (`kernel/mm/address_space.tkb`) | 262144 pages (1 GiB) | Per-process | Bounds check only (`scheduled_process_slot_valid(slot) == false \|\| index >= USER_SPACE_PAGE_COUNT`) | Not a depletable pool in practice (no workload maps close to 1 GiB); out-of-range access returns `false` from the relevant accessor. Static bound, intentional; no change needed. |
| ASIDs | **no constant -- recycled by rollover** (`kernel/arch/arm64/mm/asid.tkb`) | width from `ID_AA64MMFR0_EL1.ASIDBits`; both targets report 16-bit, so 65535 assignable numbers | Global | `asid_assign()` at the one moment a root is activated; nothing is ever freed | **This was the last fixed ceiling on the process-creation path, and issue #402 removed it in the two halves that issue named.** The width is asked for rather than assumed -- `TCR_EL1.AS` is set to match in `kernel_mmu_activate`, because the two have to agree or the hardware compares fewer bits than the software writes. And a number is reclaimed by ROLLOVER: assignment is a counter, and passing the last number advances a generation, invalidates every TLB entry and restarts at 1. An address space whose recorded generation was left behind no longer owns its number and is given a fresh one at its next activation, which is the only moment a root reaches TTBR0_EL1 and therefore the only moment handing out a recycled number is safe -- so a root is now created with NO ASID (the lifetime Linux gives an mm) instead of taking one at creation, where a rollover would have aliased a running address space's TLB entries with the new one's. `asid_assign()` cannot fail: `AsidAllocResult::Full` and `AddressSpaceEnsureResult::AsidExhausted` are both gone rather than merely unreachable, since a variant nothing can return makes every caller keep an arm that says something untrue. Boundary-tested by `address_space_asid_rollover_probe`, which drives the real allocator past its last number and proves the generation advances exactly once, numbering restarts at 1, every earlier stamp goes stale, and the running root gets a current number back. What it costs is one whole-TLB invalidation per 65535 assignments, counted by `asid_rollover_count_value()`. |
| Process page-table root registration | **no constant -- removed** (`kernel/mm/process_image.tkb`) | unbounded; the page allocator is the only limit | Global pool | `process_image_record_ensure()` from `scheduled_process_alloc()` and on demand; `IntrusivePool(ProcessImageRecord)`-backed | Was `PROCESS_IMAGE_ROOT_MAX` = 16, a restatement of `KERNEL_PROCESS_MAX` rather than an independent limit. Released by `scheduled_process_reap()`/`scheduled_process_table_clear()`, except for root 0 -- the permanent bootstrap root, whose image state is established once and read on every later stack fault, the same exemption `address_space_release_root` already makes one layer down. It did not always release: the array it replaced kept a root's entry for the life of the kernel, so the lifetime change was made deliberately and separately from the storage change. Making it release moved the installed exec image's teardown into `scheduled_process_reap` too, since that is the last moment the record still exists; only putting the parent's root back in TTBR0 stays at the parent's return. `scheduled_process_table_probe` is the detector: 24 processes allocated and cycled must leave the image-record pool holding exactly what it held before. Exhaustion is reported through `ScheduledProcessAllocResult::Full` at process creation; a record needed mid-operation that cannot be allocated falls back to a counted shared record, and the count is printed at the end of the boot suite (it is 0). |
| Physical pages | `BOOT_PAGE_COUNT` (`kernel/mm/page.tkb`) | 204800 pages (800 MiB) | Global | `page_alloc()` / `page_free()`, SlotMap-backed | `PageAllocResult::OutOfMemory`, explicit, well-named variant -- already the best-diagnosed pool in the kernel; needed no change. Its downstream callers (`page_alloc_contiguous` for kernel stacks, `address_space_allocate_root`) no longer discard this distinction. |
| Page-mapping reference count (COW fork fan-out) | **no constant -- computed** (`kernel/mm/page.tkb`) | `address_space_live_count()` = live address-space backings + 1 for root 0's static | Global, per physical page | `page_mapping_retain_physical(physical, limit)` / release via page free, called from `process_image.tkb`'s clone (fork) path | Was `PAGE_MAP_REF_MAX` = 4194304: `KERNEL_PROCESS_MAX x USER_SPACE_PAGE_COUNT`, an inventory of every PTE that could exist, until #392 removed the process ceiling and left it a bare number. **Not a capacity** -- `map_refcount` is one `usize` per page whatever the bound says. #406 replaced it with the TIGHT bound instead of the faithful-but-vacuous one: a page is mapped into an address space at most once, so it cannot be mapped into more address spaces than exist -- around 2-24 here rather than 4.2 million. That rests on an assumption worth stating: no path in this kernel maps one physical page twice within one address space. Exceeding it is an invariant break, not exhaustion; `process_image.tkb` -- the one real mapping path, and therefore where it is recorded -- logs and counts it and still rolls the clone back, and the boot suite reports POSITIVELY (`resources: page mappings within the address spaces that exist`). `PageMappingRetainResult{NotMapped;RefCeilingReached;Retained}` is unchanged. Boundary-tested by `page_mapping_ref_ceiling_probe`, which proves the bound TRACKS: refused at it, allowed one below, then one more address space makes the same refused retain succeed. |
| Per-process descriptor namespace | **no constant -- per-process, settable** (`kernel/kernel/fd_table.tkb`) | `RLIMIT_NOFILE`, initially soft 1024 / hard 4096 | Per-process | `unified_fd_alloc()` / `unified_fd_close()`; storage is an `IntrusivePool(FdBlock)` chain grown on demand | Was `PROCESS_FD_MAX` = 16, one global compile-time number shared by every process, so no process could be given a smaller limit than another and none a larger one -- a Linux-visible behaviour difference, not only an internal ceiling (issue #393). What replaces it is the pair Linux uses. The STORAGE grows: a descriptor lives in an `FdBlock` of `FD_BLOCK_SLOTS` = 16 entries, blocks are chained off the process's own context and allocated when a descriptor is installed, so a process pays for descriptors it opens rather than for descriptors it might open, and the page allocator is the only thing that runs out (`UnifiedFdInstallResult::NoMemory` -> `LINUX_ENOMEM`, the errno Linux's own `expand_files()` returns). The LIMIT is `RLIMIT_NOFILE`: per-process, inherited by fork, preserved across exec, and read/written by `prlimit64(2)` -- the only rlimit syscall arm64 has. The initial 1024/4096 are Linux's own `INR_OPEN_CUR`/`INR_OPEN_MAX`; they size no storage, and there is no equivalent of Linux's `fs.nr_open` above them because no flat table's size has to bound a descriptor number. `UnifiedFdAllocResult::Full` still means EMFILE, still logged via `kernel_boot_log_resource_exhausted` -- which now prints the limit that actually refused the call, since two processes can be refused at different numbers. Boundary-tested by `unified_fd_table_growth_probe`: 40 descriptors past the old ceiling of 16, then the same table refused at a lowered limit and admitted again at a raised one. **The incident worth remembering about this number** (issue #295 finding 6, and why #409 later removed the second name for it): `kernel/kernel/syscall.tkb` carried a `KERNEL_SOCKET_FD_MAX` that was a hand-written `8` while this table was 16, so `socket()`/`accept()` reported resource exhaustion for fd>=8 while free slots existed -- a wrong refusal rather than a compile error, hit by a shell whose first eight descriptors were already busy. #295 made it a real reference, #409 deleted the second name, and #393 removed the number itself. |
| Process contexts (fd table + heap state) | **no constant -- removed** (`kernel/kernel/fd_table.tkb`) | unbounded; the page allocator is the only limit | Global pool | `unified_fd_context_ensure()` from `scheduled_process_alloc()`, released by `scheduled_process_reap()`; `IntrusivePool(ProcessFdContext)`-backed | Was `PROCESS_CONTEXT_MAX` = 16, which was a restatement of `KERNEL_PROCESS_MAX` rather than an independent limit -- there can be no more fd contexts than processes. Removing it is a step of the work removing `KERNEL_PROCESS_MAX` itself: a context is no longer an element of an array keyed by process slot, so it no longer has to die with the slot's index. `IntrusivePoolInsertResult::OutOfMemory` surfaces as `ScheduledProcessAllocResult::Full` through the same rollback chain as the kernel stack and the address-space root. |
| Shared kernel objects (files, dirs, listeners, connections, terminals) | **no constant -- computed** (`kernel/kernel/fd_table.tkb`) | `unified_object_max_files()` = pages x (page bytes / 1024) / 10 = 81920 | Global | `unified_object_alloc_first()` via `IntrusivePool(SharedObject)`; released when the last descriptor closes | **This was the exact failure mode issue #295 was filed over, and issue #391 removed the ceiling behind it.** It was `SHARED_OBJECT_MAX` = 16 open file descriptions system-wide, backed by a `RefcountSlotMap(16)` with the records in an `[SharedObject; 16]` beside it -- the one ceiling in this kernel that was a genuine resource limit rather than a restatement of the process table's, and a shell running a pipeline over a few files was not far from it. What #391 recorded as the blocker was the second dimension: `RefcountSlotMap` exists because this resource has several independent holders, and `IntrusivePool` has one generic argument and nothing to say about refcounts. The way out is Linux's own -- the count belongs to the object (`struct file.f_count`), so `SharedObject` carries `refs` and what is left for the container to provide is identity. The system-wide bound that replaces the constant is Linux's too: `fs/file_table.c`'s `files_maxfiles_init()`, one open file description per 10 KiB of RAM, computed from this kernel's own page count rather than picked (Linux's extra `NR_FILE` floor is an order of magnitude below the derived value here, so it is not reproduced). The caller contract is deliberately unchanged: the five open/create entry points still return `UnifiedOpenResult{Invalid;Full;Ok}`, `openat` still maps `Full` to `LINUX_ENFILE` and the socket paths to `LINUX_EAGAIN`, and each still logs the cause. What changed is when `Full` can happen: at the derived ceiling, or when the page allocator is empty. Boundary-tested by `unified_object_pool_probe`, which proves the OPPOSITE of what `unified_object_pool_exhaustion_probe` proved -- 24 concurrent objects past the old ceiling of 16, each its own storage, a freed object's address refused afterwards on the generation, and the pool holding exactly what it held before. |
| Shared-object reference count | **no constant -- computed** (`kernel/kernel/fd_table.tkb`) | `unified_object_ref_bound()` = `fd_slot_total`, the descriptor slots that exist | Global, per shared object | Passed to `unified_object_retain` at each retain (`unified_fd_install`/`unified_fd_duplicate`/`unified_fd_clone`) | Was `SHARED_OBJECT_MAX_REFS`: `KERNEL_PROCESS_MAX * PROCESS_FD_MAX` (256) until #392 removed the process ceiling, then a picked 4096. **It is not a capacity** -- it sizes no storage, and `RefcountSlotMap` no longer carries a `MAX_REFS` parameter at all. What it catches is a reference LEAK. Every reference is held by one descriptor slot, so the number of descriptor slots in existence is an EXACT bound, and #401 computes it instead of picking it. Exceeding it is therefore an invariant break, not exhaustion: `fd_table` logs it as one and counts it, the callers still refuse and map to `LINUX_EMFILE` (a bound computed for the first time should not be able to halt the kernel; promoting it to a fail-stop is a one-line change once trusted), and the boot suite reports POSITIVELY -- `resources: shared-object refs within the descriptor slots that exist` -- so a boot where it happened loses a view line rather than gaining an unmatched one. Boundary-tested by `unified_object_ref_ceiling_probe`, which now proves the bound TRACKS: fill it exactly, be refused one past it, add a process, be allowed exactly `PROCESS_FD_MAX` more. |
| TCP connections | **no constant -- removed** (`kernel/net/tcp.tkb`) | unbounded; the page allocator is the only limit | Global pool | `tcp_connection_alloc()` / `tcp_connection_free()`, `IntrusivePool(TcpConnection)`-backed | Was `TCP_CONNECTION_MAX` = 2 (deliberately tiny, issue #189), `SlotMap`-backed. Issue #257 removed the ceiling itself rather than raising it: a connection is a pool slot, its three frames and its unacknowledged segments are pool slots too, and nobody picks a number. **The caller contract is deliberately unchanged** -- `TcpConnectionAllocResult::Full` is still an explicit variant, `kernel_syscall_inetd_accept` and the `accept4` handler still log exhaustion distinctly via `kernel_boot_log_resource_exhausted` before returning the existing `TimedOut`/`LINUX_EAGAIN`, and the *externally visible* retry behaviour is still the one this accept path's timing has always needed. What changed is when `Full` can happen: only when the page allocator is empty. Boundary-tested by `tcp_connection_pool_probe`, which now proves the OPPOSITE of what `tcp_connection_pool_exhaustion_probe` proved -- five concurrent connections past the old ceiling of 2, each its own storage, a freed connection's address refused afterwards on the generation, and every page given back. |
| Pending (unacked) TCP segments | **no constant -- removed** (`kernel/net/tcp.tkb`) | unbounded; the page allocator is the only limit | Per-connection chain off one global queue | `pending_tcp_record()` / acked-segment removal | **Was `PENDING_TCP_MAX` = 4 per connection, and was a real silent-corruption bug before that** -- `pending_tcp_find_free_slot()`/`pending_tcp_record()` used to fall back to slot 0 when all 4 were occupied and unconditionally overwrite whatever occupied it, clobbering an unrelated in-flight segment's still-unacknowledged retransmission record. Issue #295 fixed that by reporting "not tracked" instead of claiming a victim slot. Issue #257 then removed the ceiling itself: an in-flight segment is a `RetxEntry` allocated from a `kernel/lib/intrusive_pool.tkb` pool and chained, so nobody picks a number. The caller contract is deliberately unchanged -- `pending_tcp_record` still reports "not tracked" (0, where the sentinel used to be -1), the segment is still sent either way, and both callers still guard their deliberate-drop test injection on getting a real entry. What changed is when that can happen: only when the page allocator is empty, not at a hand-picked 4. Boundary-tested by `pending_tcp_chain_probe`, which now proves the OPPOSITE of what the old probe proved -- five outstanding segments past the old ceiling, each keeping its own record and in order, and one connection's reset leaving another's alone. |

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
   failure mode the issue was filed over. **Superseded 2026-08-24 (#391):**
   the constant is gone rather than better-diagnosed at its boundary. The
   result type this finding established is what made that safe to do --
   `Full` already had a caller contract, so removing the ceiling changed
   only how rarely it is seen.
2. TCP connection-pool exhaustion (`TCP_CONNECTION_MAX`) now logs distinctly
   from an ordinary accept timeout, without changing retry behavior.
3. Per-process fd-table exhaustion (`PROCESS_FD_MAX`) no longer reads as
   `EBADF` -- fixed via `LINUX_EMFILE`. **Superseded 2026-08-24 (#393):**
   the constant is gone; EMFILE now reports a per-process `RLIMIT_NOFILE`
   the process itself can change, which is what EMFILE means on Linux.
4. `growable_pool_ensure` no longer discards its richer result type -- fixed
   via `GrowablePoolEnsureResult`. (That pool has since left `kernel/`
   entirely: kernel stacks were its only consumer, and they outgrew a
   one-page chunk.)
5. `address_space_ensure_root` no longer collapses three failure causes into
   one bool -- fixed via `AddressSpaceEnsureResult`.
6. `KERNEL_SOCKET_FD_MAX` was an unexplained, too-small second fd-capacity
   ceiling -- fixed by raising it to match `PROCESS_FD_MAX` (it never had
   backing storage of its own). **Superseded 2026-08-24 (#409):** the
   second name is gone entirely; the socket paths name `PROCESS_FD_MAX`.
7. `PAGE_MAP_REF_MAX`'s `page_mapping_retain_physical()` collapsed a real
   invariant violation and the (practically unreachable) actual ceiling into
   one bool -- fixed via `PageMappingRetainResult`. **Superseded 2026-08-23
   (#406):** the constant is gone; the bound is the number of address
   spaces that exist, and exceeding it is an invariant break.
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
   silently dropped either. **Superseded 2026-08-20 (issue #257):** the
   constant is gone rather than better-behaved at its boundary. The
   contract this finding established is what made that safe to do -- the
   callers already handled "not tracked", so removing the ceiling changed
   only how rarely they see it.

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
pool in this file that still HAS a boundary has a dedicated boundary test:

- `scheduled_process_table_probe` (24 processes past the old `KERNEL_PROCESS_MAX`)
- `address_space_asid_rollover_probe` (the ASID generation -- was `asid_pool_probe` against `ASID_MAX` until issue #402 removed the constant; proves the rollover past the last number rather than a refusal at it)
- `unified_object_pool_probe` (the shared object pool -- was `unified_object_pool_exhaustion_probe` against `SHARED_OBJECT_MAX` until issue #391 removed the constant; proves the pool goes PAST the old ceiling rather than reporting exhaustion at it)
- `unified_fd_table_growth_probe` (the per-process descriptor namespace -- was `unified_fd_table_exhaustion_probe` against `PROCESS_FD_MAX` until issue #393 removed the constant; proves 40 descriptors past the old ceiling and that the refusal follows this process's own `RLIMIT_NOFILE`)
- `tcp_connection_pool_probe` (the connection pool -- was `tcp_connection_pool_exhaustion_probe` against `TCP_CONNECTION_MAX` until issue #257 removed the constant; proves the pool goes PAST the old ceiling rather than reporting exhaustion at it)
- `pending_tcp_chain_probe` (the retransmit queue -- was
  `pending_tcp_exhaustion_probe` against `PENDING_TCP_MAX` until issue
  #257 removed the constant; still drives the queue directly rather than
  through real TCP timing, since reaching these states via genuine
  network loss/retry would require a materially larger QEMU-peer-driven
  test, but it now proves the queue goes PAST the old ceiling rather
  than reporting exhaustion at it)

Eight resources have no entry here because they no longer have a ceiling
to test at. `TCP_CONNECTION_MAX` and `PENDING_TCP_MAX` (#257) are covered by
the past-the-old-ceiling probes above, and so is the process table itself
now that `KERNEL_PROCESS_MAX` is gone -- `scheduled_process_table_probe`
runs 24 concurrent processes where 16 was the number. The three per-process
records pooled earlier in #392 -- fd contexts, image records, address-space
backings -- never had a number of their own to exceed (each was a
restatement of the process ceiling), so what is checked for them is that
they are genuinely pooled rather than silently falling back: all three
counted fallbacks -- the process record's, the image record's and the
address-space backing's -- are printed at the end of the boot suite and are
0.

Covered since 2026-08-24 (issue #414) for ONE of its five failure points,
and worth knowing how -- and why the other four are still open: the
ROLLBACK path when one of those allocations fails inside
`scheduled_process_alloc`.
The arrays they replaced could not fail, so the whole chain is a failure
mode the pooling introduced, and reaching it honestly needs the page
allocator genuinely empty -- 800 MiB of it, which no probe does.
`make kernelcheck-alloc-rollback-qemu` empties the free list from the
debugger side for the duration of ONE acquisition
(`address_space_allocate_root`, past the process record and the kernel
stack run) and puts it back at the exhaustion log call the failing arm
makes before it rolls anything back, so the lane injects one failure rather
than poisoning the run. The verdict is this kernel's own end-of-run
accounting: `resources: pooled per-process records back to the baseline`
(the record, the address-space backing, the image record and the fd
context all came back), `resources: pages=0` (the stack run was parked and
the root's tables freed), and `resources: no double free`.

**Two things that lane found, both of which it exists to find.** The
address-space BACKING record was never released at all -- "Nothing
releases", `address_space.tkb` said, inherited from the array it replaced
in #392 -- so one record leaked per process ever created, invisible to the
page check because a pool keeps its chunk page either way. And
`page_mapping_ref_ceiling_probe` had been depending on that leak: it needs
two live address spaces to have a below-the-ceiling case, and was reading
35 where the real number was 1.

**What is still not covered**: the other four acquisitions in the chain --
the process record, the kernel stack run, the image record and the fd
context. Not for want of a breakpoint: emptying the free-list head is a
clean injection only for single-page `page_alloc`, which is what the
address-space root uses. Every other one reaches `page_alloc_contiguous`,
which finds pages by scanning `meta[].occupied` rather than through the
free list -- so an emptied list sends it down its QUARANTINE path, which
reports `OutOfMemory` as wanted but deliberately leaks up to `count` pages
on the way, and the lane would then report a rollback bug that is really
the injection's own damage. Issue #414 records the options for a poke that
does not do that.

The pooled-record baseline that catches this is taken BEFORE the probes
(the page baseline is taken after them, for the parked-run reason its own
comment gives), because the probes are where this boot allocates and
releases processes in bulk -- a baseline after them would put the most
interesting acquisitions of the run outside the measured window. That is
not a hypothetical: armed at the first process creation of the boot, the
lane passed with a rollback step deliberately deleted.
- `unified_object_ref_ceiling_probe` (the computed reference bound -- a
  real 256-iteration retain loop, not a shortcut)
- `page_mapping_ref_ceiling_probe` (the computed mapping bound -- writes the
  pool's own `map_refcount` field directly to reach the 4.2M boundary
  without looping that many times, since only the boundary CHECK, not the
  increment mechanism, needed proving here)

No pool in this file is without a boundary test.
