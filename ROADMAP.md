# Takibi roadmap

The current work split, and nothing else. It is rewritten when priorities
move and is expected to go stale. Findings belong on the GitHub issue they
concern, reasoning and past events in `HISTORY.md`, current behavior in
`kernel/README.md`. Do not add an investigation record here: this file is for
who does what next. The version before 2026-09-23, with every queue's
history, is archived in `HISTORY.md`.

Live intermittents are listed in `docs/KNOWN_INTERMITTENTS.md`, not here.

## Territories, re-cut 2026-10-09

A territory is a role, not a set of directories and not a particular agent
(`AGENTS.md`); which agent holds which is the maintainer's per-session
decision.

**The split (maintainer, 2026-10-09).** Territory A holds only the trunk:
memory safety and multicore -- the stored-authority rule and the kernel-core
consumers that need it, the safe-memory-access route (#637), preemption,
and the evidence those steps are judged by. Its steps run one at a time,
each on the previous one's four-core RPi5 evidence. Everything else is
Territory B's, in the priority order below: drivers and their DMA follow-ups,
diagnostics, fixtures, compiler and language work, measurement and
optimization, toolchain. The rules A has landed -- places (`Place(T)`,
`place_take`/`place_put`), per-CPU storage (`cpu_authority`/`per_cpu`),
fixed DMA records -- are B's to use; a B issue that needs a rule A has not
landed asks A rather than adding a local special case. If a B issue turns
out to block a step of A's route, A pulls it and says so on the issue.

**Loosely coupled (maintainer, 2026-09-29), since either may stop for days.**
A changes the kernel core's runtime behavior and needs four-core RPi5
evidence. B delivers independent fixes, fixtures, diagnostics, compiler
capabilities and build checks, which A adopts at its own pace. Neither
waits. The maintainer rebases and merges often, which is what prevents
double implementation; a conflict in a shared file is expected to be
incidental.

**A red allcheck comes first (maintainer, 2026-09-27).** A failing `make
allcheck` stops every other piece of work, and the lane that meets such a
failure analyses and fixes it, whatever territory its cause lies in. The
goal is to drive the probability of an allcheck failure toward zero step by
step. A holds the analysis of #604, #603, #605, #607, #649, #654, #655,
#667, #670, #673, #676, #685 and #690 when they next
recur.

**QEMU's role (maintainer, 2026-10-03):** QEMU gates functional verdicts
only; verdicts decided by elapsed time or ticks print RECORDED under QEMU
and are decided on the RPi5. Hardware-specific defects are hunted on the
RPi5 under load (#584's churn); each defect it finds gets a deterministic
lane (`kernelcheck-race-window-*-qemu`) before its issue closes.

### Territory A: the trunk, in this order

Done on the stored-authority route (2026-10-09): #637 stage 1's
type-checker work and #731 step 1; #131's first slices -- field places
(borrow in place) and `Place(T)` with
`place_take`/`place_put` for every stored slot, `stable_replace` removed
from the language -- on #732's generic variants; #704's per-CPU storage
(exec args migrated); GEM's RX and TX buffers as fixed DMA records. exception_evidence's per-core arrays stay ordinary arrays:
DDB reads other CPUs' entries on purpose, which is settled with #637's mint
list (maintainer, 2026-10-09).

1. **Stored authority for arrays and pools.** Borrowing in place
   (place_borrow) and runtime-length arrays of places (places, slots) exist
   (2026-10-11; HISTORY.md). Open: per-element witnesses, deferred until
   needed (#751); an immutable index keeping one static, filed for B's
   language work (#755).
2. **The process record.** Threads sharing an address space are planned
   separately on #742.
3. **#637 stage 3: shrinking the mint list.** Both maintained kernels build
   with `kernel/RAW_MINT_FILES`; step A (MMIO through IoHandles), B1 and B2
   are done (HISTORY.md, 2026-10-11), and page uniqueness is by type: every
   page not handed out keeps its permission in a per-page place, and
   PageOwner carries it back by address (2026-10-12). B3 is done too:
   process records are RegionPool records Held for their process's life,
   IntrusivePool has left the kernel, and intrusive_pool.tkb and
   pool_lock.tkb have left the mint list (2026-10-12). freelist.tkb has
   left it too: checked indexing only (2026-10-12; #770 would let a while
   condition bound its body and drop the local re-checks). ext2.tkb has
   left it as well: its scratch is per-CPU storage and every byte access a
   checked (buffer, offset) position (2026-10-12; text +4 KiB, checking a
   field's width once is #770). The network files (arp, icmp, tcp) have
   left it too, through header overlays: `bytes as &mut TcpHdr` is checked
   when every byte pattern is a valid packed header and the slice covers it
   (2026-10-13; the raw `slice as *T` path still lets a refined field sit
   over arbitrary bytes, #772). The overlay also fits the K/R files still
   on kernel/RAW_MINT_FILES that parse external bytes (fdt, virtio, elf64).
   process.tkb is split too: its kernel-stack bytes live in the small mint
   file stack_poison.tkb (2026-10-13). usb_xhci.tkb's DMA-ring raw sites
   stay as #720's work (Territory B). elf64.tkb has left the list through
   header overlays (2026-10-13). fdt.tkb stays trusted under step A: it is
   the DTB reader that mints DeviceWindows. The virtio rings wait for
   #720's option (a) in Territory B. Process stack runs now keep their
   PageRunOwner in the process record, and every process-stack byte is
   reached through it (#672, 2026-10-14; guard about +80 ns per tick on
   RPi5). **Next:** the next #672 layer, section regions (#777, awaiting its
   decision): the linker-bounded stacks and the DTB blob as regions, which
   would take stack_poison.tkb's last integer ranges away. Not on the critical path: #748 (allocator time, 2.75x
   slower since the per-page places), #739 (stale list entries, per-file
   counts). Consolidating the kernel-driven built-ins into general features
   is #750 (holder-tied identities, option C, is its central item; a
   shrink protocol for RegionPools walked with no lock belongs there). For #720
   (B): the doorbell, ERDP-release and stop/reset boundaries are in place;
   #720 must add exact request/event matching; general exclusive backing
   storage is done (2026-10-12: `region let mut` backing globals, whose name
   has no use besides the claim); the ERSTSZ write is #754. log.tkb's raw sites go with
   #613: a lockless multi-writer log ring with its protocol in the type
   system, its orderings checked by #645's herd7 litmus tests.
4. **Preemption.** #638's typed preparation -- a preemption-disabled
   authority, with per-CPU access (`cpu_authority`) derived from it in place
   of the `KERNEL_PREEMPTIBLE == 0` asserts -- with #606 stage 2 (a TLC trace
   spec replacing the Python replay; #656 extends it to LogReader) and #641
   (the world stop in TLA+). Then the flip: measure candidate designs on
   RPi5 and set `KERNEL_PREEMPTIBLE` to 1, with the models passing without
   their no-preemption guards. Never while #584's soak is being run for a
   step's evidence.
5. **Signals and SMP admission on the settled core.** #628 (delivery at an
   interrupt return), then #726 (a caught signal interrupts a sleeping
   syscall; EINTR versus restart needs a decision), with #432 (timed
   blocking) beside it; #9 (SMP process admission).
6. **Research applied to a real example** (evaluated 2026-09-29; reasoning
   on #13): indexed views generated from a TLA+ model's actions, prototyped
   on #613; coordinate that generator's authoring surface with B's #720
   B+C prototype before building separate generators. The maintainer chose
   one common Takibi protocol declaration generating both TLA+ and permission
   types on 2026-10-11; use the same representation for both consumers. Iris vocabulary for
   lock and pool invariants (#132).

**Evidence for the trunk, scheduled by A:** #584's soak at natural
boundaries, #702 (dedicated soak hardware, the maintainer's decision),
#652 (lifecycle trace events for signals and wait4). Every QEMU lane runs
four vCPUs since 2026-10-11; candidates on top of it: #756 (contention
probes rendezvous with every online peer, not core 1 alone) and #757
(uart-wake peer mode intermittently loses byte 1 at four vCPUs).

### Territory B: everything else, ordered by priority

On 2026-10-04 the maintainer authorized autonomous B work in priority order
where acceptance is settled; leave design investigations and unmet
implementation gates parked. Prefer what A consumes at once -- fewer red
allchecks, faster diagnosis -- and what finishes on its own.

Done on 2026-10-10: see HISTORY.md and the closed issues. Production #252
allocator migration remains a separate design gate.

Initialization does not prove CPU freshness across preemption.

Done 2026-10-12: #765 measured the per-call 1 KiB file-buffer zero fill
of #203 stages 1-2 on RPi5 and QEMU; it is below 0.5% of a read and within
the spread of every workload, so #203 stage 3 is not pulled forward.

Done 2026-10-12: #767, bulk HTTP on RPi5 slower since #745. The TCP
retransmit pool returned its last empty chunk, so writes kept re-running
page_alloc_contiguous; it now keeps one chunk (0.126 s against 0.192 s
before #745).

Done 2026-10-13: #497, an on-demand sampling profiler (per-core PMU
samples with frame-pointer chains and skid weighting; /proc/takibi/profile
start/stop, DDB `profile dump`, scripts/profile_kernel_session.py folds
flame-graph stacks). Accepted as option (a): a sample delayed by masked
IRQs is attributed to the unmask point with its masked weight; seeing
inside masked spans is #773 (Arm SPE) and an irqsoff-style tracer on #771.

**Next, ahead of the list below (maintainer, 2026-10-14):** #740: the
stack (arp/icmp/tcp) takes Packet_Filled by move, and the TCP retransmit
queue keeps its TxPosted owner. Done 2026-10-14 under #740: U2-full --
virtio-blk and virtio-net on the modern virtio-mmio transport
(scripts/qemu.sh sets force-legacy=false for every guest), the used rings
as VirtioUsed rx owners read through E1 snapshots (QEMU BSS -27 KB); the
packet-buffer pool (txrx regions with a
direction per publishing edge, `access read` checked by DmaTxReadBorrow.tla,
P_S_bytes), GEM and virtio-net packet buffers moved onto it with the
in-place reply, GEM descriptor rings on rx protocols; the size growth is
reviewed separately. Done 2026-10-13: #786, one section per
function and data object with --gc-sections on every kernel link (QEMU text
-17.6 KB, RPi5 -12.2 KB); #782's compiler-side pruning stays, for the
raw-deref audit rather than for size. Also done: the xHCI work
under #720 -- producer rings, session tables, input context, event ring and
output context are device-protocol owners (E1 snapshots for the last two);
usb_xhci.tkb is off kernel/RAW_MINT_FILES, its bus-address export is
usb_xhci_bus.tkb. Only the DCBAA stays legacy (D3). Candidate: #771, page_alloc_contiguous's whole-table scan under an
IRQ-masking lock (about 3 ms on RPi5), its permanent call/time counters,
the irqsoff-style tracer, and tcp_frame_pool's return-every-chunk shape.

1. **Fixed DMA lifecycle, finishing the drivers.** Every stage of one
   transfer in types, leaving one device-semantics declaration per driver
   and the platform bus translation as the only trusted parts.
   - #720 (session-long xHCI rings and contexts): B+C selected on
     2026-10-11, general region authority plus generated permissions from
     one common Takibi protocol declaration (also generating TLA+).
     B advances the declaration/model/type connection; A's exclusive
     backing storage is done (2026-10-12, `region let mut`, SPEC.md
     built-in region). Three-index region retention
     in a linear owner, reference expiry and Place flow are verified with
     existing rules; #131 is needed only for a later demonstrated shape.
     No local DMA storage exception. Coordinate MMIO observation hooks;
     see docs/XHCI_SHARED_DMA_DESIGN.md. Done 2026-10-11: the `protocol`
     declaration is parsed, validated and emitted as TLA+ (SPEC.md,
     "Protocol Declarations"); RegionTransfer.tkb reproduces
     SharedRegionTransfer's fixed and faulty verdicts. Done 2026-10-12:
     sealed linear owners generated per state (generated code is the only
     mint site), lowerings checked, and the two static rules (witness
     identity; device exit only on a completes/quiesces witness).
     Done 2026-10-12 (slice 3): generated read/write access for
     `access write` states, indices proved against a constant count.
     Unblocked on A's side: the backing-array hole is closed
     (2026-10-12), and no further #637/#672 layer is known to block
     option (a). What remains is option (a) itself, a general reviewed
     region-publication primitive, designed and built with xHCI on #720;
     option (b), retaining dma_fixed tokens, is not taken. Done
     2026-10-13 (option (a) slice 1, decisions D1 P1, D2 Q1, D3 S1, D4
     exists-b slots): device protocols (`retains region(T)[b, N] tx|rx`,
     SPEC.md "Device protocols") with generated cache work on publishing
     and finishing edges, device-state spans, kernel/DEVICE_SEMANTICS_FILES
     and a line-ownership check; a generated owner kept in a Place across
     functions works (linux_user/protocol_tx). Open: #778 (emitted model
     has no cache variables), #779 (line ownership of split or converted
     regions), wrong-ring slot identity (#750). Done 2026-10-13 (slice 2,
     decision B `access write addressed`): the four xHCI producer rings are
     XhciRing owners in usb_xhci_rings.tkb (the device-semantics file),
     usb_xhci.tkb raw dereferences 46 -> 2; kernelcheck-rpi5 green. Then
     the event ring and contexts (slice 3), then GEM/virtio (#740).
     `requires` may collide with future function preconditions; revisit
     its spelling then. #759 (boot check of CTR_EL0
     DminLine/CWG against DMA_CACHE_LINE, an assumption of
     DmaCacheVisibility.tla). #740
     (virtio-net fixed TX/RX-reply authority) awaits the stored-array
     boundary and an in-place reply design decision.
2. **Other compiler and language work, respecting design gates:** #709 and #710
   (generation exhaustion of region tables and the intrusive pool), #203
   (no uninitialized kernel bytes copied to userspace: stages 1-2 done;
   stage 3 (cross-call contracts, byte ranges) remains, with #761's TCP rx
   bound), #763 (report every definite-init error in a function), #764
   (check assume_init sites against TRUSTED_BASE.md),
   #732's later slices (static parameters on generic variants, implicit
   statics inside a type argument).
3. **Time measurement, then the optimizations waiting on it** (maintainer,
   2026-10-08: space and time are both kept): #502 (#497 done
   2026-10-13); then #520
   (TCP throughput), with #741 (locate the measured RPi5 HTTP SYN
   retransmission tails), then #680, #681, #682 (region_pool lock-free
   validation,
   false sharing, pinless single-user pools), #711, #718, #386.
4. **Evaluations awaiting a maintainer decision:** #687 (typed terminal
   mode leases), #648.
5. **Compiler and language research, independent of the ownership
   checker:** #201, #282, #129, #417, #155, #28, #8.
6. **Toolchain and portability:** #123, #124, #122, #95, #51, #50, #85.
7. **Deferred or not a scheduled work item:** #220 (telnet; waits on PTY
   and `pselect6` scoping), #555, #250, #444, #429, #149, #567, #539, #536,
   #698 (ext2 metadata exhaustion as ENOSPC), #374 (physically contiguous
   memory; waits for a dynamic DMA allocation); #13 for `Phi`, with #216
   and #109 as candidate examples, only after the solver threshold in
   `TAKIBI_CORE.md` is met; #712 (compiler-derived liveness-escape
   attribution, after a concrete source-check parser failure); #58 (static
   whole-call-path stack bounds; lowered by the maintainer on 2026-10-04).

Items are ordered within each band as well as between bands. The deferred
items stay listed so a changed premise can bring them back into the queue.
