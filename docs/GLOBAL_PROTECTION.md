# The global protection table and its ratchet

`takibi ... --facts DIR` writes `DIR/globals.tsv`, one row per `let mut` global of the
program with the protection its declared type shows (GitHub issue #1012
slice 1). The kernel recipes write it beside each `main.o` as
`<object>.globals.tsv`, and `scripts/buildcheck_global_protection.py` runs
once in `kernelbuild` on the QEMU and RPi5 tables together. The
classification is the compiler's (`lib/global_protection.ml`): it reads the
`per_cpu`, `dma_fixed`, `guarded_by` and region registries and the
generated protocol and region-pool names, not `.tkb` text.

## Format, version 3

The first line is

    # takibi globals, format 3; see docs/GLOBAL_PROTECTION.md

A reader refuses any other version. Format 2 added the uses table below;
format 3 changed no column and added the kinds `load`, `atomic_load` and
`atomic_store` to it (`read`, `index`, `cast` and `address` used to cover them),
so a reader of format 2 would misjudge a use. The second line names the columns:

| column | content |
| --- | --- |
| `file` | the declaring file, relative to the compiler's working directory |
| `line` | the declaration's line |
| `name` | the global's name |
| `visibility` | `private` or `public` |
| `qualifier` | `region` (a `region let mut` backing), `scratch`, or `-` |
| `type` | the declared type, spelled compactly (`[AtomicWord;4]`, `LockedCell(usize)`) |
| `protection` | one class below |

## The uses table (GitHub issues #769 and #1275)

After the globals' rows, a line `# uses` and a column header start a
second table: one row per use of a global anywhere in the program,
resolved after name binding (a parameter or local of the same name
shadows the global for the rest of its scope).

| column | content |
| --- | --- |
| `file`, `line` | where the use is |
| `name` | the global |
| `kind` | `write` (root of an assignment target), `atomic_store` (`&g..` given to a whole-statement `atomic_word_store`, `atomic_word_fetch_add` or `atomic_word_fetch_sub`), `atomic_load` (`&g..` given to `atomic_word_load`), `address` (any other `&g`, `&g.f`, `&g[i]`), `region` (`region_of(g)`), `load` (a read that yields no pointer into `g`: a path of scalar type such as `g.f`, `g[i]`, `g[i].f`, an operand of `slice_eq`, or a cast to a const slice), `index` (any other `g[i]`, `g[a..<b]`), `cast` (any other `g as T`), or `read` (any other use, including an array field `g.f` and `g(x)` through a global function pointer) |
| `function` | the function containing the use; `-` for another global's initializer |

It is the inventory a migration of a global needs (#637's region seal,
per-CPU or owned state replacing shared globals) and the evidence behind a
TRUSTED_BASE.md row that names a global. It is a table rather than a
`--uses-of NAME` flag because the compiler's facts are files a script
reads, not flags (#1027, #987); `grep` the name column.

## Classes

Tried in this order; an array `[T; N]` takes the class of `T`.

| class | the type |
| --- | --- |
| `region` | a `region let mut` backing, reached only through its claim |
| `slot_owned` | an `owned_by(T.f, S)` global: each element reached as `g[t.f * S + k]` with a linear slot token `t` (SPEC.md, Slot-Owned Globals) |
| `atomic` | `AtomicWord` |
| `lock` | `LockedCell(T)`, `RegionPool(T)`, `InitOnce` as kernel/lib/init_once.tkb defines it (#1418: its private `complete` is written only under its own `TaskMutex`, by that file) |
| `place` | `Place(T)` |
| `boot_once` | `BootOnce(T)`: written under one `BootPhase`, read after by `boot_once_get` |
| `per_cpu` | a `struct per_cpu` store |
| `dma_fixed` | a `struct dma_fixed` record |
| `protocol` | a struct a `protocol` declaration generated |
| `composite` | a plain struct with at least one field, every field protected or declared `guarded_by(L)`: `Mutex` and `TaskMutex` (one `AtomicWord`), the `Place` slot structs, `PeerTally` |
| `none` | anything else: integers, `bool`, arrays of those, structs with one unprotected field, `io` words, `IoHandle` |

A `scratch` global is per-call storage that is still one cell shared by
every core, so the ratchet counts it with `none`.

`composite` is this slice's reading of "lock-protected" for a struct that
is not itself a lock type: it rests on the fields' types, never on a lock
the code happens to take around the global. A global protected only by a
convention (a lock taken by every caller, "core 0 only", "written during
boot") is `none` until its type says so.

## Unread globals

`scripts/buildcheck_unread_globals.py` reads the uses table of both kernels and
refuses a global whose every use is `write` or `atomic_store`. It reads no source
line, and any other kind counts as a read: it can miss a case, never refuse a real
reader.

The same check refuses the converse: a global with uses, none of which can write
it. `load` and `atomic_load` cannot write. `read`, `index` and `cast` cannot write
a scalar or single `AtomicWord`, but an array or struct can be written through the
pointer or slice they yield, so for one of those they count as a write, as does any
`address` use. A flag a debugger sets is declared in
`scripts/debugger_set_globals.tsv` (`name`, `setter`): a row is refused when the
named script has no assignment of the symbol, when the name is not a global, and
when the program also writes it.

The check refuses a struct field too, from `--facts fields.tsv`: one row per
declared field (`file`, `line`, `struct`, `field`, `hardware`, `reads`, `writes`)
with the expressions in the program that read and assign a field of that name. A
field with writes and no reads is refused. The source tree has no receiver types
at that stage, so same-named fields share their counts: it can miss a field, never
refuse a read one. A `hardware` field (of an `io struct`, `io` typed, or in a packed struct) has its
reader outside the program and is skipped. A field only ever set by a struct
literal counts no write, so it is not judged.

## The ratchet

Production means compiled into either kernel image, under `kernel/` and
outside `kernel/tests` and `kernel/models`. The check refuses a production
global whose class is `none` (or that is `scratch`) and that is not a row of
`scripts/global_protection_allowlist.tsv` (`file`, `name`, `reader`), and a
row that no longer names such a global, so a migrated or deleted global
must leave the list in the same commit (`buildcheck_global_protection.py
--drop NAME` or `--prune` on the kernelbuild tables removes such rows and
refuses a write that loses an unprotected global's row, #1201). The row count is the trust-ledger
category `unprotected_globals` (`scripts/check_trust_ledger.py`): a rise
needs an accepting issue and a fall names its rule (`typed protection`,
`BootOnce`, `per_cpu`, ...).

Rows seeded on 2026-10-29 read `unreviewed`, followed by the global's
2026-10-06 disposition (`docs/KERNEL_GLOBAL_DISPOSITIONS_2026-10-06.tsv`)
when it had one. Slice 3 of #1012 replaces each with the reader the global
rests on or migrates it out of the list.

## What a reviewed row says

A reviewed row reads `read-by NAME[,NAME...]: why`. Each `NAME` is a function
with a use of the global other than `write` or `atomic_store` in the uses
table, or a path, containing a slash, to a file that names the global (a GDB
script, a lane's checker). The check refuses any other `NAME` and any cell that
is neither this nor `unreviewed...`, and its PASS line prints how many rows are
still unreviewed. That count moves when a review is done; the trust-ledger
category counts rows, so a review alone does not lower `unprotected_globals`.

What the check guarantees: on this build, each named reader exists and touches
the global, and it fails when a rename or deletion takes a reader away. A file
reader is only known to contain the name as a word.

What it does not guarantee: that the named readers are all the readers, that
they are the important ones, or that anything in `why` is true. The access
premise there (core 0 at boot, under the run lock, with the world stopped) is a
reviewer's reading of the code on the review date. Neither the compiler nor this
check enforces it, a later change can falsify it silently, and a data race on the
global stays possible. A reviewed row remains unprotected: it is moved into the
trusted base with a name on it, not excluded. A read through an accessor is
credited to the accessor. Being reached is not checked either, since the call
graph has no entries from assembly and a test-shaped fixture is compiled into the
same image as everything else; `retain-fixture` means the code's purpose is a
fixture, not that an ordinary boot cannot reach it.

A row whose 2026-10-06 label stopped describing the global stays `unreviewed`
with a dated note saying so, even when it has a reader, until a review gives it
a why that does describe the global.

## Classification of the remaining rows, 2026-10-31

Each of the 164 rows then unreviewed was read in the code and the uses table. 148
now name a reader, by what their why rests on; none of it is checked:

| rests on | rows | premise a later change could falsify |
| --- | --- | --- |
| lock | 34 | every access under a named lock (`block_device_lock`, `ext2_mutation_lock`, the run lock), or core 0 at boot; a `TaskMutex` is kept across preemption |
| boot | 27 | written on core 0 before userspace, read-only after |
| handle | 21 | an `IoHandle` word attached once at boot; a register's own read-modify-write is not covered |
| slot | 18 | a linear slot token (`BlockSlot`, `Ext2Slot`, `ExecWindowSlot`, `ProcessImageSlot`), kept by the task; `cpu_id()` does not select the element |
| token | 17 | the one `NetRxCanAcquire`, or a packet's slot lock |
| fixture | 17 | one boot fixture, a debugger arm, or one calling process |
| stop | 10 | written under `MachineStopped` |
| partition | 2 | own element with IRQs masked or in the IRQ itself |
| protocol | 2 | `InitOnce`'s own operations |

The rows that stayed `unreviewed`, because a task-context reader or writer can
see them inconsistent, name the owner they should migrate to in their cells. The
migration log below records the ones gone. Of the six the preemption flip breaks
first, by selecting an element or a role by `cpu_id()` in task context with IRQs
on, `kernel_log_core_state` stays listed with its premise, by decision.

## Re-audit against the flip, 2026-11-01 (#1316)

All 262 rows, asking of each whether a task-context access with IRQs on can see
it torn or pick an element by `cpu_id()` and move. Two rows the flip still breaks
read `FLIP BREAKS` in their cells: `execution_state`, which has no owner yet, and
`kernel_activity`. `kernel_crash_trace` and `kernel_crash_trace_next` were broken
too and now record with IRQs masked. The other rows' stated premises were read,
by families and not by a proof of each caller; they stay unchecked claims. The
findings table, including what the `KERNEL_PREEMPTIBLE` assertions still depend
on, is on #1316.

## Measured, 2026-10-29

Both kernels, 712 production `let mut` globals (711 before #1172 added one AtomicWord): atomic 132, composite 53,
lock 18, region 20, dma_fixed 8, per_cpu 6, scratch 1, none 474, so 475
unprotected. Outside files whose name contains `evidence` or `probe`: 519
globals, 391 unprotected (the issue's 2026-10-25 hand count was 406 of 500,
by a source scan with different edges).

## Migration log (slice 3)

Every figure is a count of allowlist rows, the trust ledger's number; the
file's comment lines are not rows.

From 2026-11-07 (maintainer) entries name what moved and why, not a count:
the current count is what `make kernelbuild`'s `PASS global-protection` line
and the trust ledger's `unprotected_globals` report. The figures in the
entries below that date are history, left as written.

- 2026-10-29: `kernel/kernel/stall_probe.tkb`'s 13 words (per-CPU notes,
  watched pids, the event ring and its cursor) become `AtomicWord`; the
  ring cursor is one `fetch_add`, so two cores no longer take one slot.
  475 -> 462 unprotected.
- 2026-10-29: ten diagnostic counters in `kernel/kernel/process.tkb`
  (recycled/stale reads, missing records, reaped-current, start refusals
  and stable-root retries, reap-unlinked) become `AtomicWord` with
  `fetch_add`, so increments from different cores are no longer lost.
  462 -> 452 unprotected.
- 2026-10-29: compare-and-swap with existing operations. virtio_blk's
  four statistics (the maximum raised by `atomic_word_compare_swap`) and
  process.tkb's nine first-occurrence words (missing, freed, stale: each
  record claimed by a compare-and-swap of its slot word from 0). 452 -> 439
  unprotected. The `_site` and timeout-snapshot structs beside them stay
  listed.
- 2026-10-30 (slice 4): `kernel/drivers/block/memory.tkb`. The fault
  injection scenario's five words become one linear record in a `Place`
  guarded by `block_device_lock` (`composite`), so it cannot be reached
  without the device guard; the six per-slot counter arrays become
  `[AtomicWord; KERNEL_MAX_CORES]`. 439 -> 428 unprotected (708 globals).
- 2026-10-30: BootOnce (#1013, #1246). The RPi5 boot-DTB configuration: PSCI
  conduit, UART, GIC, timer INTID, PCIe, MIP0, RP1 GEM, clock and GPIO bases,
  USB host base, each reader's status word, and the xHCI capability values;
  QEMU's timer INTID. 418 -> 390 unprotected. The windows' `IoHandle`s stay
  listed: a handle is reached by register syntax, not through `boot_once_get`.
- 2026-10-30: diagnostic counters to `AtomicWord`: the TCP completion and
  stack-wide retransmit counts, the descriptor-table invariant counts, the
  exec refused/lost counts, and the process-image reap, missing-record and
  stale-root counts. The three per-core arrays among them become one word,
  so an increment takes no `cpu_id()` a preempted task could outlive.
  390 -> 374 unprotected.
- 2026-10-30: thirteen more single words to `AtomicWord`: the scheduler's
  dispatch gates (`scheduled_process_boot_handed_off`,
  `scheduled_process_peer_dispatch_enabled`), the CPUs-that-ran mask and the
  deepest reaped stack (each raised by compare-and-swap), the idle-starvation
  and peer-syslog report-once flags (one swap, so one report), the core 0 idle
  note, the debugger's two rollover injection counts (each taken by
  compare-and-swap), the terminal-write wait and sleep counts (no longer taking
  the console lock), the dropped-echo count, and the missing-backing count,
  whose per-core array and `cpu_id()` go. 374 -> 361 unprotected.
- 2026-10-30: seventeen fixture hooks and one-shots to `AtomicWord`, two removed.
  TCP's injected-drop arms, their recovery markers, the retransmit-pass hold and
  the kept-segment count; the persistent-shell checkpoints and the
  connected-fixture label (one swap, no process-run lock); the UART hang arm. A
  drop is taken by one swap or compare-and-swap, so two cores do not both spend
  it, and a data segment's index is stored plus 1, so the zeroed word is
  disarmed. `tcp_ack_each_stream_segment`, which nothing ever set, goes with
  `tcp_split_request_segments` and its two branches. 361 -> 336 unprotected.
- 2026-10-30: real kernel state, one word each, to `AtomicWord`. The ext2 fence
  and the owed undo count; the literal-next latch (one swap) and the terminal
  foreground session; the UART dropped count, whose saturation goes with a
  word that cannot wrap in practice; the log's boot tick, frequency and sent
  flow-control state; the process pool's ready flag; each driver's ready and
  transmit-down flags (virtio-net, GEM, xHCI) and the xHCI write-command count.
  `asid_ready` goes: its one caller runs once. Not touched, deliberately:
  `asid_bits` and `asid_last`, which `asid_init` writes in the MMU-off window,
  where the compiler refuses an atomic call. An atomic flag says the word is
  safe to read; it does not protect what the flag describes. 336 -> 318
  unprotected.
- 2026-10-30: the console's transmit state behind the console guard, the first
  migration here to a lock rather than a flag. The TX queue with its tags, head,
  tail, terminal column, last wire byte and sent flow-control state, and the echo
  ring with its head, tail and phase, are each one record in a `region` backing,
  whose claim sits in a `Place` `guarded_by(console_tx_lock)`; the lock
  measurement is a linear record in such a place, Full only while measuring. Every
  access now takes a `ConsoleGuard[&console_tx_lock]`, which until now named no
  particular lock. The two counts stay `AtomicWord` beside the records: DDB and
  the pending hint read them without the lock, and only a holder writes them.
  `kernel_log_terminal_input_stopped`, an `AtomicWord` since the previous entry,
  moves into the record, since only holders touch it. 317 -> 303 unprotected (317
  after the never-set flag #1270 removed).
- 2026-10-30: the terminal's input state behind the process-run guard. The termios
  settings and the receive ring's indices are one linear record in a `Place`
  `guarded_by(scheduled_process_run_lock)`, and the ring's three byte arrays a
  `region` of three `PageFrame`s, an element type the kernel already compiles, so
  this costs no new region instance (about 10.7M allocated words each). The settings
  are five words, not an array, because the record travels by value through its
  place and an array there would be copied byte by byte. Every kernel reader takes
  the guard, including `ppoll` and the block path's early look. Two cannot: DDB, with
  the world stopped, reads `kernel_uart_rx_queued_word`, and the transmit path, which
  holds the console lock and so cannot take the run lock, reads
  `terminal_flow_controls`, the STOP and START bytes published by each apply; both
  are `AtomicWord`s that only a holder writes. 302 -> 292 unprotected.
- 2026-10-30: scheduler state in `kernel/kernel/process.tkb` behind the run lock,
  with no new region element type: a tick-wake list's heads and the watched pid
  are a linear record in a `Place` `guarded_by(scheduled_process_run_lock)`, and so
  is the spread-timer fixture's phase and handles. Functions that reach them name
  `ProcessRunGuard[&scheduled_process_run_lock]`, so the lock is now public. Each
  core's tick times and the process trace's switches become `AtomicWord`; the
  omitted pid and its flag become one word, pid plus 1, so a reader cannot pair one
  pid with another's flag. 292 -> 277 unprotected.
- 2026-11-01: the flip-breaking rows that needed no design choice.
  `pool_lock_wait_cores` becomes `AtomicWord` rows, on the contended path only, so
  the uncontended lock pair is unchanged; a task moved between choosing its row
  and adding loses no count. `kernel_log_snapshots` was one 64 KiB buffer per CPU
  chosen by `cpu_id()` for a whole syscall; it is now one `region` element whose
  claim sits in a `Place` `guarded_by(kernel_log_snapshot_lock)`, a `TaskMutex`
  held from the build to the last copy, so readers take turns and the image loses
  `(KERNEL_MAX_CORES - 1) * 64` KiB of BSS, for one new region element type.
  `log_ring_trace_cpus` becomes `AtomicWord` events whose slot is taken by one
  `fetch_add`. `log_ring_trace_reader_cpu` and `_begun` go: the traced read carries
  a `LogRingTraceReader` on its stack, so the role follows the read and not a CPU.
  Also `block_cache_hits` and `kernel_exec_reserve_undercount`. 275 -> 268
  unprotected.
- 2026-11-01: the profile session and irqsoff words. The classification named a
  lock for the session, but DDB and the sample interrupt cannot wait for one, so a
  writer claims a start or a stop by compare-and-swap of `profile_session_mode`,
  with a new state 3 while a start builds (#1315), and the period and depth are one
  `AtomicWord`. `profile_core_state` and `irqsoff_core` are `AtomicWord` fields; a
  version word gives procfs a matched longest and sites. `irqsoff_standing` stays a
  reviewed row: on every outermost mask, release stores took the RPi5 lock pair to
  101.1 ns against the 100 ns ceiling, and no relaxed store exists. 268 -> 262
  unprotected, with `kernel_log_core_state` reviewed. No row is unreviewed.
- 2026-11-05: the `/bin/peer-*` fixtures' sixteen words in
  `kernel/kernel/workload_evidence.tkb` (net-wake, mutation, wait, exec, fork and
  sleep pids, CPUs and flags), whose rows said "under the run lock", are one
  linear `WorkloadPeerRecord` in a `Place` `guarded_by(scheduled_process_run_lock)`,
  taken and put back by every access. The peer-sleep step-1 one-shot, read with no
  lock, is an `AtomicWord` swap. Text +2.3 KiB per kernel from the record copies.
  262 -> 245 unprotected.
- 2026-11-06: virtio_blk's state words. `virtio_blk_ready`, `virtio_blk_disabled` and
  the used-ring shadow `virtio_blk_used_seen`, whose rows said "after boot the only
  callers hold block_device_lock, a premise the signature does not carry", are one
  linear `VirtioBlkState` in a `Place` `guarded_by(block_device_lock)`. Every
  virtio_blk entry (`virtio_blk_read_block`, `_write_block`, `_capacity_sectors`,
  init, reset, the settle paths) takes `BlockDeviceGuard[&block_device_lock]`, so
  the lock is now public, and the boot capacity probe takes the guard too. The
  timeout snapshots stay listed (DDB reads them with the world stopped), as does
  the queue (its address is the device's). 245 -> 242 unprotected.
- 2026-11-06: the xHCI transport cursors. The Command, EP0 and bulk IN/OUT
  rings' producer index and cycle and the BOT tag, whose rows said "disk I/O after
  boot only under block_device_lock, core 0 before; disk_* carries no guard", are
  one linear `XhciTransportState` in a `Place` `guarded_by(block_device_lock)`.
  Every `disk_*` entry, the bring-up (`disk_initialize`) and the rootfs
  provisioning and verify take `BlockDeviceGuard[&block_device_lock]`; the
  provisioning gives it back around its cache retirements, which take a
  `BlockSlot`. The event ring's dequeue cursor, the last matched event and the
  foreign-event count stay listed: they are written inside the `XhciEvents` and
  `XhciRing` protocols' generated operations, whose signatures cannot carry the
  guard. RPi5 only; compiled, not yet run on the board. 242 -> 233 unprotected.
- 2026-11-07: the xHCI ring cursors move into their protocol owners (GitHub
  issue #1395). A protocol state may now carry data fields (SPEC.md, Protocol
  Declarations), carried along its edges and set only by the declaring file.
  XhciEvents' `Live` owner holds the event-ring dequeue index and cycle
  (`xhci_evt_idx`, `xhci_evt_cycle`, off this list); each XhciRing owner holds
  its producer enqueue index and cycle, which leave `XhciTransportState` (now
  the BOT tag alone), read and set through `xhci_ring_cursor` and
  `xhci_ring_set_cursor` under the slot lock and restarted with the ring on a
  confirmed reset. The hand-written resets in `xhci_setup_rings_and_start` are
  gone. The last event DWORD3, the foreign-event count and the await words stay
  listed: no protocol owner holds them (#1395's lock-guard parameters).
  233 -> 231 unprotected.
- 2026-11-07: `InitOnce` is classified `lock` (#1418), the classifier's own
  rule, not a new type: kernel/lib/init_once.tkb's struct keeps `complete`
  private and writes it only between `task_mutex_acquire` and
  `task_mutex_release` of its own `TaskMutex`, which is what the rows said.
  A struct named `InitOnce` from any other file stays `none`. The two
  `net_init_once` rows (virtio-net, GEM) and `init_once_probe_gate` go.
  231 -> 228 unprotected.
- 2026-11-07: virtio-net's discovery words (#1159). `virtio_base` and
  `virtio_net_gic_intid`, whose rows said "set by the DTB device map on core 0;
  never written after", are `BootOnce(i32)`: the QEMU DTB walk
  (`qemu_virtio_apply_boot_dtb`, now taking the `BootPhase`) sets them, and
  `virtio_net_base`/`virtio_net_intid` read them, an unwritten cell (no
  transport found) reading as 0 and -1 as the old initialisers did. The IRQ
  dispatcher reads through the same accessor. 228 -> 226 unprotected.
- 2026-11-07: virtio-net's packet relays (#1159, #1416's first part). The
  descriptor address no longer passes through `virtio_pkt_addr`: the caller
  asks the just-posted owner (`virtio_pkt_rx_address`/`virtio_pkt_tx_address`,
  the reviewed `virtio_span_address` writers) before parking it. The used-ring
  observation `virtio_pkt_rx_seen` is a field of the `VirtioPkt` `RxPosted`
  state (#1395's state data), set through the owner by
  `virtio_pkt_note_rx_used` and read by the `virtio_pkt_received` lowering;
  `fill` drops it with the state. 226 -> 224 unprotected. The ring shadows the
  `NetRxCanAcquire` view guards stay listed: carrying them needs the token to
  be an indexed linear struct, a change of the net layer's shared spelling
  (#1416).
- 2026-11-07: the block cache's sets (#1159 option B1, step 2). `BlockSlot`
  and its pool move to `kernel/drivers/block/block_slot.tkb`; the cache's
  functions take `borrow BlockSlot[0]` instead of the slot's number, and its
  seven entry arrays are `owned_by(BlockSlot.index, ...)` (`slot_owned`):
  each entry is reached as `g[slot.index * BLOCK_CACHE_SLOTS + k]`. The four
  `allowed_callers.tsv` rows that held the cache to memory.tkb go with the
  plain index. 224 -> 217 unprotected.
