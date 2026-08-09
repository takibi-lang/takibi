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

    .stack (NOLOAD) : ALIGN(16) {
        . += 0x10000;
        boot_stack_top = .;
        stack_top = boot_stack_top;
        . += 0x4000;
        secondary_stack_top = .;
    }

    /* Same rationale as link.ld: the first PAGE_SIZE-aligned physical
       address past every statically-laid-out kernel region, where
       kernel/mm/page.tkb's page pool starts real physical page content. */
    . = ALIGN(4096);
    usable_ram_start = .;
}
