# xHCI boot slot publication

The RPi5 driver holds the block-device guard from Enable Slot submission
through Address Device. The existing command matcher accepts only the
completion for the submitted TRB. Its successful status and slot ID in
1 through 64 permit a private linear update view indexed by that slot
and the guarded command-completion count. The hardware configuration still
enables one slot. Both DCBAA words use the checked indices derived from
the slot. The table clean precedes the creation of the publication view
consumed by Address Device. Slot zero still names the scratchpad array.

CPU serialization, the matching event observed by the synchronous ring,
DMA visibility, and confirmed reset remain the existing trusted premises.
The transient views carry no runtime ownership of the DCBAA allocation or
output-context storage. The existing output-context protocol keeps that
storage live even if Address Device is abandoned, times out or completes
with an error. A later successful command does not reclaim it.

## Linked space

Normal images built against published e275083b8, with the existing boot
USB workload and native event-matching controls.

| Metric | QEMU base and candidate | RPi5 base | RPi5 candidate |
| --- | ---: | ---: | ---: |
| Text bytes | 843704 | 4237876 | 4238240 |
| Data bytes | 4624 | 5600 | 5600 |
| BSS bytes | 1310720 | 1896448 | 1896448 |
| Usable RAM start | 0x40210000 | 0x7e0000 | 0x7e0000 |

The QEMU image is byte-identical. RPi5 adds 364 text bytes and changes
no data or BSS symbol sizes. The 520-byte, 64-byte-aligned DCBAA stays at
0x652080. The linked static frames for Enable Slot and Address Device were
80 and 160 bytes. The new frames are 96 and 96 bytes, with an 80-byte
submission frame nested inside Address Device. Together they add 112 bytes
on the Address Device submission path before the common ring-submit
routine. The existing static frame and alignment gates pass. This is a
linked frame comparison. Physical stack occupancy and USB timing await
board evidence.

Measure again when slot reuse, completion ordering, or the output-context
storage contract changes.
