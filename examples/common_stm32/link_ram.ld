ENTRY(Reset_Handler)

/* RAM-execution variant of link.ld, for the hardware test harness
   (make hwcheck) only -- see startup_ram.S's header comment for the full
   rationale (flash-endurance: every make hwcheck run used to erase/write
   the same physical flash Sector0 once per example, since every STM32
   example binary is well under Sector0's 32KB). Nothing here is ever
   copied into Flash: the whole image -- vector table, code, rodata,
   data, bss, stack -- targets AXI SRAM1 (0x20010000, 240K on the
   F746NG), loaded directly by the debug probe.

   Unlike link.ld/link_eth.ld, .data has no `AT> FLASH` clause: its load
   address and run address are the same RAM address (LMA == VMA), because
   there is no separate Flash copy for it to be loaded from -- the debug
   probe writes the correct final bytes directly. This also makes
   startup_ram.S's copy-out-of-flash loop unnecessary (see that file).

   Ordinary product/demo builds (stm32build, `make stm32-http-server`,
   manual `st-flash`, ...) are unaffected: they keep linking against
   link.ld/link_eth.ld. A shipped device still needs its firmware in
   non-volatile storage regardless of what this test-only path does. */
MEMORY {
    RAM (rwx) : ORIGIN = 0x20010000, LENGTH = 240K
}

SECTIONS {
    .isr_vector : {
        KEEP(*(.isr_vector))
    } > RAM

    .text : {
        *(.text .text.*)
    } > RAM

    .rodata : ALIGN(4) {
        *(.rodata .rodata.*)
    } > RAM

    .data : ALIGN(4) {
        _sdata = .;
        *(.data .data.*)
        . = ALIGN(4);
        _edata = .;
    } > RAM

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
