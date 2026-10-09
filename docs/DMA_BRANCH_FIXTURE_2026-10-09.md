# DMA branch fixture and space review (2026-10-09)

The workload is one isolated, single-core QEMU boot with IRQs masked and no
secondary entry. The maintained virtio-blk write path handles completed error,
no completion with confirmed reset, successful queue reuse, and no completion
with failed reset. It checks the receive, request-header and write-data slots
and refuses a later submission without losing Device authority.

The generated overlay changes only the entrypoint and device observations:
register addresses refer to test storage, queue notification publishes a
controlled status/used entry, and failed reset leaves status nonzero. The
positive overlay does not replace submission, polling, settlement or token
exchange bodies. Anchors must occur exactly once or generation refuses.
The device-side raw accesses (one descriptor address read and four status/ring
access sites) are explicitly budgeted; none bypasses checked CPU-side access.
Compilation uses --forbid-trap, the fixture's unused-function check and the
existing raw-dereference and source-coverage checks.

## Faithful negative controls

All controls compile and link successfully. The runner then exits 1, and an
independent check verifies the exact diagnostic below. These are planted
changes to maintained branches, not fake runner failures.

| Control | Planted violation | Required diagnostic |
| --- | --- | --- |
| error | Completion omits request-header settlement | FAIL dma: request authority |
| reset | Confirmed reset omits write-data settlement | FAIL dma: data authority |
| failed | Nonzero reset readback falsely reports success | FAIL dma: receive authority |
| disabled | Submit accepts initialization refusal | FAIL dma: disabled driver reused |

The initial disabled control entered the real Device-token fail-stop and DDB
instead of producing the fixture's assertion; it was not counted as the
specific refusal witness above. The final control tests the caller's handling
of the initialization refusal and produces that witness deterministically.

Byte-at-a-time UART delivery also exposed a host-runner defect: a marker
substring could stop capture before the reason or newline arrived. The runner
now requires the complete line. A fast pure control checks every byte split,
including a preceding unrelated newline; restoring the old substring predicate
fails with `partial diagnostic ended capture`. External Python stream chunks
are not established by Takibi's existing types. This build-time regression
covers the occurred instance without a new language feature or trusted mint.

## Measured space

`python3 scripts/space_delta.py 784d5709` builds the working tree and an isolated
baseline, compares both linked production kernels and checks every data/BSS
symbol size. Neither platform has a changed data/BSS symbol.

| Boundary | QEMU baseline | QEMU candidate | RPi5 baseline | RPi5 candidate |
| --- | ---: | ---: | ---: | ---: |
| text, bytes | 726276 | 726276 | 737596 | 737596 |
| data, bytes | 5078 | 5078 | 2888792 | 2888792 |
| BSS, bytes | 1658608 | 1658608 | 1697632 | 1697632 |
| usable_ram_start | 0x40248000 | 0x40248000 | 0x718000 | 0x718000 |

The dedicated test ELF has text 728356, data 5110 and BSS 1660176 bytes:
+2080/+32/+1568 versus the production QEMU ELF. Its mock registers, buffer
and counters are absent from production closures. The fixed ext2 workload,
pool metadata, reservations and retained-page behavior are unchanged. No new
OS comparison is needed because the production comparison boundary is unchanged.

Exact positive/control ELFs, overlay patches, raw audits, UART captures and
statuses are retained under `.git/takibi-diagnostics/624/2026-10-09/` before
clean publication checks. This is evidence for deterministic driver branching
against simulated observations, not physical cache coherence or the real
virtio reset guarantee. Ordinary RPi5 I/O remains the hardware evidence; the
natural device-failure gap is in SOAK_BACKLOG.

Assessment: the production space cost is zero. The test image's small extra
storage is paid only by the dedicated lane. The next measurement trigger is a
production DMA allocation/layout change or a new driver lifecycle milestone.
