/* QEMU/AArch64 `virt` machine linker script (GitHub issue #237). Mirrors
 * kernel/arch/arm64/boot/link.ld's (RPi5) section/stack/usable_ram_start
 * shape exactly -- only the load address differs, matching QEMU `virt`'s
 * RAM base (examples/common_qemu/link.ld uses the same 0x40000000). See
 * kernel/platform/qemu/mmu_layout.tkb's header for why this specific
 * address matters beyond just "where RAM starts": the kernel-identity L1
 * block's index is derived from it. */
ENTRY(_start)

SECTIONS {
    . = 0x40000000;

    .text : {
        KEEP(*(.text.boot))
        . = ALIGN(2048);
        KEEP(*(.text.vectors))
        *(.text .text.*)
    }

    .rodata : ALIGN(8) {
        *(.rodata .rodata.*)
    }

    .data : ALIGN(8) {
        *(.data .data.*)
    }

    .bss (NOLOAD) : ALIGN(16) {
        __bss_start = .;
        *(.bss .bss.*) *(COMMON)
        . = ALIGN(16);
        __bss_end = .;
    }

    /* Every kernel stack in this image has the same shape as the ones
       kernel/kernel/process.tkb allocates per process: 0x4000 of usable
       stack occupying the UPPER half of a 0x8000-aligned 0x8000 region,
       with the lower half reserved and poisoned.

       The alignment is not decoration. It makes one bit of SP -- bit 14 --
       say which half an address is in, for EVERY kernel stack with no
       per-stack base to compare against, which is Linux arm64's kernel
       stack overflow test.  A boot stack of some other size or alignment
       would answer that test wrongly on every path that is not standing
       on a process stack, which is most of them.

       0x10000 was the boot stack's size before it was ever measured.  It
       measures 4432 bytes deep across the whole bounded suite, so 0x4000
       is chosen the same way the process stacks' size was: generously
       above a real measurement, not from what happened to be there. */
    . = ALIGN(0x8000);
    .stack (NOLOAD) : ALIGN(0x8000) {
        boot_stack_run_bottom = .;
        . += 0x4000;
        boot_stack_bottom = .;
        . += 0x4000;
        boot_stack_top = .;
        stack_top = boot_stack_top;
        /* 0x8000-aligned again by construction, the run above being
           exactly 0x8000 long. */
        secondary_stack_run_bottom = .;
        . += 0x4000;
        secondary_stack_bottom = .;
        . += 0x4000;
        secondary_stack_top = .;
        /* Where the exception-entry stack-overflow check lands.  A report
           about a stack cannot be trusted if it is written using that
           stack, which is why this exists at all.  Same shape as the
           others deliberately: if a second exception ever reached the
           entry check while running here, it would pass rather than loop
           on the check that brought it. */
        overflow_stack_run_bottom = .;
        . += 0x4000;
        overflow_stack_bottom = .;
        . += 0x4000;
        overflow_stack_top = .;
    }

    /* Same rationale as link.ld: the first PAGE_SIZE-aligned physical
       address past every statically-laid-out kernel region, where
       kernel/mm/page.tkb's page pool starts real physical page content. */
    . = ALIGN(4096);
    usable_ram_start = .;
}
