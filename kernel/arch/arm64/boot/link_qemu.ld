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
    kernel_image_start = .;

    kernel_text_start = .;
    .text : {
        KEEP(*(.text.boot))
        . = ALIGN(2048);
        KEEP(*(.text.vectors))
        kernel_generated_text_start = .;
        *(.text.takibi .text.takibi.*)
        kernel_generated_text_end = .;
        *(.text .text.*)
    }
    kernel_text_end = .;

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
        /* GitHub issue #477: the two stacks below are PER CORE, laid out as
           KERNEL_CORES contiguous groups of identical shape.  A core's own
           pair is its group index times one stride from these symbols, and
           the index times the stride is what each core's entry path puts in
           TPIDR_EL1 -- so the generated exception entry adds one register
           to the address it already computes, and needs to know nothing
           about which core it is running on.

           The paragraph this replaces said "ONE stack, not one per core"
           and named the exact condition under which that stops holding:
           core 1 parking and never taking an interrupt.  GitHub issue #447
           changed that condition, and the first timer tick on core 1
           landed on core 0's saved frame -- its INTID, 30, arrived as core
           0's ELR.  The reopen condition was written down and it fired.

           Each group keeps the shape kernel/arch/arm64/kernel/
           exception_frame.tkb's stack_guard_shift depends on: every run is
           0x8000-aligned with the live half on top, so bit 14 of any
           address inside a stack is 1.  A 0x10000 stride preserves that
           for every group, which is why the stride is the group size and
           not something rounder. */
        percpu_stack_base = .;
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
        /* Where an IRQ handler runs.  The frame stays on whichever stack
           was interrupted -- it is the interrupted context, and a
           preempted process's context cannot live on a stack the next
           interrupt reuses -- but everything the handler itself does
           happens here, so one kernel stack no longer has to hold the
           deepest syscall path and the deepest interrupt path at once.
           Same arrangement as Linux's per-CPU IRQ stack, now including
           the per-CPU part. */
        irq_stack_run_bottom = .;
        . += 0x4000;
        irq_stack_bottom = .;
        . += 0x4000;
        irq_stack_top = .;
        percpu_stack_group_end = .;
        /* One more group, for the one secondary this kernel starts
           (kernel/arch/arm64/kernel/secondary.tkb's SECONDARY_CORE_ID).
           Adding a core is adding a line here and raising KERNEL_CORES. */
        secondary_percpu_stack_base = .;
        . += (percpu_stack_group_end - percpu_stack_base);
        percpu_stack_end = .;
    }

    /* Same rationale as link.ld: the first PAGE_SIZE-aligned physical
       address past every statically-laid-out kernel region, where
       kernel/mm/page.tkb's page pool starts real physical page content. */
    . = ALIGN(4096);
    usable_ram_start = .;
}
