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
   writing -- see scripts/rpi5_jtag_reset.sh's header comment.

   Do NOT assume x0 carries a usable device-tree pointer at _start, even
   though it superficially looks like it might (GitHub issue #247):
   confirmed by real-hardware SWD read after a fresh PSCI reset back into
   this exact spin loop, x0 held a plausible-looking pointer (x1-x3 were
   all zero, matching the ARM64 Linux boot protocol's reserved-zero
   convention) but the memory it pointed to was entirely zero, not an FDT
   header. Likely cause: this stub is a raw 8-byte binary with none of
   the standard Linux ARM64 "Image" header magic firmware normally keys
   off to decide whether to stage and hand off a real DTB, and
   config.txt's own os_check=0 (this file's own header, above) explicitly
   skips that same image-format validation. See HISTORY.md's 2026-08-08
   issue #247 entry for the full investigation; kernel/platform/rpi5/
   mailbox.tkb's VideoCore mailbox query is what issue #247 uses instead. */
    .section .text.boot
    .global _start
_start:
    /* Every core just parks here -- no main() to guard a single core into,
       so no MPIDR_EL1 core-number check is needed (same as RPi3's stub). */
.Lspin:
    wfe
    b       .Lspin
