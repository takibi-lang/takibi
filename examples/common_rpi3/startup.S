/* Raspberry Pi 3B (BCM2837) bare-metal startup. Never runs via the SD
   card's normal boot path -- see examples/common_rpi3/AGENTS.md and
   jtag_stub.S's header comment: the GPU firmware boots jtag_stub.S's
   spin loop instead, and this file's linked image is injected into RAM
   over JTAG (OpenOCD `load_image` + PC/SP register pokes + `resume`)
   after that stub is halted. Deliberately no exception vector table and
   no IRQ plumbing yet (unlike examples/common_qemu/startup.S) -- nothing
   in examples/common_rpi3/ uses interrupts yet; add it when a real
   example here needs it, not speculatively. */
    .section .text.boot
    .global _start
_start:
    /* Only core 0 runs main() -- cores 1-3 must not also call it
       concurrently (duplicate UART output, racing on shared HAL state).
       MPIDR_EL1[1:0] is this SoC's core number. */
    mrs     x0, mpidr_el1
    and     x0, x0, #3
    cbz     x0, .Lcore0
.Lpark:
    wfe
    b       .Lpark

.Lcore0:
    adrp    x0, stack_top
    add     x0, x0, :lo12:stack_top
    mov     sp, x0

    /* Zero-initialise BSS (identical technique to examples/common_qemu/
       startup.S). */
    adrp    x0, __bss_start
    add     x0, x0, :lo12:__bss_start
    adrp    x1, __bss_end
    add     x1, x1, :lo12:__bss_end
    cmp     x0, x1
    b.ge    .Lbss_done
.Lbss_loop:
    str     xzr, [x0], #8
    cmp     x0, x1
    b.lt    .Lbss_loop
.Lbss_done:

    bl      main

    /* Real hardware, no semihosting exit available (unlike QEMU) and
       nothing to return to (unlike a flashed STM32 image, there is no
       enclosing firmware here either, since JTAG replaced the running
       core context directly) -- just park. */
.Lhalt:
    wfe
    b       .Lhalt
