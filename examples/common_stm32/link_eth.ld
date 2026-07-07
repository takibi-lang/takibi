ENTRY(Reset_Handler)

/* Same as link.ld, except RAM is AXI SRAM (0x20010000, up to 240K on the
   F746NG) instead of DTCM (0x20000000, 64K). The STM32F7 Ethernet DMA
   master cannot reach DTCM at all -- it isn't on the bus matrix DTCM sits
   behind -- so any example using examples/common_stm32/eth.tkb (whose
   descriptor rings and frame buffers land in plain .bss/.data) must link
   against this script instead of the shared link.ld. Every non-Ethernet
   STM32 example keeps using link.ld unchanged. */
MEMORY {
    FLASH (rx)  : ORIGIN = 0x08000000, LENGTH = 1M
    RAM   (rwx) : ORIGIN = 0x20010000, LENGTH = 240K
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

    /* startup.S maps this window Normal/non-cacheable for Ethernet DMA.
       Fail at link time instead of silently placing DMA-visible globals in
       the cacheable remainder of AXI SRAM. */
    ASSERT(_stack_top <= 0x20020000,
           "Ethernet image exceeds the 64KB non-cacheable MPU window")
}
