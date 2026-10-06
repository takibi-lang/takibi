# Kernel global storage review, 2026-10-06

This is a source-level ownership and storage review of every explicit
top-level `let` in tracked kernel Takibi sources at production tree 61e778b5.
It completes declaration coverage and records a disposition for each name.
It does not prove every writer holds its required lock, establish CPU
separation/non-migration, or authorize the proposed migrations.

## Evidence and completeness

- [Access index](KERNEL_GLOBAL_ACCESSES_2026-10-06.tsv): 637 declarations in
  66 files, 611 mutable and 26 immutable; 467 private and 170 public.
- [Per-declaration dispositions](KERNEL_GLOBAL_DISPOSITIONS_2026-10-06.tsv):
  the same 637 `(file, name)` keys, each with owner, access contract,
  disposition and rationale. Families describe a storage decision, not a
  claim that all members have identical writer protocols.
- Each access-index row includes a SHA-256 of its source file, its complete
  type, explicit initializer, target-main membership, lexical access sites,
  direct-store candidates, explicit address sites and external Takibi sites.
  Sites name file, line and enclosing function body; `@-` includes signatures
  and other declarations outside function bodies.
- Both ordinary main depfiles contain all these declarations: 593 occur in
  both target closures, 21 only in QEMU's and 23 only in RPi5's. This is actual
  compilation membership, not directory-based platform attribution. Scanning
  every tracked kernel Takibi file also found no extra declaration outside
  that union, including the standalone EL0 sources and benchmark sources.
- The previous 640-name survey loses five declarations and gains two:
  syscall_ext2_mount/ready become syscall_filesystem; image ext2-state and
  target-root/set become process_image_contexts. No other key differs.

Reproduce the access index after building both ordinary kernels:

```sh
make kernelbuild
python3 scripts/inventory_kernel_globals.py > /tmp/kernel-globals.tsv
python3 scripts/inventory_kernel_globals.py --check docs/KERNEL_GLOBAL_ACCESSES_2026-10-06.tsv --dispositions docs/KERNEL_GLOBAL_DISPOSITIONS_2026-10-06.tsv
```

The script scans tracked files, omitting comments and string contents, and
balances declaration delimiters so array-type semicolons and multiline
declarations do not truncate the inventory. It is an on-demand review tool,
not a permanent build gate against a dated snapshot. Human dispositions
remain authored separately; the generator never reconstructs them from the
file it overwrites.

The index is lexical, not compiler name resolution or alias analysis. Public
names can match alternative-platform definitions, fields or local shadows;
private names are restricted to their defining file but can still be
shadowed locally. A direct-store site is a syntactic assignment candidate,
not a complete writer set. Writes through derived pointers, array decay,
slice copies, atomic helpers, stable_replace, LockedCell and generated DMA
authority code require following the indexed function. Initializer expressions
are recorded separately, not included in access-site lists. Constants,
compiler-generated globals, assembly/linker storage and debugger writes are
outside explicit-let enumeration. Named ABI consumers must be checked before
moving or deleting storage. A row without references is not a deletion proof.

## Storage decisions across the kernel

The per-name TSV is exhaustive. The table below supplies the reasoning for
the different boundaries rather than repeating hundreds of scalar names.
"Candidate" means a concrete review outcome, not approved implementation.

| Source/group | Logical owner and access evidence | Disposition |
| --- | --- | --- |
| exception_evidence | Each CPU captures terminal state; machine atomic claims choose reporting; DDB captures only after world stop. Core-0 crash names are consumed by external debuggers. | Retain fixed diagnostics and ABI. Grouping records cannot eliminate report claims or permit allocation during failure. |
| platform_uart_common | uart_set_rx_handler and the platform uart_init functions install one callback before the CPU-0 RX source is unmasked; no subsequent callback replacement is shown. | Retain one callback for one routed UART, not one callback per process/CPU. This is call-graph publication evidence, not static write-once typing. |
| secondary | kernel_secondary_boot_state_clear/CPU_ON notes control online membership; tick functions update each CPU's atomic word. | Retain machine membership and CPU-partitioned state. io spelling alone is not synchronization. |
| asid | asid_init writes width/last/ready; asid_cell protects the allocator state, with an explicit pre-MMU boot exception and stopped-peer rollover. | Retain existing guarded owner. Read-only boot geometry need not take the allocation lock. |
| block_cache | block_cache_store/touch/read maintain parallel per-CPU slot arrays; note_write/forget_all publish epochs with AtomicWord. | Candidate per-CPU slot/cache contexts; keep inter-CPU invalidation publication separate. This cache is write-through copied data, not an object owned by the requesting process. |
| block memory service | block_run_read publishes backend/first/epoch/count after transfer; block_run_take tests the current epoch; note_single tracks the next request. Device calls use TaskMutex. | Candidate read-ahead context per CPU. Do not serialize cache hits under the device lock merely to group state. |
| block fault controls | arm/disarm/hits update armed/direction/skip/sticky/count under the device guard. | Candidate fixture context, distinct from production read-ahead and device geometry. |
| virtio_blk | DTB writes base; init/reset/submit manage ready/disabled/used_seen; DMA receive ownership survives failed reset. | Device-owned metadata candidate; retain fixed backing, page/cache alignment and failed-device lifetime until its specific layout/authority review. |
| virtio_net and rp1_gem | InitOnce, RX/TX capabilities, IRQ flags/indices and boot-discovered MMIO form one device's protocol. GEM and virtio have different queue geometries. | Device contexts are reasonable owners, but no cosmetic buffer relocation or pool merger. Driver publication/completion remains a separate obligation. |
| terminal settings | initialize/apply/decode maintain settings, readiness and literal-next; output/input flow words are read independently of the process-run guard. | Candidate terminal-policy context; preserve independent atomic flow publication. |
| terminal_echo | reset/push/retire/read operate payload, indices, count and byte-expansion phase; the drop total survives reset. Kernel callers use console exclusion. | Candidate one queue context in this file. Do not merge it with RX under an assumed common lock. |
| uart_rx_ring | reset/canonical_set/push/read/erase maintain bytes, marks, columns and indices under the kernel callers' process-run lock; DDB uses quiescence. | Candidate one RX queue context. Terminal input belongs to the shared terminal, not the current reader's ProcessRecord. |
| ext2 scratch | ext2_scratch_here selects CPU-local parse buffers; ext2_write_blocks tracks transient mutation allocations. | Retain CPU partition; candidate operation context only with the non-migration/reentrancy assumption explicit. |
| ext2 recovery | settle_claim/write_abort/update_regular_file set fenced/pending blocks; recover repairs and clears them. Production mutation admission serializes the state; boot fixture runs alone. | Logical owner is the writable mount, not a CPU. Candidate mount runtime context; the current single-mount contract and copyable Ext2Mount descriptor need a design choice. |
| ext2 mutation admission | Shared mutation TaskMutex and reader-count publication govern who enters the filesystem. | Retain protocol owner. Putting the two names in a struct does not enforce reader/writer admission. |
| ext2_fixture buffers | Boot-only source/readback/bitmap buffers survive across filesystem probe calls. | Retain fixture backing; stack relocation can increase stack demand and is not a useful name-count optimization. |
| boot root image configuration | kernel_ext2_fixture_run assigns mount then readiness; test_driver resolves and assigns plan/inode/length then readiness. Child exec reads them long after boot. | First candidate: closed mount/image presence states and explicit configuration accessors, preserving permanent metadata-backed plan slices. |
| test_driver exec scratch | exec_scratch_here selects one ExecScratch per CPU, spanning resolution/prepare/assembly continuation. | Already context-owned per CPU. Keep storage separation and non-preemptible continuation distinct from grouping. |
| other test_driver globals | Resource baselines, deferred report flags, rootfs_metadata, socket/clone controls and init script parameters belong to boot/workload orchestration. | Retain fixture lifetime; rootfs_metadata must outlive the saved plan borrowing it. Never move it to a returning stack frame. |
| fd_table allocators | Three pool guards/pins, process-owned block chains and a separate shared-object refcount lock. fd_slot_total participates in the reference bound under that lock. | Retain production allocator locations. A global FD-service wrapper supplies no demonstrated new owner guarantee. |
| fd_table evidence and controls | Missing/ref-bound/double-release counters survive object teardown; fd_refcount_probe fields drive an explicit contention fixture. | Keep evidence separate from object lifetime and fixture state separate from production ownership. |
| fd_table old fallback records | fd_block_missing, fd_context_missing and unified_object_missing have no lexical use in the kernel index or scripts/lib source search. | Candidate deletion after checking generated/backend and external debugger consumers; not a reason to relax checked lookups. |
| process namespace/bootstrap | Pool, bootstrap record/live/generation, PID LockedCell, pool-ready and peer dispatch describe machine process namespace and admission. | Retain authority boundary. Process-owned waits/stacks/images/FD handles already live in ProcessRecord. Avoid a large cosmetic scheduler-context move. |
| CPU execution/activity | execution_state and kernel_activity select CPU records; hardware/assembly entry paths determine which process runs. | Retain existing CPU partition; matching caller indices is weaker than storage and non-migration proof. |
| process spare stack | scheduled_process_spare holds one PageRunOwner through mutex-guarded stable exchange. | Retain existing explicit shared reserve. It is deliberately not owned by the process whose old stack it caches. |
| process diagnostics | Missing/stale/freed/refusal/reap counters, retained trace, CPU-local exec error state and idle-starvation observations survive process transitions; some names are debugger controls. | Retain diagnostic lifetime and ABI. Grouping the last-observation tuple is possible only with its actual publication/read contract. |
| process terminal foreground | terminal_foreground_session is selected/read by process-run-guarded terminal/signal paths. | Logical terminal-owned state; migration crosses ProcessRunGuard and process-state dependencies. Keep current location until that boundary is chosen. |
| process spread timer | spread_timer fields record the specific EL0 ToIdle fixture window. | Retain fixture protocol; do not make it general scheduler policy. |
| process/syscall test evidence | One evidence struct per module, with named record/report APIs. | Already consolidated; no benefit from mixing these counters with real owners. |
| syscall filesystem | One private closed readiness context, boot configured and matched at filesystem boundaries. | Retain completed consolidation; boot publication/device lifetime still trusted. |
| syscall scratch/argv | Per-CPU scratch and indexed stable owner storage; the exec continuation is non-preemptible. | Retain partition and owner exchange. CPU separation is a distinct static-authority question. |
| syscall peer syslog flag | syscall_syslog consumes/report-once evidence on its existing path. | Retain evidence boundary; do not treat a reporting flag as filesystem configuration. |
| syscall lifecycle fixture | Connected flag uses the run lock; persistent-shell child and checkpoint flags drive named scenario predicates. | Candidate scenario context preserving those predicates and one-shot semantics. Not a production process-state migration. |
| syscall unimplemented | Atomic compare-exchange claims the first PID for each number; DDB/boot report the retained table. | Retain machine first-occurrence record; per-process storage would erase evidence at process exit. |
| profile_samples | One sampling CPU writes a fixed per-CPU prefix buffer; start/finish handle activation/support/end registers. IRQ time is invisible to the PMU sample path. | Candidate interval metadata context; retain loss accounting and fixed storage. This is an existing limited profiler, not a general FD-contention attribution tool. |
| profile_timeline | World-stopped start/finish freeze filters; IRQ-masked local hooks append to per-CPU prefix buffers. | Candidate interval/filter context; preserve CPU partitions, loss counts and snapshot rules. |
| protocol_trace | Each run-lock acquire/release observes state changes, including ones made outside the previous hold; close ends writers before reporting. | Retain ordered observer/replay contract; grouping does not prove protocol completeness. |
| workload_evidence | Named busy, peer, migration, settings and profiling scenarios have separate arming/publication and report lifetimes. | Retain scenario evidence; possible small scenario structs, without treating a whole evidence file as one protected object. |
| diagnostic_ring | Typed publish_begin/commit binds payload publication; CPU sequences remain independent. | Retain no-allocation retained storage and publication boundary. |
| intrusive_pool tag mint | LockedCell holds the machine pool-lock identity counter. | Retain one namespace; per-pool counters would change identity uniqueness. |
| occupancy/world stop | One controller issues distinct complete/partial linear tokens with nonwrapping generations. | Retain machine owner; process-owned storage would be the wrong lifetime. |
| address_space | One backing pool, permanent root0, CPU-selected active slot and missing evidence. | Retain these separate lifetimes; a single container is not a single authority. |
| page allocator | Machine RAM inventory already lives in a LockedCell; pre-MMU mint paths are explicit. Mapping-ref evidence is independently guarded. | Retain existing owner; no shadow page storage, per-process page allocator or speculative CPU front. |
| process_image | Pool and pins, permanent zero page, closed CPU operation context and teardown/missing counters. | Retain completed context migration and separate evidence/backing lifetimes. |
| socket_capability | One value-first container stores the linear RX admission authority via indexed guard/stable exchange. | Already an owned context; do not copy or merge it with TCP allocation metadata. |
| tcp | Connection/frame/retransmit pools and RetxChain, service MAC/policy, completion counts and injection controls. Payload ownership is already connection-scoped. | Retain allocators/protocol ownership; keep fault/pin-sharing fixtures distinct. Policy migration needs a real per-connection requirement. |
| QEMU GIC/UART/timer/PSCI config | boot_devices_apply_dtb and virtio DTB setup write discovered bases/INTIDs/transport before enable; IRQ/CPU_ON consume them. | Candidate boot device records and configuration APIs, not hot-path locks. PSCI's single flag alone needs no wrapper. |
| RPi5 PCI/GIC/UART/GEM/XHCI discovery | DTB apply functions jointly set addresses/status; later MMIO and DMA translation consumers include other files. | Candidate per-device discovery records; preserve pre-MMU access, default/error outcomes, DMA map sharing and diagnostics. |
| RPi5 XHCI/BOT runtime | Slot/endpoint/ring indices/cycles, transfer results, BOT tag/configuration, ready/unusable/attempted state and DMA arrays describe one host and storage device. | Context metadata is a candidate; fixed DMA backing and generated authority cannot move as ordinary fields without review. |
| USB provision | Embedded root image and bounded transfer buffers serve boot provisioning. | Retain boot storage and fixed workload; do not add runtime instance infrastructure. |
| console_lock | One IRQ-masking output mutex; measurement fields updated under the same guard. | Retain singleton device admission. Measurement grouping would be cosmetic; emergency reporters must keep their escape. |
| printk log | Retained atomic record arrays, CPU assembly state, peer-published mailboxes, tagged terminal TX queue and separate report counters. | Candidate several contexts matching these actual protocols, not one lock/container for all 51 names. |
| immutable ELF/network/wire/decimal bindings | Fixed parser offsets, MAC/IP and formatting data. ELF_IDENT_MAGIC is mutable spelling with no indexed assignment after initialization. | Retain constants; optional spelling/unused-offset cleanup is not mutable-state ownership work. |
| all contention modules and occupancy_drain | Every declared name has access evidence and a disposition row. Arming/ready/go/done, forged unlocked controls, fixture pools and retained owners drive individual protocols. | Retain fixture separation. Consolidation can be local to a scenario but is lower priority than production state boundaries. |

## Where OS precedents change the recommendation

These are structural precedents, not measurements or claims of equivalent
functionality. Linux sources are pinned to v6.12. BSD sources identify the
releng/15.0, netbsd-10 and OpenBSD master branches as reviewed; moving branch
links are not immutable release snapshots.

### Terminal state

Linux's [n_tty_data](https://github.com/torvalds/linux/blob/v6.12/drivers/tty/n_tty.c)
holds read/echo buffers, cursors and canonical/edit state; it is reached through
tty->disc_data and has distinct read/output locking. FreeBSD's
[tty](https://github.com/freebsd/freebsd-src/blob/releng/15.0/sys/sys/tty.h)
holds termios and tty input/output queues. NetBSD's
[tty](https://github.com/NetBSD/src/blob/netbsd-10/sys/sys/tty.h) and OpenBSD's
[tty](https://github.com/openbsd/src/blob/master/sys/sys/tty.h) likewise carry
termios and raw/canonical/output queues as device state.

This supports terminal-owned queue/policy contexts rather than ProcessRecord
fields. It does not support combining Takibi's RX run-lock domain and echo/TX
console-lock domain. A safe first consolidation stays in each defining file,
keeps the global singleton instance and public API, and does not mint access
from a new shared helper that hides which guard was required.

### Filesystem recovery and boot mount publication

Linux's [ext2_sb_info](https://github.com/torvalds/linux/blob/v6.12/fs/ext2/ext2.h)
is filesystem-instance metadata including mount state and locks. FreeBSD's
[ext2mount](https://github.com/freebsd/freebsd-src/blob/releng/15.0/sys/fs/ext2fs/ext2_mount.h)
holds the mount/device/filesystem information. NetBSD's
[ufsmount](https://github.com/NetBSD/src/blob/netbsd-10/sys/ufs/ufs/ufsmount.h)
and OpenBSD's
[ufsmount](https://github.com/openbsd/src/blob/master/sys/ufs/ufs/ufsmount.h)
hold filesystem-instance data, including their ext2 representation.

These support making recovery state belong to a mount rather than a CPU. They
do not provide Takibi's pending-block rollback algorithm, nor justify adding
multiple mount instances. The smallest present choice is a private runtime
context for the existing single writable filesystem with the current admission
contract. A general per-mount allocation/identity API is a larger, unselected
design. Boot descriptor readiness is a separate, cheaper consolidation.

### Devices and machine namespaces

Linux's [virtio_blk](https://github.com/torvalds/linux/blob/v6.12/drivers/block/virtio_blk.c)
holds per-device state and a separately synchronized virtqueue array;
[xhci_hcd](https://github.com/torvalds/linux/blob/v6.12/drivers/usb/host/xhci.h)
holds host-controller state and pointers to rings/device contexts. These
support device ownership, not nesting Takibi's fixed aligned DMA allocations
under an arbitrary leading lock. Start with discovery/status metadata only
when an actual configuration API needs the record.

Linux's [AArch64 ASID allocator](https://github.com/torvalds/linux/blob/v6.12/arch/arm64/mm/context.c)
retains a global allocation namespace and CPU-partitioned active/reserved
ASIDs. This corroborates keeping the machine namespace while separating local
hardware state. It does not replace Takibi's stopped-peer rollover rule.

The FD allocator comparison in the previous source review remains applicable:
Linux and BSD keep individual typed allocation handles/pools. Packing the
three Takibi allocator bodies into a service struct is not required to match
their ownership structure. Current RegionPool bodies are 24 bytes; retaining
them does not depend on the obsolete 16-byte estimate.

## Subsequent implementation assessment

The source inventory above is the pre-migration snapshot and keeps its original
source hashes. The completed storage/state change is measured in
[KERNEL_GLOBAL_MIGRATION_2026-10-06.md](KERNEL_GLOBAL_MIGRATION_2026-10-06.md).
Current ownership is described in `kernel/RUNTIME_STATE.md`.

The maintainer selected deletion of the three dead FD payloads and migration
of boot mount/image state. Remaining candidates below are review findings,
not queued implementation: grouping private terminal or cache globals has
no demonstrated new safety or space benefit; generalized mount/device owners
are YAGNI under current functionality. Existing machine namespaces, CPU
partitioning, locks, DMA storage and retained debugger state remain justified.

## Original candidate ordering

1. Validate and remove the three unused FD fallback payload declarations.
   This is actual redundant storage, not name grouping; no performance
   measurement is required, but generation/backend/debugger consumers must
   be excluded before implementation. It is independent of the three pools'
   deferred allocation/access measurements.
2. Consolidate the boot mount/readiness and saved image tuple into closed
   states with private accessors. This removes independently mutable tuple
   members and broad public writes. Retain rootfs_metadata permanently and
   preserve both syscall and initial-process configuration outcomes. One
   global boot-service context remains; multiple filesystem support is not
   required.
3. Consolidate RX and echo queue records separately within their existing
   files, followed by terminal policy. Existing guards and single-device
   lifetime remain; no extra locks or cross-file private access. Name-count
   reduction alone is not a new synchronization guarantee.
4. Consolidate block-cache/read-ahead metadata by CPU/slot. Keep copied data
   and atomic invalidation ordering, and evaluate layout before claiming a
   space benefit. Preemption-disabled CPU authority remains a separate
   prerequisite for a preemptible access contract.
5. Decide the single writable mount's recovery context and boot-device
   configuration APIs. These need specific ownership/publication choices,
   not a giant kernel context or general multi-device framework.
6. Consider interval/fixture and log subcontexts only at their protocol/ABI
   boundaries. Scheduler and failure-path cosmetic relocation is last;
   existing locked/stable owners and retained diagnostics have stronger
   reasons to remain than a lower global-name total.

The ordinary linked QEMU and RPi5 ELF symbol tables both retain
fd_block_missing at 400 bytes, fd_context_missing at 72 and
unified_object_missing at 80, totaling 552 bytes of BSS. The source index and
the separate compiler/scripts/kernel search find only their declarations.
Reproduce the linked observation with `llvm-nm-19 --print-size` on each
kernel/build/{qemu,rpi5}/kernel.elf. This is evidence of removable symbol
payload, not a prediction that image reservation decreases by 552 bytes:
alignment and live references in generated or external consumers still need
checking. No declaration was removed during this review.

No implementation, space improvement or lock-contention improvement is
claimed by this inventory. The reviewed source/storage workload is unchanged,
so its publication can reuse the current source-bound space checkpoint. Any
later storage/owner migration must review its own footprint at the milestone.

## Remaining trust and review limits

Global-name removal is not static prevention by itself. Private fields confine
writes to one file; closed states couple presence to payload; indexed guards
and borrowed owners constrain some access lifetimes. CPU-id selection,
non-migration across assembly, boot ordering, valid authority minting, DMA
cache/device completion and debugger access remain their named boundaries.
The lexical index does not prove any of them. Existing bounded protocol models
are bounded evidence, not an exhaustive alias or synchronization audit.

For a migration, re-open the access sites for its exact names and follow every
pointer/borrow/helper and external symbol consumer. The exhaustive declaration
and disposition coverage here prevents silently skipping a group; it does
not turn an unreviewed indirect writer into a read-only declaration.
