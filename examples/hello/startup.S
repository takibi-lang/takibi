    .section .text.boot
    .global _start
_start:
    /* Set up stack pointer */
    adrp    x0, stack_top
    add     x0, x0, :lo12:stack_top
    mov     sp, x0

    /* Zero-initialise BSS */
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

    /* AArch64 semihosting: SYS_EXIT (0x18)
       On AArch64 the extended format is always used:
       x1 must point to a two-word parameter block:
         [0] ADP_Stopped_ApplicationExit (0x20026)
         [1] exit code (0 = success)                */
    mov     x0, #0x18
    adrp    x1, exit_params
    add     x1, x1, :lo12:exit_params
    hlt     #0xf000

    /* Should not reach here */
.Lhalt:
    wfe
    b       .Lhalt

    .section .rodata
    .align  3
exit_params:
    .quad   0x20026    /* ADP_Stopped_ApplicationExit */
    .quad   0          /* exit code: 0               */
