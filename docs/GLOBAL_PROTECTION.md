# The global protection table and its ratchet

`takibi ... --facts DIR` writes `DIR/globals.tsv`, one row per `let mut` global of the
program with the protection its declared type shows (GitHub issue #1012
slice 1). The kernel recipes write it beside each `main.o` as
`<object>.globals.tsv`, and `scripts/buildcheck_global_protection.py` runs
once in `kernelbuild` on the QEMU and RPi5 tables together. The
classification is the compiler's (`lib/global_protection.ml`): it reads the
`per_cpu`, `dma_fixed`, `guarded_by` and region registries and the
generated protocol and region-pool names, not `.tkb` text.

The build ratchet additionally admits exactly the private
`exception_evidence.tkb::crash_snapshot_published` array as
`exception_publication`. The raw compiler table still reports `none`.
This scoped admission requires the actual builtin `struct publish`, its
private fixed array, an exact own-CPU publisher and checked reader adapters,
a terminal capture flag that cannot rearm, closed payload aliases, and the
compiled caller graph with foreign-call and function-pointer controls. Both
platforms must supply the evidence. Missing or changed premises leave the
array unprotected. This is a reviewed source-policy boundary, not a generic
classification of all published records or a proof that manually minted CPU
authority cannot migrate or escape. The compiler separately enforces the
publication token/mandatory-field protocol and typed per-CPU access.

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
| `lock` | `LockedCell(T)`, `RegionPool(T)`, `InitOnce` as kernel/lib/init_once.tkb defines it (#1418: its private `complete` is written only under its own `TaskMutex`, by that file), `GuardedField(T)` (#1159: its guard proves the guarded-field lock is held, not which cell's; one adopter, fd_table.tkb's `fd_slot_total`) |
| `place` | `Place(T)` |
| `atomic` (enum) | `Atomic(E)`: one AtomicWord holding a u8 enum's code, through `atomic_enum_store` / `atomic_enum_load` (#1159) |
| `boot_once` | `BootOnce(T)`: written under one `BootPhase`, read after by `boot_once_get` |
| `handle` | an actual compiler-generated `IoHandle(T)` declaration from the region builtins; the maintained boot-attach policy below protects its address word, not the registers' own synchronization |
| `set_once` | `SetOnce(T)` (kernel/lib/set_once.tkb, #1159): published once with the linear claim `set_once_claim`'s compare-exchange hands out, read by `set_once_get`, at any time and with no lock |
| `stop` | `StopCell(T)` (kernel/lib/occupancy.tkb, #1159): written only by `stop_cell_set`, which takes `borrow MachineStopped[&kernel_world_stop]`; read by `stop_cell_get`, a plain load, by anyone |
| `per_cpu` | a `struct per_cpu` store |
| `dma_fixed` | a `struct dma_fixed` record |
| `protocol` | a struct a `protocol` declaration generated |
| `composite` | a plain struct with at least one field, every field protected or declared `guarded_by(L)`: `Mutex` and `TaskMutex` (one `AtomicWord`), the `Place` slot structs, `PeerTally` |
| `none` | anything else: integers, `bool`, arrays of those, structs with one unprotected field, `io` words |

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
declared field (`file`, `line`, `struct`, `field`, `hardware`, `reads`, `writes`,
`qualifier`)
with the expressions in the program that read and assign a field of that name. A
field with writes and no reads is refused. `qualifier` is the struct's tracked kind (`dma_fixed`, `per_cpu`, or `-`), which `scripts/buildcheck_dma_mint_files.py` reads (#567). The source tree has no receiver types
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
| handle | 21 | an `IoHandle` word attached during boot; a register's own read-modify-write is not covered |
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
- 2026-11-07 (#1159): nine one-word flags and counts in evidence files to
  `AtomicWord` -- `profile_samples.tkb`'s `profile_sample_available` and
  `profile_sample_checked`; `workload_evidence.tkb`'s four starve-injection
  words (the debugger still writes `workload_busy_starve_injection_ticks`
  through its address, the value at offset 0) and `move_cost_stored`,
  `move_cost_lost` and `move_cost_reported` (now claimed by compare-and-swap,
  so two cores asking at once print one summary). And `GuardedField(T)` is
  classed `lock` (lib/global_protection.ml), which counts `fd_table.tkb`'s
  `fd_slot_total`; its guard proves the guarded-field lock is held, not which
  cell's (kernel/lib/locked_cell.tkb).
- 2026-11-07 (#1159): `kernel/init/test_driver.tkb`'s nine fixture words to
  `AtomicWord`: the five end-of-fixture baselines and PID 1's root key the
  boot thread takes and PID 1's deferred report reads, the report's one-shot
  `init_boot_fixture_pending` (now claimed by compare-and-swap, so the
  report runs once) and `init_boot_fixture_reported`, and
  `clone_growth_probe_ok`.
- 2026-11-07: the read-ahead run (#1159 option B1, step 3). memory.tkb's seven
  `block_run_*` arrays are `owned_by(BlockSlot.index, 1)`, each reached as
  `g[slot.index]`; `block_run_data` becomes one `BlockRunBuffer` per slot, a
  struct so the device read slices it as a field (same bytes), and
  `block_run_transfer_locked` takes the `BlockSlot` instead of its number.
- 2026-11-07: ext2's slot scratch (#1159 option B1, step 4). `ext2_scratch` is
  `owned_by(Ext2Slot.index, 1)` and `ext2_write_blocks`
  `owned_by(Ext2Slot.index, EXT2_MAX_WRITE_ALLOCATIONS)`; every use already
  indexed by `slot.index`, and the write-allocation rows lose their runtime
  row check for a refined `k`. `ext2_undo_rows`, `ext2_fence_pending` and
  `ext2_fence_pending_count` stay listed: one mutation at a time holds them
  under `ext2_mutation_lock`, not a slot, so owned_by does not apply.
- 2026-11-07 (#1159): the contention and drain probes' gates and counters to
  `AtomicWord`: `pool_contention_evidence.tkb`'s `contention_pool_ready` and
  `contention_pool_grown`, `freelist_contention_evidence.tkb`'s
  `freelist_probe_ready`, `schedule_contention_evidence.tkb`'s
  `schedule_probe_ready` and `schedule_probe_attempts`,
  `occupancy_drain_evidence.tkb`'s `occupancy_probe_teardowns` and
  `world_stop_probe_inspections`, `pool_walk_contention_evidence.tkb`'s
  `pool_walk_ready` and `log_storm_evidence.tkb`'s `log_storm_trace_rounds`.
  `init_once_contention_evidence.tkb`'s naive flag stays: it is the control's
  unprotected word on purpose.
- 2026-11-07 (#1159): `protocol_trace.tkb`'s six trace words (active,
  sequence, stored, lost, process count, unlocked-pass) and four single rows
  to `AtomicWord`: `log_ring_trace.tkb`'s `log_ring_trace_from`,
  `fd_table.tkb`'s `fd_refcount_probe_ready`, `nic_irq_affinity.tkb`'s
  `nic_irq_evidence_intid` (stored as a word, read back as the u32 INTID) and
  `workload_evidence.tkb`'s `workload_ddb_hold_park_since`. The protocol
  trace's writers keep their run-lock discipline; the type now says each
  word is one atomic cell.

- 2026-11-07: the exec staging slots (#1436). `exec_windows` is
  `owned_by(ExecWindowSlot.index, 1)` and `process_image_staging`
  `owned_by(ProcessImageSlot.index, 1)`; every use already indexed by
  `slot.index`, and the acquire resets the staging sources through the slot
  it has just minted rather than the bare index.
- 2026-11-07: stopped-world reads of a per_cpu element (GitHub issue #1159,
  rule 1 of the 2026-11-07 decision; SPEC.md, Stopped-world reads).
  `stopped_read(stopped, g[i].f)` copies a scalar out of any CPU's element
  when `stopped` is a `borrow MachineStopped` parameter. `kernel_activity`
  becomes the per_cpu store `KernelActivityCell`: every own-CPU access is one
  preempt_off region (`kernel_activity_here`, `_set`, `_enter`, `_leave`), and
  DDB's `current` reads the others through `kernel_activity_of(stopped, core)`,
  so its `FLIP BREAKS` note above no longer applies. The other targets stay
  listed: `kernel_crash_trace` is copied live from a crashing core and from
  boot probes with peers running (a sequence protocol, not a stop) and
  `kernel_process_crash_trace_reset` clears every core's slots live, and
  `execution_state` has readers outside a stop (the protocol observation
  under the run lock, the logger's stack owner), so a stop authority alone
  does not cover them.
- 2026-11-07: enum-valued atomics (GitHub issue #1159, rule 2 of the
  2026-11-07 decision; SPEC.md, Enum-valued cells). `Atomic(E)` is an
  AtomicWord holding a u8 enum's code. `scheduled_process_freed_site`,
  `scheduled_process_missing_site` (`Atomic(KernelActivity)`) and
  `kernel_process_exec_failure_reason` (`Atomic(KernelExecFailureReason)`)
  move to it; no debugger script reads the three symbols.
- 2026-11-07: write-once cells not tied to the boot phase (GitHub issue
  #1159, rule 3 of the 2026-11-07 decision). `SetOnce(T)` is a value and a
  state word: `set_once_claim` hands the one winner of a compare-exchange a
  linear claim indexed by the cell, `set_once_publish` consumes it.
  `syscall_filesystem` (`SetOnce(Ext2Mount)`, set by
  `kernel_syscall_ext2_configure`) and `process_image_root0_record`
  (`SetOnce(ProcessPoolHandleWords)`, set by the first ensure of root 0) move
  to it; a second set stops the kernel instead of overwriting silently.
  InitOnce, a gate with no value, stays #1418's.
- 2026-11-07: virtio-net's ring shadows are the RX capability's (#1416 option
  A, slice 1). `NetRxCanAcquire[net]` is a linear struct indexed by its device
  (`&virtio_net_ready`) holding `rx_used_seen`, `tx_used_seen`, `rx_avail_idx`,
  `tx_avail_idx` and the RX descriptors' pool slots (`rx_desc_pkt`, one byte
  each so the frame budget holds); `NetPacket[pb, po, net]`, `NetRxReplyReady`
  and `NetTxInFlight` carry it while the stack holds a packet, and every
  shared holder (tcp, arp, icmp, the capability store as an existential) names
  the index. The TX observation reads the shadow from a `TxPosted` state field
  the capability fills; DDB reads the RX used shadow from an `AtomicWord` the
  holder publishes. GEM's capability is an indexed view until slice 2.
  holder publishes. GEM's capability is an indexed view until slice 2.
- 2026-11-07: GEM's ring shadows (#1416 option A, slice 2). GEM's
  `NetRxCanAcquire[net]` (index `&net_init_once`) is now a linear struct owning
  `gem_rx_pkt` (as `rx_pkt`) and `gem_tx_next` (as `tx_next`), carried by its
  packets as on virtio; DDB reads the posted RX slot from an `AtomicWord` the
  holder publishes. The snapshot relays `gem_rx_seen_filled` and
  `gem_tx_seen_used` are fields of the `GemRxRing` `Armed` and `GemTxRing`
  `Sending` states (#1395), set by the snapshot's release and read by the
  completes observation; a fresh owner starts at 0, which the TSTART reset
  did by hand.
  did by hand.
- 2026-11-07: GEM's packet relays (#1416, slice 3). As on virtio
  (`issue-1159-virtio-pkt`): the descriptor address comes from the posted
  `GemPkt` owner before it is parked (`gem_pkt_rx_address`,
  `gem_pkt_tx_address`, now the reviewed `rp1_span_bus_address` writers), not
  `gem_pkt_addr`; the rings' completes observations reach the buffer as a
  `seen` field of its `RxPosted`/`TxPosted` owner, noted by the driver once
  the ring answered (`gem_pkt_note_received`, `gem_pkt_note_sent`), not as
  `gem_pkt_rx_seen`/`gem_pkt_tx_seen`.
  `gem_pkt_rx_seen`/`gem_pkt_tx_seen`.
- 2026-11-07: the kept frame lengths (#1416). `gem_pkt_kept_len` and
  `virtio_pkt_kept_len` leave the allowlist: a Kept buffer's length is a
  `kept_len` field of its `GemPkt`/`VirtioPkt` `Filled` owner (#1395's state
  data), recorded by the keeping completion (`*_note_kept_len`) and read by
  `net_packet_kept_claim` (`*_kept_len`).
- 2026-11-08 (#1159): two boot-discovered addresses to `SetOnce`:
  `virtio_blk.tkb`'s `virtio_blk_base` (now private, read through
  `virtio_blk_base_get`), `rp1_gem.tkb`'s `gem_rx_ring_cpu_address`.
  An unset cell reads as 0, as before. `virtio_net.tkb`'s used-ring
  addresses stay listed: the native TX fixture reads them directly, and a
  public accessor returning the address is refused by check_frame_api.py. test_driver's `boot_execution` and
  `boot_exec_windows` stay listed: one is written in two steps, the other is
  a buffer the loader fills, so neither is a single set.
- 2026-11-08 (#1159, the StopCell decision): words written only under the
  workload interval's complete stop move to `StopCell(T)`:
  profile_samples.tkb's `profile_sample_active` and the four
  `profile_sample_end_*` captures, profile_timeline.tkb's
  `profile_timeline_active` and `_pid_a`/`_pid_b`, workload_evidence.tkb's
  `workload_profile_active`. `profile_sample_start/_finish` and
  `profile_timeline_start/_finish` take the interval's `borrow
  MachineStopped`, which their one caller already held. While the stop is
  held every other CPU is in the pen and this CPU has IRQs masked, so no
  read is concurrent with the write. `profile_timeline_cores` stays listed
  (an own-element partition, a per_cpu store candidate).

- 2026-11-08 (#1159, the guarded_ref decision): ext2.tkb's `ext2_undo_rows`,
  `ext2_fence_pending` and `ext2_fence_pending_count` become the
  `guarded_by(ext2_mutation_lock)` fields of `Ext2MutationState`
  (`composite`), reached only as `guarded_ref(guard, ...)` in place.
  `Ext2MutationGuard` is indexed by `&ext2_mutation_lock`. Every ext2
  mutator that logs or fences takes the guard as a parameter, and the boot
  fixture takes the lock around its mutation checks, so
  buildcheck_ext2_mutation_guard.py exempts no file.
- 2026-11-08: the xHCI doorbell and await timeout (#1159 step A).
  `xhci_doorbell_target`, `xhci_doorbell_value` and `xhci_await_timeout`
  leave the allowlist: they belong to one submission, so they are value
  arguments of the `XhciRing` actions (`xhci_ring_publish(Ready, target,
  doorbell)`, `xhci_ring_event(InFlight[req], timeout)`; SPEC.md, Protocol
  Declarations), passed by `xhci_ring_submit` to the generated wrappers and
  by them to the lowerings, with no global and no owner field (no owner
  copy, unlike #1395 state data).
- 2026-11-08: the xHCI device words and the awaited event (#1159 step B).
  The slot id, the MSC configuration (config value, interface, bulk
  endpoint addresses, max packet sizes, bursts) and the bulk DCIs that
  disk_initialize learns are private fields of `XhciMscDevice`, each
  `guarded_by(block_device_lock)` and reached only as `guarded_ref(guard,
  xhci_msc_device.f)`: every writer and reader already held
  `BlockDeviceGuard`. `xhci_await_want` is gone: the publication's
  `XhciEventWant` is passed field by field as value arguments of
  `xhci_ring_event`. Twelve rows leave the allowlist. The uses table now
  records a store through `guarded_ref` as a write of the global (it was
  a load, which buildcheck_unread_globals.py reported as never written).
  Still allow-listed: `xhci_await_cc`, `xhci_cmd_completions`,
  `xhci_input_published_at`, `xhci_foreign_events`, `xhci_last_evt_dw3`:
  each is written or read inside a protocol lowering or usb_await_event,
  which holds no guard and whose value arguments are scalars only.
- 2026-11-08: the xHCI words reached from protocol lowerings (#1159 (1a)).
  `xhci_await_cc`, `xhci_cmd_completions`, `xhci_input_published_at`
  (fields of `XhciRingWords`) and `xhci_last_evt_dw3`,
  `xhci_foreign_events` (fields of `XhciEventSeen`) are
  `guarded_by(block_device_lock)`. `xhci_ring_event`, `xhci_input_publish`
  and `xhci_input_used` take the borrowed `BlockDeviceGuard` as an action
  argument (SPEC.md, Protocol Declarations), and xhci_ring_submit,
  xhci_input_submit/take/recover, xhci_tables_start and usb_await_event take
  it as a parameter. Five rows leave the allowlist.
- 2026-11-08: the USB provisioning buffers (#1159 (2)). `usb_provision_batch`
  and `usb_provision_expanded` are fields of `UsbProvisionBuffers`,
  `guarded_by(block_device_lock)`, and reach slice_copy, slice_eq,
  lz4_image_expand_chunk and the new per-batch helpers only as borrowed
  slices of `guarded_ref`. disk_read_sectors, disk_write_sectors and
  disk_write take their buffer as `borrow`. Two rows leave the allowlist.
- 2026-11-08: debugger-set arms (#1159 (3A)). A scalar global (bool or an
  unsigned integer) listed in scripts/debugger_set_globals.tsv is class
  `debugger_set`: only a debugger writes it, and
  buildcheck_unread_globals.py refuses a program write to any listed name.
  The seven `kernel_ddb_*` arms and `diagnostic_trace_test_enabled` leave
  the allowlist. An aggregate stays unprotected even when listed.
- 2026-11-08: the crash-path words (#1159 (3B)). `crash_console_owner`,
  `crash_report_owner`, `crash_fault_order`, `crash_report_contended` and
  `crash_report_abandoned` are `AtomicWord`s reached by the atomic_word_*
  operations, with the same orderings the raw intrinsics had; their address
  helpers and `unsafe` blocks are gone. The contended/abandoned summary now
  reads them with an acquire load. `crash_report_claim_waits`, an empty
  noinline function, is the breakpoint the oops lane waits on in place of
  the removed `crash_report_owner_address`. Five rows leave the allowlist.
- 2026-11-08: the DDB records (#1159 (3D)). `ddb_snapshot` and
  `ddb_wait_test_records` are fields of `DdbState`,
  `guarded_by(kernel_world_stop)`, reached as `guarded_ref(stopped, ...)`
  with the borrowed `MachineStopped` that kernel_ddb_enter_stopped holds and
  now passes to every DDB render and stack helper. A whole process record
  is copied out with slice_copy (`ddb_snapshot_record`,
  `ddb_wait_test_copy`). `ddb_snapshot_published_sequence`, the external
  debugger's publication word, is an `AtomicWord` (release stores as
  before). GDB reads `ddb_state.snapshot` and
  `ddb_snapshot_published_sequence.value`. Three rows leave the allowlist.
  Two guarded_ref gaps were closed on the way: an array field below a
  struct-typed guarded field was refused as "a call's result", and a
  struct-element guarded array cast to a slice was taken for a byte view.
- 2026-11-08: the xHCI one-shot claims and the reset flag (#1159). The
  four `*_claimed` flags (rings, tables, events, output) are `SetOnce(bool)`:
  the first caller wins the claim and takes the region, the rest reclaim.
  `xhci_rings_quiesced` is `XhciResetState.quiesced`,
  `guarded_by(block_device_lock)`: the seven reset observations take the
  borrowed `BlockDeviceGuard` as an action argument, and the restart, start
  and halt paths pass it down. Five rows leave the allowlist.
- 2026-11-08: `virtio_blk_used_claimed` is `SetOnce(bool)`, as the xHCI
  claims (#1159). A region gone at the first claim publishes false, and
  later calls answer the published value. One row leaves the allowlist.
- 2026-11-08: `xhci_init_description` is `XhciInitRecord.description`,
  `guarded_by(block_device_lock)` (#1159, coordinator call (a): the boot
  report's caller may block). disk_initialize writes it under its guard;
  usb_disk_init_last_report takes the guard, and
  kernel_boot_log_usb_init_failure takes and gives back the block device
  before it logs. One row leaves the allowlist.
- 2026-11-08: the boot ext2 fixture's buffers and release words (#1159).
  ext2_fixture.tkb's `ext2_write_fixture_source/readback/bitmap`,
  `ext2_release_first/second/fenced` and test_driver.tkb's
  `ext2_read_fixture` and `ext2_symlink_fixture` (used only by the fixture)
  are fields of `Ext2FixtureState`, `guarded_by(ext2_mutation_lock)`, and
  are reached only as `guarded_ref(guard, ...)` with the mutation guard the
  fixture already holds around its mutation checks. The TestDriverPhase
  token names the fixture's premise more exactly, but its end flag is
  private to test_driver_phase.tkb, so it cannot be a guarded_by lock.
  The ext2 and block entry points the buffers reach (ext2_read_small_file,
  ext2_read_fast_symlink, ext2_block_bitmap_snapshot,
  ext2_resize/replace/write_regular_file*, block_read and its callees) take
  their buffer as `borrow`. Eight rows leave the allowlist.
- 2026-11-08: `virtio_blk_timeout_first` and `virtio_blk_timeout_last`
  (#1159, coordinator call (1)(a)) are `VirtioBlkTimeoutWords`, six
  `AtomicWord`s each (`composite`), private to virtio_blk.tkb. The one
  writer stores them under block_device_lock; DDB loads them with the world
  stopped. A guarded_by(block_device_lock) copy beside the published one
  would have no reader, so there is none. DDB may still see a record a
  stopped writer half stored, as before, but each word is whole. Two rows
  leave the allowlist.
- 2026-11-08: fixture words that fit `AtomicWord` (#1159 survey of the
  retain-fixture rows). `nic_irq_phase_start`, `log_storm_last_round` and
  `kernel_log_storm_found` are `[AtomicWord; KERNEL_MAX_CORES]`;
  `init_once_probe_naive_complete` is an `AtomicWord` read and stored
  separately, so the naive phase still races check-then-set, on whole
  words; `pin_sharing_page` is an `AtomicWord`; `TcpPoolCostMailbox`'s
  never-touched padding is `[AtomicWord; 8]`, so the record is
  `composite`. `kernel_test_init_script`, which both mains set to true just
  before the call, is a parameter of kernel_test_driver_run. Seven rows
  leave the allowlist.
- 2026-11-08: `move_cost_records` (#1475, first record): `MoveCostRecord`'s
  fields are `AtomicWord`s (cold is 1 or 0), stored under the run lock,
  published by `move_cost_stored` and printed by core 0. One row leaves
  the allowlist.
- 2026-11-08: `process_test_evidence` (#1475): every `ProcessTestEvidence`
  field is an `AtomicWord` (the two flags 1 or 0). Counters are
  fetch_add, the clone release is a compare-and-swap decrement that stops
  at zero, and the one-time UART marker is claimed by compare-and-swap.
  One row leaves the allowlist.
- 2026-11-08: `syscall_test_evidence` (#1475): every `SyscallTestEvidence`
  field is an `AtomicWord` (the enable flag 1 or 0); a one-time counter's
  first-time test reads fetch_add's previous value. One row leaves the
  allowlist.

### 2026-11-08 evidence-record incremental space review

The recovered three-record slice replaces scalar fields with AtomicWord;
it adds no record, allocation, pool, lifetime or workload. The bool fields
occupied padded word slots already. Current linked record sizes on both
platforms are 72 B (ProcessTestEvidence), 112 B (SyscallTestEvidence) and
1536 B (move_cost_records). Allocation and occupancy evidence from the
existing space checkpoint is reused at this unchanged boundary; this is
an incremental migration, not completion of the globals milestone.

Both production kernels were rebuilt at 04c94895. llvm-size-19 reports
QEMU text/data/BSS 810628/4600/1302528 B and RPi5
4192856/5576/1933312 B. llvm-nm-19 reports usable_ram_start
0x40208000 and 0x7e0000 respectively; the memory-map check passes.
The base's current checkpoint (source digest verified against origin/main
2a135027) records text 809700/4192012 B: the respective increases are
928/844 B for atomic access, fetch-add, first-claim CAS and decrement code.
Those baseline text figures are inherited measurements, not a baseline
rebuild in this recovery. No timing or cache-performance claim is made.
The next trigger is another storage/lifetime change or completion of the
remaining evidence-record migration. The coordinator still runs the full
publication gate, including hardware.

- 2026-11-09: integration retains the three evidence-record sizes and the
  allocation boundary above. The process evidence header now states atomic
  field updates, coordinated resets and the clone callers' run lock, rather
  than the obsolete single-scheduler-core premise. Host capture/inventory
  repairs add no kernel storage or workload; the preceding incremental
  observations are reused, not reported as a fresh baseline measurement.
- 2026-11-09: `WorkloadSettingsWake` fields are `AtomicWord`s (flags are
  zero or one), including its refused-call counter. The existing run guard
  still serializes registration, terminal-state checks and report claims;
  word atomicity does not provide a multi-field snapshot. Its allowlist
  row is removed.

### 2026-11-09 settings-wake record space measurement

This incremental record migration compares the production kernels at
ac5712d1 (the recovered evidence-record slice) with the settings-wake
AtomicWord conversion. A task-owned baseline clone under the checkout's
ignored build directory was built from that exact commit; both baseline
and candidate used the root kernelbuild-qemu/kernelbuild-rpi5 targets.
No existing worktree was changed for the baseline.

| Boundary | QEMU base | QEMU candidate | RPi5 base | RPi5 candidate |
| --- | --- | --- | --- | --- |
| llvm-size text bytes | 810628 | 810788 | 4192856 | 4193016 |
| data bytes | 4600 | 4600 | 5576 | 5576 |
| BSS bytes | 1302528 | 1302528 | 1933312 | 1933312 |
| settings-wake record bytes | 64 | 80 | 64 | 80 |
| usable_ram_start | 0x40208000 | 0x40208000 | 0x7e0000 | 0x7e0000 |

Only .text changes section size: +160 B on each platform. The ioctl
recorder grows 148 -> 184 B on each; the progress function grows
884 -> 1020 B on QEMU and 876 -> 1004 B on RPi5. The remaining difference
is alignment padding (-12 B QEMU, -4 B RPi5). No other text/data/BSS symbol
changes size. The one boot-scoped record gains 16 B because adjacent bools
become words; it fits the existing BSS reservation. There is no pool,
allocator metadata, resource lifetime or allocation-workload change.
The existing common settings_wake and peer_tty views remain the execution
boundary. No physical timing/cache conclusion or cross-OS comparison is
claimed. Adopted: the small code and payload cost makes each field access
atomic while retaining the run-locked multi-field protocol. The next
measurement is the next record migration or a changed fixture lifetime.

- 2026-11-09: `WorkloadBusyWait` scalar fields and its PID/pick arrays use
  `AtomicWord` cells. The process-run lock still serializes wait tracking,
  increments and maxima, and interval reporting retains its stop protocol.
  Atomic field access is not a multi-field snapshot or an unlocked
  read-modify-write guarantee. Its allowlist row is removed.

### Busy-wait atomic-cell space review (2026-11-09)

Compared with d9f0974d, both production kernels retain a 200-byte
WorkloadBusyWait record (400 bytes for the two workers). Field offsets are
0, 8, 16, 24, 32, 96, 160, 168, 176, 184 and 192 bytes; both eight-word
arrays retain their strides. Widening waiting uses existing padding.
QEMU text grows 810788 -> 810948 bytes; RPi5 text grows
4193016 -> 4193208 bytes. Data/BSS remain 4600/1302528 bytes on QEMU
and 5576/1933312 bytes on RPi5. usable_ram_start remains 0x40208000
and 0x7e0000 respectively. No allocation or lifetime changes.

Reset is private and called only by workload_profile_start while holding
MachineStopped and ProcessRunGuard. Finish/report retain both authorities.
The run lock still serializes separate load/store increments and maxima;
atomic cells provide only word-level accesses. Existing starvation GDB
controls consume UART output and inject a separate unchanged atomic word;
no raw BusyWait layout consumer was found in scripts or maintained tests.
This incremental record migration adopts the small code cost; completion
of the globals milestone still requires its own workload/space review.

- 2026-11-09: `WorkloadProfileCore` uses `Atomic(WorkloadCpuMode)`
  for its two mode fields and `AtomicWord` for counters and flags. The
  enum is explicitly u8-backed for the existing typed enum-cell API.
  Own-CPU IRQ-masked updates, run-locked selection/capture and stopped
  interval reset/reporting retain their original ordering. Atomic cells
  do not establish a multi-field accounting snapshot or reset protocol.
  The cross-core report classification remains; only the plain-global
  allowlist row is removed.

### Profile-core atomic-cell space review (2026-11-09)

Compared with c87f9027, both production kernels measure a 136 -> 144 byte
WorkloadProfileCore record and a 544 -> 576 byte four-core array. Its two
enum cells occupy offsets 0 and 8, followed by word fields at offsets
16 through 136. QEMU text grows 810948 -> 811412 bytes (+464); RPi5 text
grows 4193208 -> 4193656 bytes (+448). Data/BSS remain 4600/1302528 bytes
on QEMU and 5576/1933312 bytes on RPi5. usable_ram_start remains
0x40208000 and 0x7e0000 respectively. There is no allocation, pool metadata
or lifetime change. No external raw record-layout or enum ABI consumer
was found in maintained scripts or tests.

Typed local enum-cell references satisfy the existing generic inference
rule. They add no new ownership or scope semantics. The own-CPU charge
and mode transition retain one IRQ-masked interval; separate load/store
counter increments rely on that mask, not on a compound atomic operation.
Selection and inactive PID capture retain the run guard. Start preserves
selected witnesses before reset and publishes active only after restoring
them. Finish charges all online cores before publishing inactive; reporting
retains MachineStopped and ProcessRunGuard until its last field read.
This incremental review adopts the bounded code/payload cost. Completion
of the globals milestone still requires its measured workload review.

- 2026-11-09: `WorkloadBusyPair` scalar/array fields use `AtomicWord`;
  restart state uses the existing `Atomic(E)` API with an explicit u8
  enum. Run-locked updates, stopped profiling boundaries and the one-shot
  stack-release/reap handoff retain their ordering. Reaping publishes its
  reported flag after unlink releases the run guard; this is not described
  as a locked compound operation. Peer controls retain their planted
  failures, and GDB reads/watchpoints address the atomic value fields.

### Workload record milestone space review (2026-11-09)

The final record conversion is compared with the rebased pre-conversion
commit 9718310f, which includes published a761a122 and the earlier two
workload units. Both production kernels were built before and after the
conversion in the same worktree. BusyPair grows 448 -> 592 bytes; its two
four-word arrays retain word strides and all fields are now word cells.
QEMU text grows 809592 -> 811080 bytes (+1488); RPi5 text grows
4194460 -> 4196036 bytes (+1576). Data remains 4600/5576 bytes. QEMU BSS
remains 1302528 bytes. RPi5's reported BSS falls 1933312 -> 1929216 bytes
because its start moves 0x602000 -> 0x603000 while its end stays 0x77a000.
The fixed RP1 DMA arena stays 0x640000..0x680000: this consumes alignment
slack before the arena, not a payload saving.

The three-record batch is also compared with the published a761a122 ELFs
from the coordinator's completed allcheck, copied read-only for measurement.
QEMU text grows 808968 -> 811080 bytes (+2112); RPi5 text grows
4193820 -> 4196036 bytes (+2216). BusyWait remains 400 bytes, ProfileCore
grows 544 -> 576 bytes across four cores, and BusyPair grows 448 -> 592:
176 bytes more fixed record payload in total. These measurements separate
payload from section padding. usable_ram_start stays 0x40208000 on QEMU
and 0x7e0000 on RPi5 throughout; the reserved image/page boundary does not
grow. There is no allocation, pool metadata, retained-resource lifetime or
workload-capacity change.

The workload remains the bounded common boot: two CPU-bound workers, the
stopped profile interval, restart, peer filesystem/console and stack-release
fixtures, with existing starvation and DDB controls. This milestone measures
fixed evidence-record storage and linked-image reservations; it does not
claim a new allocator-occupancy measurement, timing/cache guarantee or an
OS comparison. The small measured cost is adopted for typed atomic field
access, retaining all multi-field protocols. The next measurement trigger
is changed record capacity, allocation/retention behavior or a new kernel
feature milestone.

## Device-handle boot boundary

The compiler classifies only actual generated IoHandle definitions, using
the builtin region provenance and generated type name together. A same-named
user struct or an ordinary io pointer has no handle protection. This facts
classification adds no language ownership rule or generated MMIO operation.

The maintained kernel and native-driver fixtures additionally pass
check_io_handle_boot_phase.py: handles have direct global declarations,
registers are reached by projection, and only a direct io_handle_attach
argument may take a whole handle word's address. Whole-word copies,
assignments, escaping addresses, generated-type spellings and callable
aliases are rejected. Aggregate/local handle storage needs a separately
verified boundary before adoption; it is not silently exempted. Every raw
attach's own enclosing function borrows BootPhase, including a nested
callback rather than inheriting an outer function's phase. The type checker
refuses reuse after boot_phase_end.

BootPhase remains mutable: bootstrap and verified DTB windows can attach
more than once during that phase. The mint and ordering before CPU_ON stay
trusted as for BootOnce. The general language primitive remains copyable
and phase-independent outside this maintained repository policy. There is
no SetOnce read wrapper, new attach refusal, or per-MMIO load/check/lock.
The register block's own concurrent read-modify-write still needs its driver
synchronization. All 21 reviewed handle rows leave the allowlist only with
this boundary in place.

### Device-handle milestone space review (2026-11-09)

Compared with published 762abced, both production kernels retain the same
handle layout and fixed storage, data/BSS sizes and usable_ram_start. QEMU
text/data/BSS remain 811080/4600/1302528 bytes; RPi5 text grows
4196036 -> 4196068 bytes (+32), with data/BSS unchanged at 5576/1929216.
The reservation boundaries stay 0x40208000 and 0x7e0000. No allocation,
pool metadata, retained lifetime or device capacity changes. The compiler
facts classify the 21 reviewed handle globals as protected handles.

The static workload is the existing device-map bootstrap/DTB attachment
before CPU_ON, plus the single-core DMA fake transport and the two native
virtio driver fixtures using their existing boot token. Repeated in-phase
attachments remain part of this workload. This is a measured fixed-state
and linked-image boundary, not a new allocator-occupancy or physical-timing
measurement. No backend or primitive lowering changed. The UART FIFO-full
and TX-store accessors retain identical instruction bytes on both targets;
there is no per-MMIO wrapper, load, branch or lock. The 32-byte boot-code
cost is adopted for the explicit phase boundary. The next measurement is a
changed handle capacity, device-map lifetime or allocation workload.
### ExecutionState authority milestone (2026-11-09)

ExecutionState is a private-field per_cpu store reached through CpuHere;
its ordinary-global allowance is removed. Run-lock observers use guarded
PID/live copies, retaining live PID0 separately from absence. Complete-stop
diagnostics use a separate scalar per_cpu capture, generation revalidation
and existing stopped_read. The exception constructor is an exact confined
trusted mint, not a language proof of physical nonmigration. The measured
source is 521e320b; both platforms retain the 544-byte execution-state
layout and add 72-byte observation plus 192-byte stop capture payload.
Image/page reservations and both bounded pool samples remain unchanged.
The physical incremental publication observation is 165.545 ns per one
current-plus-stack pair, not per switch or individually per publisher.
The accounting, artifact hashes and corrected frame/callpath boundary are
in docs/EXECUTION_STATE_PER_CPU_SPACE_2026-11-09.txt and its evidence JSON.
This completes the ExecutionState slice, not the globals or preemption
milestone.

### Virtio block queue guarded CPU access

The virtio block descriptor/avail queue is a private guarded field of an
offset-zero container, protected by the existing block_device_lock. Every
CPU field read or write uses guarded_ref with the existing borrowed
BlockDeviceGuard, including initialization and timeout evidence. Linear
submission stages, receive/transmit owners, reset outcomes and barrier
placement remain separate requirements. The device may still read the
queue while CPU operations are serialized; the lock is not DMA ownership.

Only the guarded setup function may mint the fixed container's two integer
addresses. The closed source policy and resolved caller map confine those
addresses to descriptor/driver low/high MMIO programming, including runtime
reinitialization after confirmed reset. Container copies and other pointer
or integer escapes are rejected by the source policy; the language's
general guarded_ref address rejection remains unchanged. The network
queue retains its current capability-based boundary.

### Virtio block queue milestone space review (2026-11-09)

Compared with the archived published 766d9e8a production ELFs, the block
queue remains 256 bytes, aligned to 64, with descriptor offset 0 and avail
offset 128. Its private guarded container adds no payload or allocation.
QEMU text changes 815368 -> 815420 bytes (+52); data/BSS stay
4616/1302528 bytes. RPi5 text changes 4200428 -> 4200424 bytes (-4);
data/BSS stay 5592/1925120 bytes. usable_ram_start remains 0x40208000 and
0x7e0000. The baseline ELFs were checked against the archived SHA manifest.

The workload is the existing synchronous block submission, including
initialization, descriptor-chain publication, observed completion, timeout
and confirmed/failed reset. The kernel DMA fixture retains its real guard
and authority branches. There is no new pool, retained allocation or device
capacity; used-ring and buffer authority storage are unchanged. This is a
measured fixed-state/image milestone, not physical cache/timing evidence.
The small code change is adopted for the explicit borrowed guard boundary.
Measure again when queue capacity, DMA ownership, or allocation lifetime
changes. CPU serialization remains distinct from device quiescence.

### Shared block-device guard provider

The block-device lock and its linear guard are declared in
`kernel/drivers/block/device_lock.tkb`. Its blocking take has no slot
accounting; its try take performs one real TaskMutex attempt and returns
Busy or a guard. The existing block wrapper alone charges a failed first
attempt to the caller's real BlockSlot. Guard payload remains one word
and carries no CPU or slot identity. Native spinlock coverage exercises
the actual shared provider's exclusion and release, without a fake guard.

This shared-interface extraction preserves the existing lock/storage and
block-I/O workload. The net queue migration is a separate consumer change.

The interface-only extraction measures against archived e15c4f54: QEMU
text 815420 -> 815540 bytes (+120), RPi5 text 4200424 -> 4200512 bytes
(+88). Data/BSS and usable_ram_start remain unchanged on both targets;
the one lock remains 8 bytes and the linear guard remains one word. This
component changes no allocation capacity or retention workload. The full
net queue consumer milestone requires its own final measurement.
