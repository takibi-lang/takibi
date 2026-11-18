# Ext2 bitmap initialization space review

The boot exhaustion fixture uses one 4096-byte work page and stores one
1024-byte bitmap block. The contract names the exact written prefix, and
the two restore paths pass that prefix. The allocation, work page size,
and number of saved bitmap bytes remain the same.

Production ELF section sizes (bytes), relative to the pre-change build:

| Target | Text before | Text after | Data | BSS |
| --- | ---: | ---: | ---: | ---: |
| QEMU | 827880 | 827848 | 4608 | 1310720 |
| RPi5 | 4221044 | 4221044 | 5584 | 1916928 |

The compiler control's AArch64 disassembly shows the stack frame of
ext2_bitmap_fill changes from 256 to 240 bytes on both targets.
These observations measure linked sections and one function frame.
The existing kernelcheck-qemu-main workload passed.
