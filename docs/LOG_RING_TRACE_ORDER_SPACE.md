# Log-ring reader trace ordering space review

The reader's logical event order follows its syscall across CPU changes.
It occupies previously unused event-tag bits 16..31; writer tags retain zero
there, and the wire format, counter intervals and external validator are
unchanged. The reader ordinal saturates at 1024 rather than wrapping. A
further event forces the existing lost-event refusal. One traced reader and
quiescent reporting remain caller requirements, not newly proved properties.

The maintained storm probe drives CPU1 BEGIN, CPU0 HEAD, CPU1 COPY through
the production store and actual emission traversal before resetting storage
for the real window. Its counterfactual restores CPU-grouped emission and
fails the probe. This tests deterministic placement/order, not actual CPU
migration, interrupt timing, or physical coherence. The ordinary kernel lane
still validates its real emitted window against the unchanged LogRingTrace
model. No traversal-wide IRQ mask, affinity pin or coverage exclusion is used.

## Measurement boundary

Source 66a80b3d is compared with the archived published acc2b55b kernels.
The upstream ee62aa60 change is documentation only. Baseline ELF and four
object hashes were checked against the canonical archive manifest at
`.git/takibi-land/baselines/kernel-green-acc2b55b/manifest.json` in the common
Git directory. `LOG_RING_TRACE_ORDER_SPACE.json` records measured image sizes,
all changed mutable symbol sizes (none), image reservation endpoints, selected
frames and object hashes. This is a small correction, measured incrementally;
it does not complete the preemption stage or replace its milestone review.

| Boundary | QEMU change | RPi5 change |
|---|---:|---:|
| Linked text | +1256 bytes | +1192 bytes |
| Linked data | 0 | 0 |
| Mutable data/BSS symbol payload | 0 | 0 |
| ELF BSS section, including layout padding | 0 | -4096 bytes |
| `usable_ram_start` / image reservation | 0 | 0 |

The smaller RPi5 BSS section is a layout-padding observation, not a retired
mutable object or a reclaimed image page. Event arrays retain their original
size. `LogRingTraceReader` grows from 2 to 16 bytes: the ordinal is at offset
8, after two byte-sized flags and alignment padding. The candidate layout is
from both production `structs.tsv` facts; the previous layout is in the
source-matched frozen RootHeld facts, whose trace reader source matches the
published baseline. No pool, heap, retained-page or allocation-workload
improvement is claimed.

## Stack and traversal scope

Corrected `llvm-objdump-19 -d` prologue observations include hexadecimal and
decimal negative `stp` immediates as well as `sub sp`. The named frames agree
across both platforms:

| Function | Production before -> after | Debug before -> after |
|---|---:|---:|
| kernel_log_snapshot_fill | 80 -> 96 | 112 -> 112 |
| log_ring_trace_reader | 64 -> 80 | 64 -> 96 |
| log_ring_trace_store | 80 -> 96 | 128 -> 128 |
| log_ring_trace_report | 64 -> 32 | 80 -> 48 |
| log_storm_trace_probe | 112 -> 112 | 208 -> 208 |
| log_ring_trace_line | 80 -> 80 | 160 -> 160 |
| new log_ring_trace_store_at | 16 | 32 |
| new log_ring_trace_reader_order | 16 | 32 |
| new log_ring_trace_reader_position | 16 | 32 |
| new log_ring_trace_report_events | 80 | 128 |
| new log_ring_trace_order_probe | 80 | 144 |

These are selected single-frame measurements, not a whole-callpath sum or a
proof of the 16 KiB stack bound. Snapshot capture calls reader/store helpers;
reporting calls report_events, which calls position lookup and line emission
on separate branches. Probe and report paths are not combined into an
invented stack prefix. The known frame-check parser defect remains separate
(#1485); its recorded budget numbers are not substituted for these observed
frames.

The closed-window lookup scans at most 1024 ordinal positions and four
256-event buffers, stopping at the first missing ordinal. It allocates no
index array. This is bounded cold reporting work, not a measured latency
claim. No new hardware workload is required for this deterministic ordering
correction; no physical timing or cache-cost claim is made.

The measured code/stack cost is adopted to preserve trace evidence under
migration. Next measurement: a changed trace record/reader layout, reporter
lookup structure, window writer/reader cardinality, or completion of the
preemption stage.
