ENTRY(_start)

/* 0x80000: the conventional physical load address Raspberry Pi firmware
   uses for a raw (non-Image-header) 64-bit kernel unless config.txt's
   kernel_address overrides it -- same address examples/common_rpi3/
   jtag_stub.ld uses for the same reason on RPi3. UNCONFIRMED for RPi5 as
   of this writing (see examples/common_rpi5/AGENTS.md); if the stub never
   gets control, this is the first thing to check. Converted to a raw
   binary (not left as an ELF) before being copied onto the SD card as
   kernel_2712.img, since that is the format the firmware's loader expects. */
SECTIONS {
    . = 0x80000;

    .text : {
        KEEP(*(.text.boot))
        *(.text .text.*)
    }
}
