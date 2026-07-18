/* Minimal spin stub for Raspberry Pi 3B (BCM2837) JTAG bring-up.
   Built standalone (no takibi, no link against any HAL) and flashed as
   the SD card's kernel8.img -- see examples/common_rpi3/AGENTS.md.

   Purpose: give a JTAG debugger a clean, known, non-Linux halting point.
   The GPU firmware (start.elf/bootcode.bin) still runs first and brings
   up DRAM/clocks exactly as it would for a real OS, but instead of
   booting Raspbian, it jumps here and core 0 immediately parks in an
   infinite wfe loop with MMU/caches off and no OS state to corrupt.
   From there, `openocd -c halt` can safely catch core 0 and a real
   payload can be injected via `load_image` + PC/SP register pokes +
   `resume`, the same RAM-injection technique examples/common_stm32/
   startup_ram.S uses for STM32 (see that file's header comment) --
   except here a physical power cycle stands in for STM32's `reset halt`,
   since the 6-pin GPIO JTAG header this board exposes (GPIO22-27) has no
   wired system reset line, so OpenOCD's `reset` cannot itself restart
   the GPU firmware's boot sequence. */
    .section .text.boot
    .global _start
_start:
    /* Every core just parks here -- unlike examples/common_rpi3/startup.S
       (the real payload's startup code), there is no main() to guard a
       single core into, so no MPIDR_EL1 core-number check is needed. */
.Lspin:
    wfe
    b       .Lspin
