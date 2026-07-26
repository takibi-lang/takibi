ENTRY(_start)
SECTIONS {
    . = 0x00090000;
    .text : { KEEP(*(.text.boot)) *(.text .text.*) }
}
