ENTRY(_start)

/* 0x80000: the conventional physical load address Raspberry Pi firmware
   uses for a 64-bit kernel unless config.txt's
   kernel_address overrides it -- same address examples/common_rpi3/
   jtag_stub.ld uses for the same reason on RPi3. UNCONFIRMED for RPi5 as
   of this writing (see examples/common_rpi5/AGENTS.md); if the stub never
   gets control, this is the first thing to check. The raw binary now starts
   with the standard arm64 Image header even though it is not an ELF file. */
SECTIONS {
    . = 0x80000;

    .text : {
        KEEP(*(.text.boot))
        *(.text .text.*)
    }
}
