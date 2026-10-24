# ext2 ENOSPC space review (#698), 2026-10-24

Workload: the production QEMU and RPi5 kernels linked at the #698 branch head
and at origin/main a17c1028, measured with `scripts/space_delta.py`.

| | qemu base | qemu change | rpi5 base | rpi5 change |
|---|---|---|---|---|
| text | 670596 | 675628 | 724420 | 729452 |
| data | 4832 | 4832 | 2889680 | 2889680 |
| bss | 1482416 | 1482416 | 1690736 | 1690736 |
| usable_ram_start | 0x40210000 | 0x40218000 | 0x710000 | 0x718000 |

No data or BSS symbol changed size.

## Where the growth comes from

Text grows by 5032 B on both kernels. Part of it is the NoSpace outcomes: inode
allocation, directory insertion, create, mkdir and rename now carry NoSpace
through, and mkdirat and renameat map it to ENOSPC. The rest is the boot
fixture that fills each bitmap and checks that mkdir and create refuse. On
both kernels that pushes the image end across the next 32 KiB step, so
usable_ram_start moves by 32 KiB: 8 allocator pages fewer.

## The test-only buffer was moved out of BSS

The first version kept the fixture's one-block saved bitmap in BSS
(`ext2_full_fixture_saved`, 1024 B). Against 751d6bc6, that buffer alone
moved the QEMU image across a step. It is gone now. The fixture takes a page
tagged `PageOwnerTag::BootFixture` for each fill and frees it after, and
`ext2_bitmap_fill` and its restore copy the bitmap through the slot's existing
metadata block, so they do not keep the borrowed page. BSS is now identical to
the base.

On the earlier base (751d6bc6), that change alone restored QEMU's page count.
On a17c1028 the base text is 1.4 KiB larger, so the 5 KiB of code crosses the
QEMU step anyway. The pages are lost to code, not to the fixture's state.

## Why the remaining cost stays

The boot fixtures are part of the production image by design, so their code
goes into the image. Keeping only the fixture code out of the production image
would need a separate test build of the kernel, which is out of scope for
#698. Any later code growth of a few hundred bytes would cross the same step.
Adopted.

## Lane time

I ran `kernelcheck-qemu-main` once on origin/main 3dac688b and once on this
branch, one after the other on the shared host. Busy seconds are elapsed time
minus vCPU lease wait (`scripts/summarize_lane_timing.py`):

- base: 291.4 s elapsed, 61.5 s lease wait, 229.9 s busy
- branch: 652.2 s elapsed, 459.4 s lease wait, 192.8 s busy

The branch is not slower; the 37 s difference is noise from other load on
the host. The added phases do one bitmap block write each and a few dozen
mkdirat calls, so the added time is below what one run can resolve. The last
land used 3880 busy lane-seconds, and the budget is 4300.
