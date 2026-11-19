# Freelist fixture quiescence space

The normal linked QEMU and Raspberry Pi 5 kernels were compared with
`d78156045` using `make kernelbuild-qemu kernelbuild-rpi5` and LLVM 19
ELF tools. The changed workload is the boot-only freelist contention fixture
and its two existing phases. The runtime allocator path and its workload
keep their existing representation.

| Linked-image boundary | QEMU base | QEMU change | RPi5 base | RPi5 change |
|---|---:|---:|---:|---:|
| Text, read-only data and unwind data (bytes) | 830704 | 831904 | 4224028 | 4225196 |
| Writable initialized data including GOT (bytes) | 4616 | 4624 | 5592 | 5600 |
| BSS and stack sections (bytes) | 1310720 | 1310720 | 1916928 | 1912832 |
| Usable RAM start | 0x40210000 | 0x40210000 | 0x7e0000 | 0x7e0000 |

The new admission word uses eight BSS bytes on each target. Initialized
data grows by eight bytes for the GOT. The RPi5 BSS section becomes one
page shorter as the preceding sections push its start to the next page;
its end, the stack section, and the reservation boundary stay fixed.
The memory-map check retains all five ordinary allocator expectations.
The linked section sizes therefore show no change in reserved pages or
allocator capacities.

The candidate's normal static frames are 16 bytes each for register,
unregister and close admission, 96 bytes for close, and 48 bytes each for
open, phase and the secondary runner, on both targets. The RPi5 phase and
secondary runner previously used 32 bytes each. The fixture's top-level
frame grows from 32 to 64 bytes on RPi5 and is 64 bytes in the QEMU
candidate. These are per-function frame records, not a call-chain stack
measurement. Generated QEMU code uses acquire/release LL/SC for the
gate transitions, while RPi5 uses acquire/release CAS. Physical timing
was not measured.

Adopt the fixed image cost for this fixture-only synchronization. Measure
again when registration storage, the boot contention workload, or the
linked reservation boundary changes.
