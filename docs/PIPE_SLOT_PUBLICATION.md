# Pipe slot publication

The Pipe pool initializes its existing 4128-byte record before publishing
a handle. The slot's typed fields include a 4096-byte buffer. One contract
on the inline publication entry requires initialized fields of the live
slot. The matching generated region_give checks the same condition at
direct call sites. No separate runtime flag, write, or padding certificate
is added.

The checker associates the fact with the allocation's current owner. The
generated region_slot_zero operation establishes the fact. Its physical
slot address, representation, and writes retain the preexisting trust
boundary. A new allocation or reacquisition starts without the fact.
Consumption ends it. The contract covers record fields before handle
publication. Pipe ring-length and the correctness of user-copy operations
have their own boundaries.

Compiler controls cover a proved current slot, a direct move, omitted
initialization, a different slot, reacquisition, direct region_give, and
an opaque write through a direct record alias. Removing the existing clear
from the real production source is rejected at the publication call in
both maintained compiler configurations.

## Measured cost

Comparison against fc86f604c using the same normal linked kernels.

| Metric | QEMU baseline | QEMU change | RPi5 baseline | RPi5 change |
| --- | ---: | ---: | ---: | ---: |
| Text bytes | 830420 | 830416 | 4223760 | 4223756 |
| Data bytes | 4608 | 4608 | 5584 | 5584 |
| BSS bytes | 1310720 | 1310720 | 1916928 | 1916928 |
| Usable RAM start | 0x40210000 | 0x40210000 | 0x7e0000 | 0x7e0000 |

The linked text shrinks by 4 bytes on each target. The layout checker
reports the same allocator capacities. No data or BSS symbol changes
size. The existing initializer and allocation workload remain.

Three interleaved compile-only runs per version and target used the
normal main-object commands, with separate fact and output paths.
Median process user plus system time was 12.87 to 12.54 seconds on QEMU
and 13.95 to 13.16 seconds on RPi5. Median peak RSS was 546488 to
544284 KiB and 602236 to 601828 KiB, respectively. The run-to-run
samples vary and do not establish a compiler speedup.

In the integration candidate with CPU-local log staging, the same base
(fc86f604c) gives 830672 text bytes on QEMU and 4223996 on RPi5, increases
of 252 and 236. Data increases by 8 bytes on each target. BSS, usable RAM
starts and allocator expectations are unchanged. Per-function symbol
size changes compose; the total linked text includes layout effects.
The only additional data/BSS symbol is the four-byte emergency polling
array described in the log staging review.
