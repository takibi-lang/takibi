ENTRY(_start)

/* 0x80000: the fixed physical address the GPU firmware loads and jumps to
   for a 64-bit kernel8.img on this board -- see jtag_stub.S's header
   comment. Converted to a raw binary (not left as an ELF) before being
   copied onto the SD card as kernel8.img, since that is the format the
   firmware's loader expects. */
SECTIONS {
    . = 0x80000;

    .text : {
        KEEP(*(.text.boot))
        *(.text .text.*)
    }
}
