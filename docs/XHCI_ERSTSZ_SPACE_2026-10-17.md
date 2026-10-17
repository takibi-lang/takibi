# #754: xHCI ERSTSZ write, space (2026-10-17)

Interrupter 0's first ERST write now goes to ERSTSZ (+0x488) instead of
IMAN (+0x480); Rp1XhciRegs gains one io field. Measured with
scripts/space_delta.py against main e8644b37:

```
| | qemu base | qemu change | rpi5 base | rpi5 change |
| text | 697368 | 697368 | 747976 | 747976 |
| data | 4760 | 4760 | 2889560 | 2889560 |
| bss | 1486352 | 1486352 | 1692672 | 1692672 |
| usable_ram_start | 0x40218000 | 0x40218000 | 0x718000 | 0x718000 |
no data/BSS symbol changed size
```

Assessment: no size change on either image; the store targets a different
offset of the same handle. Accepted.
