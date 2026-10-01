# Unsafe inventory for the safe-memory design

A dated snapshot of where the maintained kernel relies on hand-checked memory
reasoning, grouped by the language mechanism that could remove each site. It
is the baseline for ROADMAP Territory A route step 3 (safe pointers and safe
memory access): the design picks mechanisms by what they would retire, and the
same counts, re-measured afterwards, say what they did retire.

This file is a snapshot, not a maintained contract. `TRUSTED_BASE.md` states
what a build establishes; `make trustedbasecheck` prints the current raw
counts. Re-measure rather than trust these numbers once the tree has moved.

- Measured: 2026-09-29, at commit `14c4747b`.
- Source set: the union of the RPi5 kernel, QEMU kernel, and EL0 test payload
  depfiles, the same set `scripts/measure_trusted_base.py` reads: 113 files,
  65,259 lines. The 15 kernel `.tkb` files outside that union are not counted.

## Headline

| Measure | Production | Boot-time probes | Total |
| --- | ---: | ---: | ---: |
| `unsafe { ... }` blocks | 338 | 383 | 721 |
| Plain raw pointer types in signatures and declarations (`: *T`, `-> *T`) | 545 | 24 | 569 |
| `*io T` types in signatures and declarations | 199 | 0 | 199 |
| Call sites of the 11 declared pool liveness escapes | 369 | 0 | 369 |

"Boot-time probes" are the two-core contention and drain probes: every
`kernel/kernel/*_evidence.tkb` file except
`kernel/arch/arm64/kernel/exception_evidence.tkb` (which is DDB and the crash
reporter, and counted as production), plus the `fd_refcount_probe` blocks
inside `kernel/kernel/fd_table.tkb`. All 383 probe blocks are raw atomics.
They are linked into the kernel, so they are part of its trusted base, but
they are test machinery and do not decide the design.

## Three things the block count does not show

1. **Raw pointer dereference is not gated.** `unsafe` marks only the moment a
   pointer or slice is minted (`SPEC.md`, "unsafe { ... }"). Once a `*T`
   exists, `p.field`, `*p`, and `p[i]` compile anywhere. The 545 plain
   raw-pointer types in production code are therefore the reach of unchecked
   access, and they are mostly outside any `unsafe` block.
2. **The largest unchecked surface is pool payloads, and it costs almost no
   blocks.** `kernel/lib/intrusive_pool.tkb` ties a payload pointer to a
   linear liveness proof (#488). Eleven accessors drop that tie and return a
   bare pointer, each declared with its reason in
   `scripts/check_liveness_proof_escapes.py`. Those accessors contain only 7
   `unsafe` blocks between them, but they have 369 call sites in 7 files,
   and at each one the payload's lifetime rests on a hand argument (a
   reaper's exclusivity, a reference count, a connection owner, or the
   process-run guard).

   | Escape accessor | Call sites |
   | --- | ---: |
   | `scheduled_process_record_at` | 124 |
   | `process_image_record_at` | 87 |
   | `address_space_backing_at` | 32 |
   | `unified_object_at` | 32 |
   | `fd_context_at` | 30 |
   | `fd_block_at` | 21 |
   | `tcp_connection_payload` | 16 |
   | `tcp_connection_alloc` | 11 |
   | `address_space_backing_existing_at` | 7 |
   | `scheduled_process_record_peek` | 6 |
   | `tcp_frame_slice` | 3 |

   The raw-pointer types follow the same pools: `*ProcessFdContext` (38),
   `*TcpConnection` (36), `*ProcessRecord` (32), `*SharedObject` (24),
   `*FdBlock` (22), `*PageMeta` (21).
3. **`!{unsafe}` no longer locates hand reasoning.** 633 production functions
   declare it, but only 163 of them contain an `unsafe` block. The other 470
   declare it because something they call does, which the effect row permits
   and does not require. The block, not the effect, is the unit that
   identifies a hand-checked assumption.

## Production blocks by the mechanism that would remove them

The 338 production blocks are listed by the language mechanism that would
remove them. `measure_trusted_base.py` sorts the same blocks by syntax (MMIO /
atomic / raw cast / unchecked index / unclassified). This table re-sorts them
by their purpose, which that syntactic view does not show.

| Group | Blocks | Where | Candidate mechanism | Open issues on 2026-09-29 |
| --- | ---: | --- | --- | --- |
| A. MMIO register access | 199 | `platform/rpi5` (intc 51, usb_xhci 34, pcie 30, uart 24, timers 2), `platform/qemu` (uart 24, intc 12, timer 1), NIC and block drivers 21 | A typed register block: one minted base per device, registers as typed fields | -- |
| B. Raw atomics on computed addresses | 66 | DDB/crash reporter 18, occupancy 15, printk log 7, terminal 6, secondary boot 5, spinlock 4, ext2 mutation lock 4, block cache 3, diagnostic ring 2, crash trace 2 | A typed atomic cell that fixes the location and, where possible, the protocol | #613 |
| C. Kernel stack and exception frame | 24 | DDB/crash reporter 10, `process.tkb` 7, `syscall.tkb` 6, `profile_samples.tkb` 1 | A typed stack region whose frame is derived from it rather than from a saved `sp` | #614 |
| D. Physical pages and user memory | 23 | `mm/user_memory.tkb` 13, `mm/page.tkb` 8, `mm/address_space.tkb` 2 | A physical-page view and a user range that carry their length into a slice | #202 |
| E. DMA ownership boundary | 13 | `usb_xhci.tkb` 9, `virtio_blk.tkb` 3, `drivers/block/memory.tkb` 1 | Extending the existing DMA ownership model to device-address and receive completion | -- |
| F. Pool internals | 7 | `intrusive_pool.tkb` 6, `pool_lock.tkb` 1 | Payload lifetimes carried past the probe (see point 2 above) | #343, #131, #132, #370, #518 |
| G. Correlated index | 3 | `lib/freelist.tkb` | A relational or cross-function owner-index proof | #216 |
| H. Boot-time tables | 3 | `arch/arm64/mm/mmu.tkb` 2 (page-table entries), `boot/fdt.tkb` 1 | A bounded table view | -- |

Notes on individual groups:

- **A** is uniform: 194 of the 199 blocks are a single
  `(base + constant) as *io T` expression, drawn from 29 distinct base names.
  Group A accounts for most of the block count while carrying the least
  memory-safety risk, because each block is one reviewed register address.
- **B** uses `usize` addresses because the atomic intrinsics take one
  (`SPEC.md`, "Atomic Operations"). `kernel/lib/atomic_word.tkb` now fixes
  which word is addressed: an `AtomicWord` cell, and arrays of them indexed by
  a refined core number. The terminal, secondary-core, diagnostic-ring,
  block-cache, ext2 reader count, unimplemented-syscall, crash-trace, log and
  world-stop/occupancy words are cells; the files that still call an
  intrinsic directly are the allowlist in `scripts/check_lock_discipline.py`.
  A cell does not check the ordering argument between accesses, which is the
  part #613 asks the type system to carry. The counts in the table are the
  2026-09-29 baseline.
- **F** is small in blocks and large in reach, for the reason given in point
  2 above. Of all the groups, F has the most bearing on use-after-free (#343).
- Null safety (#342) is not measured here. Nothing in the source marks a
  pointer that may be null, so this inventory has nothing to count for it.

## Raw dereference sites (measured 2026-09-30, #639)

`--emit-raw-deref-audit` lists every place the type checker sees a raw
pointer dereferenced, in six forms: `*p`, `p.field`, `p[i]` and a store
through each. Both kernel objects, deduplicated by source position so a
generic function counts once:

| Measure | Plain `*T` and `*align(N) T` | `*io T` | Files |
| --- | ---: | ---: | ---: |
| QEMU kernel | 2,377 | 172 | 33 |
| RPi5 kernel | 2,372 | 220 | 34 |
| Union, per-file budget in `scripts/raw_deref_budget.tsv` | 2,377 | 291 | 38 |

The 545 above counts raw-pointer TYPES in signatures and declarations and 199
counts `*io` types; these count SITES, and one pointer parameter used twenty
times is twenty sites. So the two are not comparable one for one: the audit is
the larger figure because it counts uses, and it counts only what the
compiler proved is a raw pointer, where the type scan matched text. The five
largest files hold 1,632 of the 2,377 plain sites: `process.tkb` (750),
`tcp.tkb` (337), `fd_table.tkb` (209), `process_image.tkb` (159) and
`page.tkb` (157), which is the pool-payload reach that point 2 above
describes, seen from the dereference side. The EL0 test payloads are not
audited yet.

## Outside the blocks

These trusted boundaries are unchanged by any of the mechanisms above.

| Boundary | Count |
| --- | ---: |
| Handwritten production assembly | 7 files, 1,633 lines |
| Extern function and symbol declarations | 76 |
| DMA and cache builtin operations | 44 |

## Reproducing

`make trustedbasecheck` builds the kernels and prints the source set, the
block totals, and the syntactic categories. The production and probe split,
the regrouping by mechanism, and the escape call-site counts were produced
with a one-off script built on `measure_trusted_base.py`, which was not
committed. The rules are:

- A block is a probe block when its file is a `kernel/kernel/*_evidence.tkb`
  other than `exception_evidence.tkb`, or when its body names
  `fd_refcount_probe`.
- Raw-pointer types are counted by matching `: *T` and `-> *T` after comments
  are stripped. `*io T` is counted separately. A `*T` whose `T` is an
  affine or linear opaque struct would be a handle rather than a raw pointer,
  but the source set declares none.
- Escape call sites are calls to the functions in
  `scripts/check_liveness_proof_escapes.py`'s `ALLOWED` table, with comments
  and definitions excluded.
- A block's group comes from reading its body. For groups A and B, the
  syntactic category was enough to assign it. Groups C through H were
  assigned by hand from the file and the construct in each block.
