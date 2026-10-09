# Space review: GEM RX as a fixed DMA allocation (2026-10-09)

Unit: #622 on #131's place rule. `python3 scripts/space_delta.py
origin/main` (RPi5 is the only target with GEM):

- RPi5 data: +8 B; BSS: +32 B. `gem_rx_buf` (2048 B) became `gem_rx`
  (2048 B, the same aligned buffer), and the compiler-created owner slot
  `dma_owner_GemRx` (32 B: mutex and authority) is new.
- usable_ram_start unchanged on both targets; QEMU data/BSS unchanged.
- Text changes are the token moves, the owner-slot exchanges and the
  slice derivation; see the table printed by the command at this commit.

The 32-byte slot is the fixed cost of a device ownership record, the same
form virtio-blk's and xHCI's allocations already pay. Adopted.
