# process.tkb split (stack_poison.tkb): space review (2026-10-13)

Change: kernel stack poisoning and depth scans move from raw casts in
kernel/kernel/process.tkb into three range functions in
kernel/kernel/stack_poison.tkb (#637 S list).

`python3 scripts/space_delta.py main` (linked production kernels):

| | qemu base | qemu change | rpi5 base | rpi5 change |
|---|---|---|---|---|
| text | 703384 | 703080 | 716656 | 716368 |
| data | 5328 | 5328 | 2889192 | 2889192 |
| bss | 1660272 | 1660272 | 1696880 | 1696880 |
| usable_ram_start | 0x40248000 | 0x40248000 | 0x710000 | 0x710000 |

Text shrinks by 304 B (QEMU) and 288 B (RPi5), because the scan loops are
now shared. Data, BSS and usable_ram_start are unchanged. The poisoned
regions are the same. kernelcheck-qemu-main, kernelcheck-stack-overflow-qemu
and kernelcheck-rpi5 passed.
