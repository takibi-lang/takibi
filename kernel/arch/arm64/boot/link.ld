ENTRY(_start)

SECTIONS {
    . = 0x200000;

    .text : {
        KEEP(*(.text.boot))
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
    }
}
