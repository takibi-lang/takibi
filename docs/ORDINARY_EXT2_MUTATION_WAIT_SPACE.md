# Ordinary ext2 mutation wait space

The normal kernel images below compare the first ordinary mkdirat wait
and restore slice with published base `617f5f2d0`. The base sizes come
from the getrusage fixture's linked measurements. The candidate figures
come from the maintained board-free kernel build.

| Target | Text class before | Text class after | Data | BSS before | BSS after | Usable RAM start |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| QEMU | 834484 B | 840432 B | 4624 B | 1310720 B | 1310720 B | 0x40210000 |
| RPi5 | 4227680 B | 4233516 B | 5600 B | 1908736 B | 1904640 B | 0x7e0000 |

The candidate adds 5948 B and 5836 B of linked text class, respectively.
The RPi5 BSS difference is linked packing within the same image
reservation. Both targets retain the same usable-RAM boundary. The
AArch64 save and restore leaves are 76 B and 72 B on both targets.

The compiled ProcessRecord grows from 2192 B to 2200 B for one saved-SP
word. An earlier QEMU build of this slice observed the same process-pool
geometry and bounded occupancy at both sizes. Each chunk is 16 KiB with
seven slots and 24 B of pool metadata. Boot used one chunk and one live
slot. The bounded workload ended with four chunks and one live slot.
The continuation saves one 176 B context on the task's existing private
stack. It allocates no extra stack.

Normal compiled frame sizes on both targets include 112 B for the syscall
dispatch, 128 B for the ordinary park, 80 B for completion, 48 B for the
mkdirat retry, and 16 B each for the shared try and the release-then-wake
wrapper. These are individual frame measurements. Live stack high water
and the RPi5 timing cost remain unmeasured.

An earlier exact QEMU image was tested with a guest writer, ordinary
waiter and counted reader. The scratch observer saw the reader take
SIGTERM, give up its registration before the terminal exit tail, and
resume the waiter on the original frame, slot and generation. A
following mutation succeeded. The current linked report covers the
subsequent neutral ext2 lock split and the mandatory frame-bearing
landing check. The earlier run supplies behavioral evidence for the
observed image and order.

Remeasure with the reader-drain wait and again when a registered reader
can sleep. The space accounted here does not include those stages.
