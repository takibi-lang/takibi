# ext2.tkb off the mint list: space review (2026-10-12)

Change: ext2's per-core scratch is per-CPU storage reached through
cpu_here(), and positions in it are (buffer, offset) values whose every byte
access is bounds-checked (ext2_byte/ext2_set_byte), replacing raw *u8
arithmetic (#637).

`python3 scripts/space_delta.py ca699bab` (linked production kernels):

| | qemu base | qemu change | rpi5 base | rpi5 change |
|---|---|---|---|---|
| text | 698496 | 702536 | 711600 | 715848 |
| data | 5328 | 5328 | 2889192 | 2889192 |
| bss | 1660272 | 1660272 | 1696880 | 1696880 |
| usable_ram_start | 0x40248000 | 0x40248000 | 0x710000 | 0x710000 |

Text grows 4040 B (QEMU) and 4248 B (RPi5): each multi-byte field read is
now a chain of checked byte accesses, plus one cpu_here() per operation.
Data, BSS and usable_ram_start are unchanged, and allocation behavior is
unchanged. Adopted: the cost buys a bound on every scratch access. A
cheaper form (check a field's whole width once, then load without further
checks) needs the compiler to carry that width check into the index proof;
not built now. kernelcheck-qemu-main, kernelcheck-qemu-ash and
kernelcheck-rpi5 passed.
