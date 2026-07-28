/* SPDX-License-Identifier: MIT
 * Thin RPi5 boot shim for issue #177. TF-A hands off at EL2; this file does
 * the system-register work Takibi cannot express and drops exactly once to
 * the monolithic EL1 kernel. It is not an EL2 service layer.
 */
    .section .text.boot, "ax"
    .global _start
    .type _start, %function
_start:
    mrs     x0, mpidr_el1
    lsr     x0, x0, #8
    and     x0, x0, #3
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
    /* EL1 may use the physical counter/timer without trapping to EL2. */
    mrs     x0, cnthctl_el2
    orr     x0, x0, #3
    msr     cnthctl_el2, x0

    /* EL1 and EL0 execute AArch64; retain all unrelated inherited bits. */
    mrs     x0, hcr_el2
    orr     x0, x0, #(1 << 31)
    msr     hcr_el2, x0

    adrp    x0, el1_vectors
    add     x0, x0, :lo12:el1_vectors
    msr     vbar_el1, x0

    adrp    x0, boot_stack_top
    add     x0, x0, :lo12:boot_stack_top
    msr     sp_el1, x0

    mov     x0, #0x3c5         /* EL1h, DAIF masked */
    msr     spsr_el2, x0
    adr     x0, .Lel1_entry
    msr     elr_el2, x0
    isb
    eret

.Lel1_entry:
    /* Permit ordinary compiled code to use FP/SIMD if LLVM selects it. */
    mrs     x0, cpacr_el1
    orr     x0, x0, #(3 << 20)
    msr     cpacr_el1, x0
    isb
    bl      kernel_mmu_init
    bl      main

.Lpark:
    wfe
    b       .Lpark

/* All sixteen architectural vector slots lead to an evidence-preserving
 * fail-stop path. x16 identifies the slot. No slot silently spins at an
 * anonymous PC. Lower-EL synchronous dispatch becomes a separate entry when
 * the first EL0 process is added.
 */
    .section .text.vectors, "ax"
    .align 11
el1_vectors:
.macro VECTOR slot
    mov     x16, #\slot
    b       el1_exception_evidence
    .align  7
.endm
    VECTOR 0
    VECTOR 1
    VECTOR 2
    VECTOR 3
    VECTOR 4
    VECTOR 5
    VECTOR 6
    VECTOR 7
    VECTOR 8
    VECTOR 9
    VECTOR 10
    VECTOR 11
    VECTOR 12
    VECTOR 13
    VECTOR 14
    VECTOR 15

    .section .text, "ax"
el1_exception_evidence:
    adrp    x17, exception_vector_slot
    add     x17, x17, :lo12:exception_vector_slot
    str     x16, [x17]
    mrs     x16, esr_el1
    str     x16, [x17, #8]
    mrs     x16, far_el1
    str     x16, [x17, #16]
    mrs     x16, elr_el1
    str     x16, [x17, #24]
    mrs     x16, spsr_el1
    str     x16, [x17, #32]
.Levidence_park:
    wfe
    b       .Levidence_park

    .section .bss, "aw", %nobits
    .align 3
    .global exception_vector_slot
exception_vector_slot:
    .zero 40
