# GEM TX fixed allocation: space (2026-10-09)

Change: #707, gem_tx_buf as the dma_fixed GemTx with its owner slot, and the unconfirmed-completion halt path. Measured with `python3 scripts/space_delta.py` against origin/main 7c25199e:

| | qemu base | qemu change | rpi5 base | rpi5 change |
| text | 726920 | 726920 | 738448 | 739608 |
| data | 5400 | 5400 | 2889152 | 2889208 |
| bss | 1658432 | 1658432 | 1697344 | 1697344 |
| usable_ram_start | 0x40248000 | 0x40248000 | 0x718000 | 0x718000 |
data/BSS symbols changed:
  rpi5: dma_owner_GemTx None -> 40
  rpi5: gem_tx None -> 1536
  rpi5: gem_tx_buf 1536 -> None
  rpi5: gem_tx_down None -> 1

RPi5 only: text +1160 B (token claim/settle, halt path, dropped-frame branch), data +56 B (the 40 B owner slot created full, the 1 B gem_tx_down flag, padding); the 1536 B buffer is renamed, not grown. QEMU unchanged; usable_ram_start unchanged. Adopted: the cost of carrying TX ownership through completion and refusing reuse after an unconfirmed one.
