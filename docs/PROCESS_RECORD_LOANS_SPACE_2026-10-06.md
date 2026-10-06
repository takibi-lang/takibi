# ProcessRecord authority loans: space review, 2026-10-06

The workload is the standard linked QEMU and RPi5 kernel with the existing
bounded boot/process workload. The baseline is the production tree before
checker-only destructive record contracts; the candidate adopts those
contracts on slot removal and reap removal. The native record-loan fixture
also executes all three authority paths, teardown and a stale generation.

| Platform | Boundary | Baseline bytes | Candidate bytes |
| --- | --- | ---: | ---: |
| QEMU | ELF text | 706620 | 706620 |
| QEMU | ELF data | 5022 | 5022 |
| QEMU | ELF BSS | 1667904 | 1667904 |
| QEMU | `_start` to `usable_ram_start` | 2392064 | 2392064 |
| RPi5 | ELF text | 715164 | 715164 |
| RPi5 | ELF data | 2888728 | 2888728 |
| RPi5 | ELF BSS | 1705120 | 1705120 |
| RPi5 | `_start` to `usable_ram_start` | 5341184 | 5341184 |

Measurements use `llvm-size-19` and `llvm-nm-19`. Before implementation,
linked kernels and their generated `main.o` were copied as the baseline.
All six `.text*` and `.rela.text*` sections in each generated object compare
byte-for-byte equal: 1062224 bytes on QEMU and 1076680 bytes on RPi5,
including relocations. Debug/source metadata is outside that boundary.
These observations establish unchanged generated production instructions,
not a multicore throughput measurement.

No fields, pool capacity, allocator metadata, pins, lock operations or
retention policy were added. Existing pool layout and occupancy evidence in
`REGION_POOL_GENERATIONS.md` and `REGION_POOL_ENDPOINT_2026-10-05.tsv` remains
applicable to those separate boundaries. The contract adds static rejection
of local destructive aliases; mint correctness and remote lifetime protocols
remain trusted. Adopt the contracts with no observed production space cost.

Measure again at the next completed kernel feature/stage or a change to
process lifetime, pool representation, allocation workload or retention.
The cross-OS comparison boundary has not changed, so fresh OS measurements
are unnecessary for this decision.
