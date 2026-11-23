# Projected Pipe lock space review

The comparison uses the normal linked QEMU and RPi5 kernels at fe2491d92
and the same two targets with checked projected Pipe locking. The compiler
checks the lock word and the linear owner at build time. This review covers
the compiled representation and the linked image. It makes no claim about
contention, elapsed runtime, or the space high-water marks of a live workload.

| Accounting boundary | QEMU before | QEMU after | RPi5 before | RPi5 after |
| --- | ---: | ---: | ---: | ---: |
| Main object text accounting (B) | 842055 | 842175 | 4227073 | 4227193 |
| Linked text accounting (B) | 843780 | 843740 | 4239408 | 4239384 |
| Linked executable .text (B) | 663552 | 663536 | 708260 | 708260 |
| Linked unwind table (B) | 124988 | 124964 | 135924 | 135900 |
| Linked data accounting (B) | 4624 | 4624 | 5600 | 5600 |
| Linked BSS accounting (B) | 1310720 | 1310720 | 1896448 | 1896448 |
| Usable RAM start | 0x40210000 | 0x40210000 | 0x7e0000 | 0x7e0000 |

The unlinked main objects include the inline adapter definitions. The
linked images discard their out-of-line copies and the old separate
release helper. On both targets the static frames for pipe_take, pipe_put,
and pipe_free remain 32, 32, and 48 bytes respectively. The unlinked release
helper's frame changes from 16 to 32 bytes. There is no such out-of-line
symbol in the linked candidate. Pipe, PipeOwner, and TaskMutex remain
4128, 16, and 8 bytes respectively on both targets. The records and pool
allocations use their existing representation.

The comparison uses llvm-size-19, the linked usable_ram_start symbol,
LLVM stack-size records in main.o, and the compiled struct layout facts.
Remeasure when the lock or owner gains runtime storage, or when the Pipe
ring and write-effect changes alter the linked copy paths.
