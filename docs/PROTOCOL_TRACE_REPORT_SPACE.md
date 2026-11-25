# Protocol trace report space

Normal linked QEMU and Raspberry Pi 5 kernels were compared with
`598ff7a94` using `make kernelbuild` and LLVM 19
ELF tools. The workload is the boot protocol trace's regular open,
record and close/report sequence. The event capacity remains 512.

| Linked-image boundary | QEMU base | QEMU report | RPi5 base | RPi5 report |
|---|---:|---:|---:|---:|
| Text, read-only data, unwind data (bytes) | 847676 | 848612 | 4242116 | 4243124 |
| Initialized writable data and GOT (bytes) | 4624 | 4624 | 5600 | 5600 |
| BSS and stack sections (bytes) | 1310720 | 1310720 | 1892352 | 1892352 |
| Usable RAM start | 0x40218000 | 0x40218000 | 0x7e0000 | 0x7e0000 |

The event buffer grows from 32768 to 32776 bytes with its guarded
reporting flag and padding. The linked BSS and stack sections, both
usable RAM starts, and the five allocator expectations in the
memory-map check remain unchanged.

Both targets have the same normal per-function frame sizes. The
reporter's frame grows from 96 to 192 bytes and the close caller's
from 32 to 64. Recording and opening retain their 16- and 32-byte
frames. The new row-copy helper has a 16-byte frame. The generated
report loop calls lock, row copy, unlock, then print in that order.
This is static per-function evidence, without full call-chain peaks.

A successful close now takes one guard for admission and header, one
per stored event to copy the row, and one for report completion. The
old report took only the guard used to close. The prepare and finish
holds do no UART work, and the row holds copy the nine scalar event
fields. This is a derived bound on operations, without measured lock
latency or physical timing. Recording uses the prior writer guard
and no additional acquisition. Adopt the fixed cost for report
isolation, and remeasure if row shape, capacity, lock scope or
the image reservation changes.
