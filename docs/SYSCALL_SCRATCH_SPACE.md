# Slot-owned syscall scratch space

Compared the normal linked QEMU and Raspberry Pi 5 kernels with
`5c67235f8` using the maintained builds. Static stack records come from
the same AArch64 objects. This comparison covers the fixed image and
per-function stack frames. It does not measure cycle cost, concurrent stack
high-water marks, or physical timing.

| Measurement | QEMU before | QEMU after | RPi5 before | RPi5 after |
| --- | ---: | ---: | ---: | ---: |
| Text (bytes) | 834736 | 834496 | 4227788 | 4227532 |
| Data (bytes) | 4624 | 4624 | 5600 | 5600 |
| BSS (bytes) | 1310720 | 1310720 | 1908736 | 1908736 |
| `usable_ram_start` | `0x40210000` | `0x40210000` | `0x7e0000` | `0x7e0000` |
| Syscall scratch (bytes) | 11696 | 11696 | 11696 | 11696 |
| Slot acquire words (bytes) | 32 | 32 | 32 | 32 |
| `syscall_execve_current_with` frame (bytes) | 160 | 112 | 160 | 112 |
| `syscall_getdents64_current_with` frame (bytes) | 416 | 432 | 416 | 432 |
| `syscall_renameat_under_with` frame (bytes) | 560 | 576 | 560 | 576 |

In RPi5 debug, execve's worker goes from 352 to 480 bytes, getdents64's
worker from 608 to 640, and rename's worker from 736 to 800. Reusing the
pathname's normalized span to determine whether it is absolute removed
32 bytes of the rename debug frame from the first caller migration. The
normal frame sizes stayed the same. A getdents64 trial deriving the user
output cursor from the input offset left the normal frame unchanged and
raised the debug frame another 16 bytes, so the separate output cursor is
kept. Both images keep the existing frame ceilings.

No linked writable symbol changed size. The pool still has four equal slots
and uses its existing compare-exchange words. The compiler checks slot
access and per-call initialization.
The migration keeps scratch-backed bytes in the live borrow. Callers form
views locally and the pathname decoder returns only two byte offsets.
The existing rename buffer copy and command-line snapshot copy still serve
their prior lifetimes. In the normal QEMU directory-name byte loop the
source-level refined offset guard is optimized away, leaving the loop
limit branch and the existing byte write.

Remeasure when the scratch layout, pathname staging/copy boundary, or
stack budget for these syscalls changes.
