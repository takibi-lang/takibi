# Kernel global-state review

This records the first survey and filesystem migration, dated 2026-10-05. It is
not a completed synchronization audit or an authorization to move every
object into one context. The declaration snapshot is
[KERNEL_GLOBALS_2026-10-05.tsv](KERNEL_GLOBALS_2026-10-05.tsv).

## Survey boundary

The input is the union of the QEMU and RPi5 ordinary main-object depfiles
from the clean build of 2ae18260. It contains 118 compiled Takibi source
files. Every column-zero top-level let declaration in those files is
listed: 640 declarations, 614 mutable bindings and 26 immutable bindings.
Constants, compiler-generated pool helpers, assembly objects and separately
compiled EL0 payloads are outside this declaration survey. A declaration
count is neither a linked-memory footprint nor a live-object count.

The storage_shape column is a syntactic first pass, not a concurrency
claim. Its disjoint categories, applied in this order, are:

| Shape | Declarations | What the classification establishes |
| --- | ---: | --- |
| pool | 12 | RegionPool or IntrusivePool object declaration |
| cpu-shaped | 59 | declared type mentions KERNEL_MAX_CORES |
| synchronization | 44 | type names LockedCell, Mutex, InitOnce, AtomicWord or GuardedField |
| immutable-binding | 26 | binding is not mutable |
| other-state | 499 | remaining state needs the subsystem review below |

A cpu-shaped array does not prove CPU/storage separation or non-migration.
A lock-shaped declaration does not prove the fields it protects, and a
mutable ready flag is not classified as write-once without reading its
writers. Array types in the snapshot include their full element/count
expressions. The dated line numbers describe this snapshot only.

Fourteen contention/occupancy fixture modules account for 145 declarations.
The twelve direct pool declarations include nine production pools and three
fixture pools; the boot allocator's LockedCell(BootPagePool) is classified
under synchronization rather than direct pool storage.

## Reviewed boundaries and proposed disposition

| Group and concrete examples | Existing authority or execution contract | Proposal |
| --- | --- | --- |
| Shared object pools: the three TCP pools, backing/image/FD records, FD blocks and shared objects | typed pool guards and checked slots/pins; process ownership for per-process mutation | retain shared allocation authority; consider a private context field for each subsystem, without merging locks or changing slot layout |
| Scheduler pool and bootstrap record | run guard, running/owner makers, permanent root 0; assembly and debugger consumers | migrate last, together with the stored-authority boundary; preserve the bootstrap and named entry ABI |
| Boot page pool and root-0 backing | allocator LockedCell; early pre-MMU initialization; permanent fallback root | keep explicit boot mint/storage sites; do not move these as cosmetic grouping |
| syscall_scratch and exec_args_store | checked per-CPU access, stable owner exchange for argv, non-preemptible EL1 assumption | keep their storage partition explicit; grouping cannot replace a CPU-separation/non-migration guarantee |
| process_image_ext2_state, target root and target-set flag | per-CPU mapping operation and process ownership | a candidate private per-CPU image context after its access contract is stated; preserve root/set consistency and refusal outcomes |
| block-cache data, tags, validity and epochs | per-CPU cache lines and cross-CPU AtomicWord invalidation publication | consider per-CPU cache contexts only with layout and ordering evidence; neither combine CPUs nor silently change release/acquire publication |
| syscall_filesystem | boot configures one private context; syscall boundaries match its closed readiness result | mount and readiness are one state; mutation locking and per-CPU scratch stay separate |
| Driver queue/buffer and ready/disabled state | MMIO, DMA handoff, IRQ paths and linked alignment contracts | retain device-specific contexts and initialization phases; no platform-independent giant context or relocation of named DMA storage by default |
| log, crash snapshot and DDB state | lockless publication, world-stop inspection and retained assembly-visible evidence | preserve diagnostics availability during failure; context conversion follows their protocol/ABI review |
| contention fixtures and accounting | ready/go/done publication and fixture-specific ownership | keep distinct from production topology; reducing fixture global names is not a production performance result |
| immutable offset names and network configuration | immutable bindings; configuration source and initialization | leave immutable values alone unless an actual API needs multiple instances |

## What existing language features establish

The surveyed filesystem candidate had one assignment site for each of
syscall_ext2_mount and syscall_ext2_ready, in kernel_syscall_ext2_configure.
Its only maintained caller is kernel_ext2_fixture_run in shared boot setup.
The first migration below retains that initialization/read contract; it does
not establish type-level write-once publication.

A minimal compiler probe declares two RegionPool(Item) fields in an ordinary
Context and one private global context. Locking &context.first, allocating a
slot, freeing it through the same guard and unlocking compiles under
--regions --forbid-trap. Replacing that free with a guard from
&context.second is rejected with:

```text
static value mismatch: &context.first vs &context.second
```

Thus an ordinary pool does not have to remain a separate top-level global
merely to distinguish its guard/slot identity. This observation does not
prove a context can move while a handle or authority derived from it is live.

Kernel CONCURRENCY.md also forbids putting a leading lock in an align(16)
aggregate that shifts pre-MMU payload arrays to an unsuitable offset. These
compiler probes execute no boot path and cannot waive that physical layout
constraint. Any real context migration must keep the pre-MMU and DMA linked
alignment checks and the value-first container convention.

Explicit durable branding has a narrower syntax: Cell[&context.first]
is a syntax error, while Cell[&global] is supported. No current kernel Cell
migration has been shown to require the former spelling. Do not add it
speculatively: first identify the real stored owner or handle which needs
that field identity. General stored indexed owners and alias/place tracking
are a separate requirement from grouping ordinary fields.

## Recommended sequence and decision boundaries

1. Review the process-image context candidate next. The filesystem
   mount/readiness migration below establishes the first small boundary;
   preserve the image mapping operation's per-CPU ownership and refusal
   outcomes before grouping its fields.
2. Keep the shared pools and their lock/pin contracts while relocating only
   the chosen pool's storage. Compare annotation count, raw-access budget,
   linked layout and representative workload results on both targets.
3. Decide whether a per-CPU allocation front is justified by the existing
   lock/owner/pin-sharing measurements. Context grouping and a per-CPU front
   are separate changes: renaming storage cannot remove lock/cache-line
   contention. Neither implement a front nor change production packing just
   to satisfy an old ordering note.
4. Use a concrete stored-authority consumer to decide the next place/owner
   capability, then consider scheduler/allocator contexts. Keep CPU-local
   storage separation and non-migration as their own contract.
5. Follow with pool-space measurements using the chosen topology and real
   live-object counts. The declaration snapshot alone cannot select a
   generation width, bitmap design or padding layout.

The current pool implementation has one lock and chunk-list head per pool;
it has no per-CPU allocation front. The prior blanket prerequisite that a
front must exist before any global survey is stronger than this survey
needs. It remains a design choice before an allocation-policy change.


## First migration: syscall filesystem context

Two independent globals become one private SyscallFilesystemContext. Its
private state is Unconfigured or Configured(Ext2Mount); the zero-initialized
first tag is Unconfigured. A separate must-use SyscallFilesystemReady result
is returned by the private lookup because stored plain variants and
must-check API results serve different ownership roles.

The exec, pathname-mutation and filesystem I/O boundaries match that result.
Lower helpers receive the extracted Ext2Mount rather than reading a bare
mount global. Streaming loops use one descriptor snapshot. Existing
unconfigured exec/open/access/mutation outcomes are preserved, and ext2
read/write/stat/directory/sendfile paths explicitly refuse an unconfigured
context before their first filesystem operation. Procfs and UART paths keep
their independent early handling.

The common filesystem_context view observes both zero-initialized refusal
through the real exec-format entry and a lookup/read of etc/init.sh through
the published descriptor. Existing syscall, shell and peer-filesystem lanes
exercise the configured paths. Compiler controls check acceptance of a
matched descriptor and rejection of a missing descriptor argument, ignored
readiness result and an unmatched readiness result used as Ext2Mount.

No new compiler rule, lock, raw dereference or CPU-local layout is introduced.
The state is still boot-written and later read-only by the current call graph;
configure is not statically write-once, and the context is not atomically
replaceable while readers run. Boot publication before EL0 filesystem users,
mount-device lifetime and ext2 mutation/reader exclusion remain trusted
contracts. Other independently stored mount/readiness pairs in the boot
fixture and process-image mapper remain separate candidates.
