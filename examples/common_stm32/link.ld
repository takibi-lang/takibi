ENTRY(Reset_Handler)

/* STM32F746: 1MB flash at 0x08000000. RAM region here is DTCM (64K at
   0x20000000) rather than SRAM1/AXI-SRAM -- DTCM needs no cache
   configuration to behave correctly, the simplest choice for this first
   bring-up. Revisit if a later example needs more than 64K of RAM. */
MEMORY {
    FLASH (rx)  : ORIGIN = 0x08000000, LENGTH = 1M
    RAM   (rwx) : ORIGIN = 0x20000000, LENGTH = 64K
}

SECTIONS {
    .isr_vector : {
        KEEP(*(.isr_vector))
    } > FLASH

    .text : {
        *(.text .text.*)
    } > FLASH

    .rodata : ALIGN(4) {
        *(.rodata .rodata.*)
    } > FLASH

    _sidata = LOADADDR(.data);

    .data : ALIGN(4) {
        _sdata = .;
        *(.data .data.*)
        . = ALIGN(4);
        _edata = .;
    } > RAM AT> FLASH

    .bss (NOLOAD) : ALIGN(4) {
        __bss_start = .;
        *(.bss .bss.*) *(COMMON)
        . = ALIGN(4);
        __bss_end = .;
    } > RAM

    .stack (NOLOAD) : ALIGN(8) {
        . += 0x2000;
        _stack_top = .;
    } > RAM
}
