ENTRY(_start)

/* 0x200000: deliberately different from jtag_stub.ld's 0x80000 load
   address, so a JTAG session's `load_image` target is never the same
   address the stub itself occupied -- keeps "did this overwrite the
   stub or land somewhere fresh" unambiguous while debugging by hand. */
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

    .bss (NOLOAD) : ALIGN(8) {
        __bss_start = .;
        *(.bss .bss.*) *(COMMON)
        . = ALIGN(8);
        __bss_end = .;
    }

    .stack (NOLOAD) : ALIGN(16) {
        . += 0x4000;
        smp_core1_stack_top = .;
        . += 0x4000;
        smp_core2_stack_top = .;
        . += 0x4000;
        smp_core3_stack_top = .;
        . += 0x10000;
        stack_top = .;
    }
}
