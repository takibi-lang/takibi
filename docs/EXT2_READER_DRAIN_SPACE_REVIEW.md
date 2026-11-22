# Ext2 reader-drain space review

The first ordinary writer that parks for existing ext2 readers is mkdirat.
It holds its mutation admission through the wait and leaves its private
stack through the ordinary idle route. The reader count and the task's
existing scheduler state carry the protocol without a new allocation.

## Linked production kernels

Measured against `5793c2f77` with the same toolchain and normal link recipes.

| Boundary | QEMU base | QEMU drain | RPi5 base | RPi5 drain |
| --- | ---: | ---: | ---: | ---: |
| Linked text bytes | 840416 | 842604 | 4235908 | 4238120 |
| Linked data bytes | 4624 | 4624 | 5600 | 5600 |
| Linked BSS bytes | 1310720 | 1310720 | 1896448 | 1896448 |
| Usable RAM start | 0x40210000 | 0x40210000 | 0x7e0000 | 0x7e0000 |

No data or BSS symbol changed size, and the linked map and five allocator
expectations passed. Process records remain 2200 bytes. The normal QEMU
boot took the standard pool snapshots. The process pool had 7 slots and
1 occupied at boot, and 28 slots and 1 occupied at the bounded endpoint.
The snapshots do not measure peak occupancy during a drain.

The phase adding the post-decrement barrier increased QEMU linked text
by 16 bytes and left RPi5 linked text unchanged. Both binaries put the
barrier after the atomic decrement and before the mutex query, on the
last-reader branch. This is generated code evidence, not a timing
comparison. Sharing the existing CPU snapshot mint adds 4 bytes of
linked unwind encoding on each target. The executable section size and
both affected functions' instruction bodies stay the same; the changed
unwind size shifts some linked relocations.

## Live wait and completion

An optional observer used the normal QEMU kernel and ordinary openat and
mkdirat calls. It held the reader before the normal decrement while the
writer moved to its idle stack, then observed the reader wake the writer
before software released its stack ownership. The resumed writer kept its
frame, slot and generation. In a second run, the normal reader decremented
from two to one and the rejected admission rolled the count from one to
zero and woke the writer. The reader calls, parked mkdirat and follow-up
mkdirat succeeded. The observer used the candidate before the shared CPU snapshot mint.
The controlled ordering shows those transitions and does not measure
their natural frequency or hardware timing.

The 2188-byte QEMU and 2212-byte RPi5 text growth adds no linked data or
new page reservation. Remeasure at the next writer integration, when the
waiting representation changes, or when measuring physical contention.

## Killable directory admission

A validated ext2 getdents64 waits behind a writer before taking a reader
registration or touching any output. An ordinary caught signal stays
pending through that wait. Once a complete record exists, the iterator
can return the prefix with the next unread offset. SIGKILL wakes the
waiting syscall at the same ordinary continuation, before any output.

Measured on linked production ELFs against the completed mkdirat drain
at `8ad447f17`.

| Boundary | QEMU drain | QEMU directory admission | RPi5 drain | RPi5 directory admission |
| --- | ---: | ---: | ---: | ---: |
| Linked text accounting bytes | 842604 | 843780 | 4238120 | 4239408 |
| Linked data bytes | 4624 | 4624 | 5600 | 5600 |
| Linked BSS bytes | 1310720 | 1310720 | 1896448 | 1896448 |
| Usable RAM start | 0x40210000 | 0x40210000 | 0x7e0000 | 0x7e0000 |

The first link put the last 208 executable bytes into the following
QEMU page and pulled the static stacks to the next 32 KiB alignment.
Inlining the directory eligibility and ordinary park facades and the
signal-result selection recovered those 208 executable bytes without
changing the linker layout. QEMU executable .text is 663552 bytes.
The main dispatch frame is 320 bytes on QEMU and 288 bytes on RPi5,
from 240 on both. The directory body retains its syscall scratch slot
only after admission. Its prefix check takes the existing process run
lock after a record exists. Timing and peak stack depth were not
measured.
