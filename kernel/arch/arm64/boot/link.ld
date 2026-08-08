ENTRY(_start)

SECTIONS {
    . = 0x200000;

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

    /* GitHub issue #251: the first PAGE_SIZE-aligned physical address past
       every other statically-laid-out kernel region (.text/.rodata/.data/
       .bss/.stack) -- kernel/mm/page.tkb's page pool starts real physical
       page CONTENT here instead of inside a kernel-owned shadow array, so
       this must stay strictly after everything above it, page-aligned (an
       unaligned start would break every PAGE_SIZE-stride computation
       page.tkb does off of it). */
    . = ALIGN(4096);
    usable_ram_start = .;
}
