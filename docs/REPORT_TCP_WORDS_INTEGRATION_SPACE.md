# Display word and TCP cost records integration (2026-11-09)

This measured milestone covers the actual combination of the init report's
display-only AtomicWord and the four retained TCP cost AtomicWord fields.
The baseline is published 1a2a69ee. Both original production ELF/object pairs
and compiler facts were verified against its immutable baseline manifest.
Read-only candidate inspection held the existing shared kernel build lock
after the combined kernelbuild completed; input hashes stayed stable.

| Boundary | QEMU baseline -> combined | RPi5 baseline -> combined |
| --- | --- | --- |
| llvm-size text | 822808 -> 822840 B | 4207428 -> 4207492 B |
| Data | 4624 -> 4624 B | 5600 -> 5600 B |
| BSS | 1318912 -> 1318912 B | 1933312 -> 1933312 B |
| usable_ram_start | 0x40210000 -> 0x40210000 | 0x7e0000 -> 0x7e0000 |
| Init report retained payload | 8 -> 8 B | 8 -> 8 B |
| Three TCP sample records | 96 -> 96 B | 96 -> 96 B |

These are actual combined measurements, not sums of component estimates.
The only data/BSS symbol-size differences are the old init status name
disappearing and the new display word name appearing, each eight bytes.
The replacement keeps its address. Sample field offsets remain 0/8/16/24,
with a 32-byte record. There is no allocator, pool, retained-capacity,
storage-lifetime or physical page reservation change. Existing occupancy
evidence is reused only at that unchanged boundary; no RAM saving is claimed.

Only four actual object text sections and compiler body hashes change:
kernel_init_boot_fixture_reaped, kernel_init_script_success_evidence,
tcp_pool_cost_evidence and pin_sharing_evidence. Other object text remains
byte-identical. All kernel function signatures, qualifiers, inferred effects
and function-value identities remain unchanged. Callee changes are confined
to those four bodies; caller-edge changes only reference those bodies,
including moving the pure shell projection from the reporter to the typed
callback. The JSON retains the exact caller differences, layouts, selected
symbols, allocated/object section changes and artifact/fact hashes. Only
trailing source line numbers are normalized for identity comparison.

INIT_REPORT_WORD_SPACE.md and TCP_COST_WORDS_SPACE.md explain the component
instructions, alignment gaps, FDE ranges and relocation changes at their
stated baselines. The actual combined code growth is 32 bytes on QEMU and
64 bytes on RPi5, consistent with those explanations. Linked relocation
changes outside the four object bodies are not additional source changes.
Static instructions and QEMU timing records do not measure physical latency,
throughput or cache coherence.

ProcessEnd, wait4 and SIGCHLD remain typed closed variants. The display word
is a deliberately lossy log projection, not process status or readiness;
the unchanged pending/reported protocol handles valid code zero. The native
wait_status coverage checks all 512 typed payload cases and retains its host
oracle. TCP stores stay after all four measured results and loads after the
sharing pair; the timed work, mailbox protocol, ordering and literal output
are unchanged. Surrounding execution can still affect later timing values.

Existing AtomicWord access and recursive classification retire exactly two
plain allowance rows. They do not prove projection/publication, CPU ownership,
sample sequencing or a multiword snapshot. No classifier exception, new
authority, protocol or compiler semantics is introduced. Component runtime
receipts retain their recorded source scope; final combined runtime and
hardware acceptance uses the coordinator's exact-HEAD publication checks.

Measure again at the next completed kernel feature, or after changing report
or sample representation, timing intervals, allocation or retained lifetime.
