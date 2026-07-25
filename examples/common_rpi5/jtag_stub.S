/* Minimal spin stub for Raspberry Pi 5 (BCM2712) JTAG bring-up. Built
   standalone (no takibi, no link against any HAL) and flashed as the SD
   card's kernel_2712.img -- see examples/common_rpi5/AGENTS.md.

   Same purpose as examples/common_rpi3/jtag_stub.S: give a debugger a
   clean, known, non-Linux halting point. RPi5's boot chain (EEPROM
   bootloader -> TF-A BL31, which hands 64-bit payloads off at EL2 per
   Trusted Firmware-A's own rpi5 platform docs) runs first exactly as it
   would for a real OS, but instead of booting Linux, config.txt's
   kernel=/os_check=0 settings point it at this stub, which immediately
   parks core 0 in an infinite wfe loop with MMU/caches off and no OS state
   to corrupt. From there OpenOCD can halt core 0 and inject a real payload
   via `load_image` + PC/SP register pokes + `resume`, same technique as
   RPi3. Whether OpenOCD's `reset halt` can restart the whole boot chain
   here (the official Debug Probe's dedicated connector may carry a real
   SRST line, unlike RPi3's 6-pin GPIO header) is UNCONFIRMED as of this
   writing -- see scripts/rpi5_jtag_reset.sh's header comment. */
    .section .text.boot
    .global _start
_start:
    /* Every core just parks here -- no main() to guard a single core into,
       so no MPIDR_EL1 core-number check is needed (same as RPi3's stub). */
.Lspin:
    wfe
    b       .Lspin
