# Sampling profiler space (2026-10-13)

GitHub issue #497: kernel/kernel/profile_session.tkb, the /proc/takibi
procfs nodes, and the per-core PMU routing.

## Fixed image

Linked kernels against main cf3d2ab1 (`scripts/space_delta.py main`):

| | qemu base | qemu change | rpi5 base | rpi5 change |
|---|---|---|---|---|
| text | 703384 | 712792 | 716656 | 726080 |
| data | 5328 | 5392 | 2889192 | 2889256 |
| bss | 1660272 | 1660704 | 1696880 | 1700976 |
| usable_ram_start | 0x40248000 | 0x40248000 | 0x710000 | 0x718000 |

New data/BSS: profile_core_state 256 B, profile_core_store 128 B, six
session words of 8 B each (both targets). Text grows 9.4 KB, mostly the
session module, the control-file parser and the procfs/getdents
additions. On RPi5 the image end crosses a page boundary, so
usable_ram_start moves 32 KB and the boot view's allocator pages drop
from 259312 to 259304 (kernel/tests/rpi5/views/boot.expected).

## Runtime

Idle: no buffer is allocated and no counter is armed. The cost is one
acquire load and compare per timer tick per core (profile_session_sync).

During a session: one run per online core from page_alloc_contiguous,
the smallest power-of-two page count holding SAMPLES records of 168 B
(the default of 2048 samples needs 512 KB per core, 2 MB on four cores),
given back by DDB `profile dump`. A start that cannot allocate every core's
buffer returns all of them and answers ENOMEM.

## Assessment

Adopted. The maintainer's D4 decision (no idle storage) holds. The fixed
image cost is the 9.4 KB of text and 0.4 KB of data/BSS above.
