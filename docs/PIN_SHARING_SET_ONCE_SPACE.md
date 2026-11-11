# Pin-sharing publication space review

The bounded boot pin-sharing probe allocates one page for a private
RegionPool, validates 32 handles, runs alternating shared-line and
separate-line rounds, and returns the page after all workers finish.
Failures after a successful grow still retain the pool, including when
a worker may finish late. The handle table is published as a unit
before the round publication. Each worker selects its handle before
starting its 4096 pin/unpin timing interval.

## Linked images

Measured with LLVM 19 from the maintained images, against 96e3db02.
Both sides use the same platform and normal or debug build target.

| Target | Text before | Text after | Data | BSS | Usable RAM start |
| --- | ---: | ---: | ---: | ---: | --- |
| QEMU normal | 823144 | 824080 | 4608 | 1314816 | 0x40210000 |
| QEMU debug | 899764 | 900740 | 4608 | 1314816 | 0x40220000 |
| RPi5 normal | 4207828 | 4208780 | 5584 | 1929216 | 0x7e0000 |
| RPi5 debug | 4293312 | 4294336 | 5584 | 1843200 | 0x7e0000 |

Data, BSS and usable RAM start are identical within each pair. In each
image, the handle symbol grows from 768 to 776 bytes: 32 handles at 24
bytes each and one eight-byte publication word. Existing BSS alignment
absorbs the eight bytes. Pool payload and state layout, the single
page of capacity, and the retention boundary use the same workload.

## Stack and copies

Object prologues on both platforms give the same frames within each
mode. All values are bytes and the ceiling is 2048 bytes per function.

| Function | Normal before | Normal after | Debug before | Debug after |
| --- | ---: | ---: | ---: | ---: |
| Setup | 96 | 1632 | 144 | 1680 |
| Cycles | 96 | 96 | 160 | 160 |
| Cleanup | 64 | 64 | 96 | 96 |
| Indexed read | - | 32 | - | 32 |

Setup initializes one 768-byte local and passes a 768-byte publication
argument. The publisher copies the value into the cell before the
release store. The local clear makes the existing definite-assignment
check accept an early-exit fill loop. Each successful iteration
replaces one entry with its real handle; any allocation failure exits
before the claim. Layout and live-count validation still gate the claim.

In all four objects, the reader calls the acquire check at cell offset
768, computes the element address using stride 24, and loads the
handle with one paired word load and one single word load. It returns
the three handle words and the outcome tag in registers. The unset
path returns the outcome tag without reading the payload. There is
no array copy or returned reference on the read path. The acquire
check's own frame is 16 bytes in both modes. This records per-function
stack use and generated work outside the timing interval.

The one-time setup frame and text growth fit the existing limits. The
published handles still identify pool slots whose liveness is checked
by the existing region operations. Revisit this measurement if the
handle count, handle layout, or fixture allocation or retention
boundary changes.
