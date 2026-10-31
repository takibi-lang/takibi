# The global protection table and its ratchet

`takibi ... --facts DIR` writes `DIR/globals.tsv`, one row per `let mut` global of the
program with the protection its declared type shows (GitHub issue #1012
slice 1). The kernel recipes write it beside each `main.o` as
`<object>.globals.tsv`, and `scripts/buildcheck_global_protection.py` runs
once in `kernelbuild` on the QEMU and RPi5 tables together. The
classification is the compiler's (`lib/global_protection.ml`): it reads the
`per_cpu`, `dma_fixed`, `guarded_by` and region registries and the
generated protocol and region-pool names, not `.tkb` text.

## Format, version 2

The first line is

    # takibi globals, format 2; see docs/GLOBAL_PROTECTION.md

and the second names the columns:

| column | content |
| --- | --- |
| `file` | the declaring file, relative to the compiler's working directory |
| `line` | the declaration's line |
| `name` | the global's name |
| `visibility` | `private` or `public` |
| `qualifier` | `region` (a `region let mut` backing), `scratch`, or `-` |
| `type` | the declared type, spelled compactly (`[AtomicWord;4]`, `LockedCell(usize)`) |
| `protection` | one class below |

## The uses table (format 3, GitHub issues #769 and #1275)

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
| `atomic` | `AtomicWord` |
| `lock` | `LockedCell(T)`, `RegionPool(T)` |
| `place` | `Place(T)` |
| `boot_once` | `BootOnce(T)`: written under one `BootPhase`, read after by `boot_once_get` |
| `per_cpu` | a `struct per_cpu` store |
| `dma_fixed` | a `struct dma_fixed` record |
| `protocol` | a struct a `protocol` declaration generated |
| `composite` | a plain struct with at least one field, every field protected or declared `guarded_by(L)`: `Mutex` and `TaskMutex` (one `AtomicWord`), the `Place` slot structs, `PeerTally` |
| `none` | anything else: integers, `bool`, arrays of those, structs with one unprotected field, `io` words, `InitOnce`, `IoHandle` |

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
rests on (DDB under `MachineStopped`, a probe's totals, an ABI record) or
migrates it out of the list.

## Measured, 2026-10-29

Both kernels, 712 production `let mut` globals (711 before #1172 added one AtomicWord): atomic 132, composite 53,
lock 18, region 20, dma_fixed 8, per_cpu 6, scratch 1, none 474, so 475
unprotected. Outside files whose name contains `evidence` or `probe`: 519
globals, 391 unprotected (the issue's 2026-10-25 hand count was 406 of 500,
by a source scan with different edges).

## Migration log (slice 3)

Every figure is a count of allowlist rows, the trust ledger's number; the
file's comment lines are not rows.

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
