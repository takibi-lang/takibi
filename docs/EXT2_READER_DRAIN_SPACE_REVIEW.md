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

## Sleeping unlinkat

The normal linked kernel baseline is `fe2491d92`, with the mkdirat drain
and getdents64 admission waits in place. The candidate shares the
post-acquisition path between mkdirat and unlinkat. The focused QEMU
workload holds a counted reader, runs an actual unlinkat with
`AT_REMOVEDIR`, and observes the same frame, process slot and generation
at resume after that reader releases. Recreating the removed directory
checks that the operation completed. This orders the events with GDB.

| Accounting boundary | QEMU baseline | QEMU candidate | RPi5 baseline | RPi5 candidate |
| --- | ---: | ---: | ---: | ---: |
| Linked text accounting (bytes) | 843780 | 843752 | 4239408 | 4239380 |
| Linked data (bytes) | 4624 | 4624 | 5600 | 5600 |
| Linked BSS (bytes) | 1310720 | 1310720 | 1896448 | 1896448 |
| Usable RAM start | 0x40210000 | 0x40210000 | 0x7e0000 | 0x7e0000 |
| Dispatch frame (bytes) | 320 | 320 | 288 | 288 |

The initial candidate duplicated the post-acquisition body and moved the
QEMU static stack alignment by 32768 bytes. Joining the two control paths
after acquisition and inlining the small dispatch helpers recovers that
reservation without a linker layout change. No data or BSS symbol changed
size. The wait uses the existing task and guard state. Scratch acquisition
still follows reader drain. Peak stack depth and real contention timing
remain unmeasured.

## Sleeping renameat

The normal linked kernel baseline is `77a3289f3`. The candidate joins
renameat to the existing pathname mutation wait. In the focused QEMU
workload, a counted reader holds the wait open until renameat reaches
the ordinary drain park. After that reader leaves, the observer checks
the same frame, process slot and generation. The syscall uses separate
source and destination pathnames. Removing the destination and recreating
the source verify that the rename completed.

| Accounting boundary | QEMU baseline and candidate | RPi5 baseline and candidate |
| --- | ---: | ---: |
| Linked text accounting (bytes) | 843704 | 4239348 |
| Linked data (bytes) | 4624 | 5600 |
| Linked BSS (bytes) | 1310720 | 1896448 |
| Usable RAM start | 0x40210000 | 0x7e0000 |
| Dispatch frame (bytes) | 320 | 288 |

All data and BSS symbols retain their sizes. The wait uses the existing
task and guard state. Scratch acquisition follows reader drain, and
fixture progress is reported after guard release. Peak depth and physical
contention timing remain unmeasured.

## Sleeping truncate and ftruncate

The normal linked kernel baseline is `04724feab`. Two focused QEMU
workloads issue actual truncate and ftruncate calls after positioning an
open file at byte 3. In each, the observer holds a counted reader until
the writer reaches the ordinary drain park, releases the count and checks
resumption on the same frame, slot and generation. Each guest checks
`EINVAL` for nonzero length, a zero final file size and an unchanged open
offset after successful truncation.

| Accounting boundary | QEMU baseline | QEMU candidate | RPi5 baseline | RPi5 candidate |
| --- | ---: | ---: | ---: | ---: |
| Linked text accounting (bytes) | 843704 | 843672 | 4239348 | 4239316 |
| Linked data (bytes) | 4624 | 4624 | 5600 | 5600 |
| Linked BSS (bytes) | 1310720 | 1310720 | 1896448 | 1896448 |
| Usable RAM start | 0x40210000 | 0x40210000 | 0x7e0000 | 0x7e0000 |
| Dispatch frame (bytes) | 320 | 320 | 288 | 288 |

The two syscalls share the existing post-acquisition dispatch path. Their
scratch allocation, validation and filesystem mutation follow reader
drain. All data and BSS symbol sizes agree with the baseline. The QEMU
observers force an event ordering. Physical contention timing and peak
stack depth remain unmeasured.

## Sleeping mutating openat

The normal linked kernel baseline is `18fa7046c`. The focused QEMU
workloads exercise the ordinary writer wait through openat with
`O_CREAT | O_EXCL` on a missing path and `O_TRUNC` on a populated file.
Each observer holds an admitted reader until the writer reaches its
drain park and checks the frame, slot and generation on resume. The
guest checks file size, the exclusive-open error, and plain and
exclusive procfs results.

| Accounting boundary | QEMU baseline | QEMU candidate | RPi5 baseline | RPi5 candidate |
| --- | ---: | ---: | ---: | ---: |
| Linked text accounting (bytes) | 843672 | 843704 | 4239316 | 4239348 |
| Linked data (bytes) | 4624 | 4624 | 5600 | 5600 |
| Linked BSS (bytes) | 1310720 | 1310720 | 1896448 | 1896448 |
| Usable RAM start | 0x40210000 | 0x40210000 | 0x7e0000 | 0x7e0000 |
| Dispatch frame (bytes) | 320 | 320 | 288 | 288 |

Sharing guard release and syscall completion recovers the 32 KiB QEMU
alignment reservation observed with separate completion paths. Data and
BSS symbols retain their sizes. The existing guard is acquired before
path lookup, scratch use and descriptor allocation. The observers force
the ordering. Physical contention timing and peak depth remain unmeasured.

## Ordinary reader admission after SVC affinity migration

Matched normal images on 2026-11-24 against 4dcbfb3b3. The candidate
adds ordinary reader admission and records the first fatal signal that
commits termination during the wait.

| Image | Text before -> after | Data | BSS | Usable RAM start |
| --- | ---: | ---: | ---: | --- |
| QEMU | 846612 -> 847676 B | 4624 B | 1310720 B | 0x40218000 |
| RPi5 | 4241124 -> 4242116 B | 5600 B | 1892352 B | 0x7e0000 |

The combined QEMU image remains within the already approved reservation
step. Neither allocator start moves from this baseline. These figures
measure linked images. Remeasure when the reader-writer admission policy
or the shared file-position lifetime changes.

Rebuilding the same reader candidate with the in-compiler caller policy
produced byte-identical normal objects, ELFs, call graphs and source
signatures on both targets. The linked-image comparison above applies
to the combined candidate.
