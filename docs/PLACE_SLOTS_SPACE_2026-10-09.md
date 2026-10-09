# Place slots: space (2026-10-09)

Change: #131 slice 2. Every stored linear slot is a `Place(T)` field and
`stable_replace` left the source language; a fixed DMA record's owner slot
is a `Place` of its two-case authority, created full.

Measured with `python3 scripts/space_delta.py` (base origin/main 145c5297,
change c2ba37e8), linked production kernels:

| | qemu base | qemu change | rpi5 base | rpi5 change |
| text | 726276 | 726164 | 737596 | 737692 |
| data | 5078 | 5400 | 2888792 | 2889152 |
| bss | 1658608 | 1658352 | 1697632 | 1697344 |
| usable_ram_start | 0x40248000 | 0x40248000 | 0x718000 | 0x718000 |
data/BSS symbols changed:
  qemu: dma_owner_MscCbwTransmit 32 -> 40
  qemu: dma_owner_MscCswReceive 32 -> 40
  qemu: dma_owner_MscDataReceive 32 -> 40
  qemu: dma_owner_MscDataTransmit 32 -> 40
  qemu: dma_owner_VirtioBlkDataTransmit 32 -> 40
  qemu: dma_owner_VirtioBlkReceive 32 -> 40
  qemu: dma_owner_VirtioBlkRequestTransmit 32 -> 40
  qemu: dma_owner_XhciControlReceive 32 -> 40
  rpi5: dma_owner_GemRx 32 -> 40
  rpi5: dma_owner_MscCbwTransmit 32 -> 40
  rpi5: dma_owner_MscCswReceive 32 -> 40
  rpi5: dma_owner_MscDataReceive 32 -> 40
  rpi5: dma_owner_MscDataTransmit 32 -> 40
  rpi5: dma_owner_VirtioBlkDataTransmit 32 -> 40
  rpi5: dma_owner_VirtioBlkReceive 32 -> 40
  rpi5: dma_owner_VirtioBlkRequestTransmit 32 -> 40
  rpi5: dma_owner_XhciControlReceive 32 -> 40

Reading:

- Each DMA owner slot grows 32 -> 40 B: the place's tag now wraps the
  authority's own tag. Nine slots on RPi5, eight on QEMU.
- The slots move from BSS to data because the global is created full
  (Full(Cpu(token))) rather than relying on a zero tag being the CPU case:
  QEMU data +322 B / BSS -256 B, RPi5 data +360 B / BSS -288 B.
- Text: QEMU -112 B, RPi5 +96 B (the take helpers fail-stop on an empty
  slot themselves, so callers lost an arm; the nested match on the
  authority adds a test).
- Every other place (exec args, spare stack run, network capability, TCP
  links) keeps its layout: Place's two cases match the variants they
  replaced.
- usable_ram_start is unchanged on both targets.

Adopted: about 8 B per DMA slot buys the place form for DMA authority and
an explicit created-full initial state instead of a case-order convention.
