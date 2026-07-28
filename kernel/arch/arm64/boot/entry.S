/* SPDX-License-Identifier: MIT
 * Temporary standalone-tree bootstrap for issue #177. This first build
 * boundary selects core zero, installs a known stack, clears BSS, and calls
 * Takibi code at the TF-A-provided EL2. The next executable boundary replaces
 * the final call with the one-way EL2-to-EL1 transition.
 */
    .section .text.boot, "ax"
    .global _start
    .type _start, %function
_start:
    mrs     x0, mpidr_el1
    and     x0, x0, #0xff
    cbnz    x0, .Lpark

    adrp    x0, boot_stack_top
    add     x0, x0, :lo12:boot_stack_top
    mov     sp, x0

    adrp    x0, __bss_start
    add     x0, x0, :lo12:__bss_start
    adrp    x1, __bss_end
    add     x1, x1, :lo12:__bss_end
.Lbss_loop:
    cmp     x0, x1
    b.hs    .Lbss_done
    str     xzr, [x0], #8
    b       .Lbss_loop
.Lbss_done:
    bl      main

.Lpark:
    wfe
    b       .Lpark
