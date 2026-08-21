# Kernel Memory Map

Where an address is. Both platforms side by side, because the differences
are the part worth seeing.

This document exists because two separate debugging sessions spent real
time on the question "which region is this address in": diagnosing a
kernel stack overflowing into a process's text page meant a page dump and
a guess about what a repeating 16-byte-stride pattern meant, and a
detector reporting `base=89984` on RPi5 needed two linker scripts and a
page allocator read before anyone could say "that is below the kernel
image, so it is not a stack".

Both were lookups. This is the table.

## How to trust a number here

Rows are in one of three states, and which one is always stated:

- **CHECKED (ELF)** -- read out of the linked `kernel.elf` by
  `scripts/check_kernel_memory_map.py`, which fails the build if this
  document and the build disagree. Run as part of `make kernelbuild`.
- **CHECKED (const)** -- the named `const` is read out of the named `.tkb`
  file by the same script and compared.
- **HAND** -- written by a person, checked by nobody. Treat as suspect
  and verify against the file named in the row. These are the rows that
  will rot; they are marked so a reader knows which ones to distrust
  rather than distrusting the whole document.

Every row names the constant or symbol it comes from and the file that
defines it, so any row can be verified with one `grep` even where nothing
automated does it.

## Platforms at a glance

| | RPi5 | QEMU `virt` |
|---|---|---|
| Kernel load address | `0x00200000` | `0x40000000` |
| Linker script | `kernel/arch/arm64/boot/link.ld` | `kernel/arch/arm64/boot/link_qemu.ld` |
| Kernel-identity L1 block | index 0 (`KERNEL_IDENTITY_L1_INDEX`) | index 1 |
| `USER_TEXT_VA` | `0x40000000` (L1 index 1) | `0x80000000` (L1 index 2) |
| Device MMIO L1 blocks | 64-65 (BCM2712 SoC), 124-127 (RP1 via PCIe) | 0 (GICv2, PL011, virtio-mmio) |
| Defined in | `kernel/platform/rpi5/mmu_layout.tkb` | `kernel/platform/qemu/mmu_layout.tkb` |

State: **HAND**, except the load addresses, which follow from the linker
scripts and are pinned by the `_start` row below.

The two maps are roughly inverted, and it is a real physical-memory-map
fact rather than a choice: RPi5's RAM genuinely starts at physical 0, so
its identity block is index 0 and index 1 is free for the user window. On
QEMU `virt`, RAM starts at `0x40000000` -- index 1 -- and the kernel
enables the MMU without a post-enable jump, so the running PC's VA must
already equal its PA at that instant. Index 1 must be the identity block
there, and the user window moves to index 2.

## Physical layout of the kernel image

Ascending, in the order the linker script emits them. Sizes vary with the
build; the boundaries are what matter.

<!-- checked: elf-symbols -->

| Symbol | RPi5 | QEMU `virt` | Defined by | State |
|---|---|---|---|---|
| `_start` | `0x00200000` | `0x40000000` | linker script `.` assignment | CHECKED (ELF) |
| `__bss_start` | `0x0062d000` | `0x4042c000` | linker script `.bss` | CHECKED (ELF) |
| `__bss_end` | `0x00b0f030` | `0x40915740` | linker script `.bss` | CHECKED (ELF) |
| `boot_stack_run_bottom` | `0x00b10000` | `0x40918000` | linker script `.stack` | CHECKED (ELF) |
| `boot_stack_bottom` | `0x00b14000` | `0x4091c000` | linker script `.stack` | CHECKED (ELF) |
| `boot_stack_top` | `0x00b18000` | `0x40920000` | linker script `.stack` | CHECKED (ELF) |
| `secondary_stack_run_bottom` | `0x00b18000` | `0x40920000` | linker script `.stack` | CHECKED (ELF) |
| `secondary_stack_bottom` | `0x00b1c000` | `0x40924000` | linker script `.stack` | CHECKED (ELF) |
| `secondary_stack_top` | `0x00b20000` | `0x40928000` | linker script `.stack` | CHECKED (ELF) |
| `overflow_stack_run_bottom` | `0x00b20000` | `0x40928000` | linker script `.stack` | CHECKED (ELF) |
| `overflow_stack_bottom` | `0x00b24000` | `0x4092c000` | linker script `.stack` | CHECKED (ELF) |
| `overflow_stack_top` | `0x00b28000` | `0x40930000` | linker script `.stack` | CHECKED (ELF) |
| `usable_ram_start` | `0x00b28000` | `0x40930000` | linker script, `ALIGN(4096)` | CHECKED (ELF) |

`stack_top` is an alias of `boot_stack_top`, kept because `entry.S` names
it. `overflow_stack_top` and `usable_ram_start` are the same address:
`.stack` ends where the page pool begins, and it is already page-aligned.

### An address between `_start` and `usable_ram_start` is kernel image

...and an address at or above `usable_ram_start` is a page the allocator
handed out, or free. Nothing else lives in between.

## Kernel stacks

**Every kernel stack in this kernel has the same shape**: 16384 bytes of
usable stack occupying the UPPER half of a 32768-byte-aligned 32768-byte
region, with the lower half reserved, poisoned, and handed to nobody.

That uniformity is load-bearing, not tidiness. It makes bit 14 of an
address say which half it is in -- 1 inside a stack, 0 below it -- for
every kernel stack, with no per-stack base to load and no memory access.
The generated exception entry tests exactly that bit
(`kernel/arch/arm64/kernel/exception_frame.tkb`'s `stack_guard_shift`), so
a stack of some other size or alignment would be reported as an overflow
on every exception taken while standing on it.

| Stack | Where | Held to the shape by |
|---|---|---|
| Boot | `.stack`, symbols above | `kernel_linker_stacks_well_shaped()` at runtime |
| Secondary core | `.stack`, symbols above | same |
| Overflow report | `.stack`, symbols above | same |
| Per process | a `page_alloc_contiguous(8)` run, anywhere at or above `usable_ram_start` | `scheduled_process_table_probe` |

State: **HAND**. The numbers behind it are CHECKED (const) below.

<!-- checked: consts -->

| Constant | Value | Defined in | State |
|---|---|---|---|
| `PAGE_SIZE` | 4096 | `kernel/mm/page.tkb` | CHECKED (const) |
| `PAGE_META_BYTES` | 128 | `kernel/mm/page.tkb` | CHECKED (const) |
| `BOOT_PAGE_COUNT` | 204800 | `kernel/mm/page.tkb` | CHECKED (const) |
| `KERNEL_STACK_PAGES` | 4 | `kernel/kernel/process.tkb` | CHECKED (const) |
| `KERNEL_STACK_SHIFT` | 14 | `kernel/kernel/process.tkb` | CHECKED (const) |
| `KERNEL_PROCESS_MAX` | 16 | `kernel/kernel/process.tkb` | CHECKED (const) |
| `USER_SPACE_PAGE_COUNT` | 262144 | `kernel/mm/address_space.tkb` | CHECKED (const) |
| `ADDRESS_SPACE_MAX` | 16 | `kernel/mm/address_space.tkb` | CHECKED (const) |
| `USER_RANGE_WINDOW` | `0x40000000` | `kernel/mm/user_memory.tkb` | CHECKED (const) |
| `PROCESS_HEAP_PAGES_DEFAULT` | 128 | `kernel/mm/process_image.tkb` | CHECKED (const) |
| `PROCESS_STACK_LOW_STATIC` | 448 | `kernel/mm/process_image.tkb` | CHECKED (const) |
| `PROCESS_STACK_LOW_DYNAMIC` | 504 | `kernel/mm/process_image.tkb` | CHECKED (const) |

Derived, so **HAND** -- each is arithmetic on the rows above, stated here
because these are the numbers people actually quote:

| | | |
|---|---|---|
| `PAGE_USABLE_BYTES` | 3968 | `PAGE_SIZE - PAGE_META_BYTES` |
| `KERNEL_PROCESS_STACK_SIZE` | 16384 | `KERNEL_STACK_PAGES * PAGE_SIZE` |
| `KERNEL_STACK_RUN_BYTES` | 32768 | twice the above |
| Page pool extent | 800 MiB | `BOOT_PAGE_COUNT * PAGE_SIZE` |
| Page pool end (RPi5) | `0x32b28000` | `usable_ram_start + 800 MiB` |
| Page pool end (QEMU) | `0x72930000` | `usable_ram_start + 800 MiB` |

## A page is 3968 bytes of payload, not 4096

The last `PAGE_META_BYTES` (128) of **every** page belong to the
allocator, not to whoever holds the page. `page_meta_at(physical)` names
that region; pool primitives keep their per-chunk bookkeeping there
instead of in a side array sized by the number of pages.

Two separate bugs came from code that assumed a page is 4096 bytes of
payload, one of which was a kernel stack whose first push landed inside
its own page's metadata and forged a pool chunk header. If you are about
to write `4096` where a payload size belongs, this is the row you needed.

**Exception, and it is deliberate**: a run from `page_alloc_contiguous` is
all payload. Its pages are marked `in_run` and `page_meta_at` answers 0
for them, so the whole `count * PAGE_SIZE` is contiguous and usable --
which is the only way a multi-page kernel stack can exist at all, and also
what stops any pool reading a run's bytes as its own chunk header. The
region goes back to being metadata when the run is freed, scrubbed on the
way out.

## Virtual layout of a user process

One address space per process, with its own ASID and its own L2/L3 tables.
The backing pages come from the same physical pool as everything else --
the VAs below are purely virtual and have no physical meaning.

State: **HAND** throughout; the constants are CHECKED (const) above.

| Region | VA | Notes |
|---|---|---|
| Window base | `USER_TEXT_VA` | `0x40000000` on RPi5, `0x80000000` on QEMU |
| Window size | `USER_RANGE_WINDOW` = 1 GiB | what `user_range_check` accepts |
| Window pages | `USER_SPACE_PAGE_COUNT` = 262144 | 1 GiB at `PAGE_SIZE` |
| Text / rodata / rw | from page 0 upward | laid out by the ELF loader, `kernel/mm/process_image.tkb` |
| Heap | above the image | `PROCESS_HEAP_PAGES_DEFAULT` = 128 pages |
| Stack guard | one unmapped page below `stack_low_page` | the only genuinely unmapped guard in this kernel |
| Stack, lowest page | `stack_low_page` | 448 (static) or 504 (dynamic/musl), per image |
| Stack, top page | `USER_SPACE_PAGE_COUNT - 1` | `process_stack_top_page()` |

A page index in this table becomes an address as
`USER_TEXT_VA + index * PAGE_SIZE`.

The static and dynamic paths differ only in `stack_low_page`, because the
musl image's own heap reaches higher. Both are bounded virtual
reservations, not eager allocations: pages inside the interval are mapped
on an EL0 translation fault.

## Device MMIO

Identity-mapped as 1 GiB L1 blocks, device-nGnRnE, UXN+PXN.

State: **HAND** -- read from each platform's `mmu_layout.tkb`.

| Platform | L1 indices | Covers |
|---|---|---|
| RPi5 | 64-65 | BCM2712 SoC peripherals, including the VideoCore mailbox |
| RPi5 | 124-127 | RP1's PCIe-translated MMIO/BAR window: UART, xHCI, GEM |
| QEMU `virt` | 0 | GICv2 (`0x08000000`), PL011 (`0x09000000`), virtio-mmio (`0x0a000000`) |

An L1 index is `PA >> 30`, so index *n* covers `[n GiB, (n+1) GiB)`.

## Answering the question this document exists for

Given an address from a boot log or an oops line:

1. Below `_start`? Not this kernel's. On RPi5 that includes everything
   under `0x200000`, which is where a bad "kernel stack base" landed once.
2. Between `_start` and `__bss_end`? Kernel image -- text, rodata, data,
   or bss.
3. Between `__bss_end` and `usable_ram_start`? One of the three
   linker-provided stacks. Which one, and which half, from the symbol
   table above: an address in a run's LOWER half is an overflow that has
   already happened.
4. At or above `usable_ram_start`, below the pool end? A physical page
   from `kernel/mm/page.tkb`. Whether it is live, and whether it is part
   of a run, is in `boot_page_pool.meta[(pa - usable_ram_start) / 4096]`.
5. In `[USER_TEXT_VA, USER_TEXT_VA + 1 GiB)`? A user virtual address --
   which process's depends on the live ASID/TTBR0.
6. `PA >> 30` in a device row? MMIO.

## Related documents

- `kernel/RESOURCE_LIMITS.md` -- how much of each resource exists, and
  what happens when it runs out. This document says where; that one says
  how many.
- `kernel/RUNTIME_STATE.md` -- the mutable global state and who owns it.
- `kernel/README.md` -- the kernel's own overview and current limits.
