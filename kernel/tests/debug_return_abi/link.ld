/* GitHub issue #713: QEMU virt RAM starts at 0x40000000. */
ENTRY(_start)
SECTIONS
{
    . = 0x40080000;
    .text : { *(.text.boot) *(.text*) }
    .rodata : { *(.rodata*) }
    .data : { *(.data*) }
    .bss : { *(.bss*) *(COMMON) }
}
