# ProcessRecord authority transfers: space review, 2026-10-06

The baseline is published production commit 989184d5; the candidate retains
pool proofs through run-guard, scheduled-owner and current-process loan
transfers. Current-process readers borrow one erased generation/phase witness
from entry. Clone, rollback, installation, suspension and exit transfer or
consume it. LLVM SROA runs before and after forced inlining in production
builds so the temporary proof wrappers need not remain aggregate copies.

Both images use the standard production flags and linked kernel workload.
Measurements use llvm-size-19 and llvm-nm-19, with a separately built baseline.

| Platform | Boundary | Baseline bytes | Candidate bytes | Change |
| --- | --- | ---: | ---: | ---: |
| QEMU | ELF text | 706620 | 691924 | -14696 |
| QEMU | ELF data | 5022 | 5022 | 0 |
| QEMU | ELF BSS | 1667904 | 1667904 | 0 |
| QEMU | `_start` to `usable_ram_start` | 2392064 | 2392064 | 0 |
| RPi5 | ELF text | 715164 | 700940 | -14224 |
| RPi5 | ELF data | 2888728 | 2888728 | 0 |
| RPi5 | ELF BSS | 1705120 | 1705120 | 0 |
| RPi5 | `_start` to `usable_ram_start` | 5341184 | 5308416 | -32768 |

The QEMU image's reservation boundary does not move despite its smaller text.
The RPi5 image releases eight 4096-byte pages. This is linked-image accounting,
not a measurement of physical cache behavior or multicore throughput.

The fresh QEMU bounded boot/teardown capture is
`PROCESS_RECORD_AUTHORITY_ENDPOINT_2026-10-06.tsv`. It is byte-identical to
`REGION_POOL_ENDPOINT_2026-10-05.tsv` under the same endpoint boundary. The
process payload is 872 bytes, stride 880, pool control 104 and chunk 8192.
At both endpoints it retains one chunk, nine slots and zero nonfree slots:
8192 reserved chunk bytes plus 104 control bytes. Payload, free capacity,
slot metadata, header reservation, alignment and tail are separate columns.
Other pool endpoint rows are unchanged too. These samples are not peaks.

The live phase is exercised by the maintained 24-process allocation/cycle/
reap/reuse probe, followed by teardown of every record. Its observed count
and measured payload size give 20928 live payload bytes; this is calculated
payload, not total allocator or stack storage. The three-sibling clone/wait4
probe and the ordinary process-clone workload also pass. The fresh capture
`PROCESS_RECORD_AUTHORITY_LIFETIMES_2026-10-06.txt` records these verdicts and
the complete two-core protocol trace: 87 changes at 48 changed hold boundaries, replayed as 43 action steps over
2367 run-lock holds, with no lost changes. The trace contains three process
identities initially, four during clone and three after reap; it includes
the permanent bootstrap process and is not a pool occupancy counter. Replay
accepts the clone/installation, exit, wake, stack handoff and removal actions.

The generated QEMU accessor frames are 80 bytes for run-guard lookup,
80 for current lookup and 64 for owner lookup. The temporary indexed wrappers
are local proof transport, not retained per-process state. Current phase
views and their context-change contracts add no runtime witness fields,
checks, pin operations or reclamation counters. The FD-slot query now reads
the CPU-local slot directly instead of probing an address-space root solely
to extract its slot. Existing record probes and field locks remain.

Adopt the authority transfer and phase design with these measured costs.
Private physical mints, annotation completeness, generation association and
remote CPU lifetime protocols remain reviewed trust; local proof provenance
and witness consumption are compiler checks. The cross-OS allocation boundary
has not changed, so existing Linux/FreeBSD comparisons remain applicable.
Measure again at the next completed kernel feature/stage, a new process
lifetime/resource, or changed pool allocation/retention behavior.
