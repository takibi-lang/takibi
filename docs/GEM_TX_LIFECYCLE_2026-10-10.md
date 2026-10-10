# GEM TX lifecycle evidence and space review

The workload is one fixed 1536-byte TX allocation shared by two descriptors,
ordinary ready-frame and RX-reply transmissions, and refusal of both entry
points after completion cannot be confirmed. The maintained driver preserves
its 200 us completion poll and 1000-wakeup fallback. Only observed completion
or confirmed halt returns CPU authority. Unconfirmed halt retains Device
in the owner slot; either halt outcome stops later sends for that boot.

## Linked production space

Measured on 2026-10-10 with `python3 scripts/space_delta.py b1477eab`.
The baseline and candidate are the standard production kernels, not the
isolated test images. The model, test-only overlays and runner add no
production storage or allocation workload.

| Bytes or address | QEMU baseline | QEMU candidate | RPi5 baseline | RPi5 candidate |
| --- | --- | --- | --- | --- |
| text | 727152 | 727152 | 739392 | 739392 |
| data | 5400 | 5400 | 2889208 | 2889208 |
| BSS | 1658432 | 1658432 | 1697344 | 1697344 |
| usable_ram_start | 0x40248000 | 0x40248000 | 0x718000 | 0x718000 |

No data/BSS symbol changes size. Production image and allocator reservation
boundaries do not move. `llvm-nm-19 -S` confirms the existing RPi5 GemTx payload
is 1536 bytes, its owner slot is 40 bytes, and the down flag is one byte.
The cost of introducing that owner and halt path was measured separately in
[GEM_TX_FIXED_SPACE_2026-10-09.md](GEM_TX_FIXED_SPACE_2026-10-09.md).
No new pool, retained page or dynamic allocation is introduced by these
controls. These linked/payload observations are not new live pool-occupancy
or cross-OS comparisons. No space optimization is warranted for this change.

## Physical branch controls

All four final cases passed on 2026-10-10. Each reported actual TSR=33
(TGO clear) and NCR=0 (RX/TX disabled). For unconfirmed cases, the overlay
withheld that actual TGO evidence; retaining Device is intentionally
conservative even when the physical controller has already finished.
Both later send entry points left the submission count at three.

| Case | Checked wire frames | Retained authority | Loaded ELF SHA-256 |
| --- | --- | --- | --- |
| confirmed-ready | 3 | Cpu | cd5437a07df9add6e6700523fcf5a4cb08a59812abadf8351387d7b95d309d28 |
| confirmed-reply | 3 | Cpu | bfa0e3385e017d929c3d74439050e6cb565bc40f0df4b65a75c370546e768fe5 |
| unconfirmed-ready | 3 | Device | 7df562ec7751e13dd7a529244e33cb669127bf695bdd43566df9f553628f7304 |
| unconfirmed-reply | 3 | Device | e3cf9e80f94c5a842c7f614df8f2ecefabbfb0a142864a88f785bbaa5d7d6aae |

Exact loaded images, raw UART, all Ethernet bodies and per-case results are
preserved locally under
`.git/takibi-diagnostics/707/board-handshake/gem-tx-rpi5/`.
The runner snapshots the ELF before load and excludes observations preceding
that load, independently of when buffered UART output reaches the host.
The API rejection control passed; the native shared wait-policy executable
matched its eight-case expected output. Host verifier controls reject absent
fresh mode/completion markers, explicit failures, too few or extra frames,
corrupt payloads and incorrect authority sequences.

## Ordinary checksum-verified bulk transfers

The existing interactive RPi5 shell workload ran with
`KERNEL_RPI5_SHELL_BULK_TCP=1 make kernelcheck-shell-rpi5` on implementation
commit 0df4fe69. Both HTTP checks, process snapshots, bulk bodies and the final
shell prompt passed. Each file had one separately retained warm-up and three
measured samples. Host wall time includes the request and HTTP headers.

| Body | Bytes | Warm-up seconds | Measured seconds | Median seconds |
| --- | --- | --- | --- | --- |
| busybox-extras | 132840 | 0.305331 | 0.171249, 1.111936, 0.113518 | 0.171249 |
| busybox.static | 1116408 | 0.336541 | 0.380279, 0.260328, 0.349483 | 0.349483 |

Every body matched the local built file by length and SHA-256. Raw timings,
body identities and the serving ELF digest are recorded in
[GEM_TX_BULK_2026-10-10.json](GEM_TX_BULK_2026-10-10.json); exact bodies, the
serving ELF and UART/terminal results are preserved locally under
`.git/takibi-diagnostics/707/bulk-final/`.

The 2026-10-04 comparison on f8b30c3b used the same shell workload and body
sizes: disabling the short poll gave large-file samples 13.918919, 13.888157,
13.767390 seconds; the 200 us poll gave 0.299055, 0.266876, 0.230180 seconds.
The current large-file median is about 39.7 times faster than that historical
no-poll median. It retains the observed improvement, while its 0.349483-second
median is above the earlier 0.266876-second poll median. The small-file
1.111936-second outlier remains visible, like the earlier 1.106332-second
outlier. This is a small measured sample across different revisions, not an
isolated cost estimate for ownership checks or a performance guarantee.

## Guarantee boundaries

The FixedDmaOwnership model abstracts guarded slot exchanges and the actual
GEM submit, observation, halt and admission paths. TLC and Apalache checks
cover the fixed behavior and faithful premature-authority/reuse controls;
their verdict is finite abstract evidence. The actual generated GemTxDevice
also fails the CPU-slice API control with nonzero status and the expected
CPU-authority diagnostic. Neither check establishes cache coherence or the
hardware stop contract.

The physical overlays preserve the ownership, wait and halt bodies. They
hide actual USED and, for unconfirmed cases, TGO observations, rather than
fabricating completion or halt success. They run both send paths, observe
real Ethernet bodies, check retained authority, and refuse later sends.
A real RX request establishes host link readiness before counting outbound
frames. After halt, any genuinely received pending frame can exercise the
Down reply branch; the MAC cannot receive a new dedicated test frame then.
The compiler prevents an unconfirmed Device token from becoming CPU buffer
access. The reviewed USED/TGO observation and bus translation remain trusted.

Raspberry Pi OS macb_halt_tx sets THALT and polls TSR.TGO before descriptor
recovery (raspberrypi/linux revision
43c132e8863c3bff3647033b6a7d2bf87b15501c,
drivers/net/ethernet/cadence/macb_main.c). This corroborates the device
contract, not a proof that a faulty controller obeys it. The masked board
control is not a naturally hung MAC; the gap remains explicit in
[SOAK_BACKLOG.md](SOAK_BACKLOG.md).

The next measurement trigger is a change to the fixed allocation/authority
layout, transfer ownership lifetime, completion-wait mechanism, or another
completed kernel feature or stage. A changed runtime allocation workload
requires live occupancy evidence as well as linked-image measurement.
