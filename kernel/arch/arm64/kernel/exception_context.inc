/* The one exception-frame shape. Every EL1 exception entry that returns to
 * the interrupted context uses this layout: EL0 sync (syscalls), Lower-EL
 * IRQ, and Current-EL-SPx IRQ. A saved SP_EL1 points at offset zero, and the
 * frame contains every architectural value the scheduler must preserve before
 * selecting a different context -- x0-x30, SP_EL0, ELR_EL1, SPSR_EL1,
 * TPIDR_EL0, and the FP/SIMD state q0-q31 + FPSR + FPCR.
 *
 * The FP/SIMD half is not optional for any entry, including the Current-EL
 * one: kernel/arch/arm64/boot/entry.S enables FP/SIMD in CPACR_EL1 for
 * ordinary compiled code, LLVM does select q registers in kernel .tkb code,
 * and since issue #187 syscall handling runs with IRQs unmasked -- so EL1
 * kernel code holding live q registers can be interrupted. GitHub issue #223
 * removed the separate 272-byte general-registers-only Current-EL frame that
 * used to exist alongside this one; a second layout is exactly what let that
 * asymmetry go unnoticed, so there is deliberately only one now.
 */
    .equ EXC_CONTEXT_SIZE,          0x330
    .equ EXC_CONTEXT_X0,          0x000
    .equ EXC_CONTEXT_X1,          0x008
    .equ EXC_CONTEXT_X2,          0x010
    .equ EXC_CONTEXT_X3,          0x018
    .equ EXC_CONTEXT_X4,          0x020
    .equ EXC_CONTEXT_X5,          0x028
    .equ EXC_CONTEXT_X6,          0x030
    .equ EXC_CONTEXT_X7,          0x038
    .equ EXC_CONTEXT_X8,          0x040
    .equ EXC_CONTEXT_X9,          0x048
    .equ EXC_CONTEXT_X10,          0x050
    .equ EXC_CONTEXT_X11,          0x058
    .equ EXC_CONTEXT_X12,          0x060
    .equ EXC_CONTEXT_X13,          0x068
    .equ EXC_CONTEXT_X14,          0x070
    .equ EXC_CONTEXT_X15,          0x078
    .equ EXC_CONTEXT_X16,          0x080
    .equ EXC_CONTEXT_X17,          0x088
    .equ EXC_CONTEXT_X18,          0x090
    .equ EXC_CONTEXT_X19,          0x098
    .equ EXC_CONTEXT_X20,          0x0a0
    .equ EXC_CONTEXT_X21,          0x0a8
    .equ EXC_CONTEXT_X22,          0x0b0
    .equ EXC_CONTEXT_X23,          0x0b8
    .equ EXC_CONTEXT_X24,          0x0c0
    .equ EXC_CONTEXT_X25,          0x0c8
    .equ EXC_CONTEXT_X26,          0x0d0
    .equ EXC_CONTEXT_X27,          0x0d8
    .equ EXC_CONTEXT_X28,          0x0e0
    .equ EXC_CONTEXT_X29,          0x0e8
    .equ EXC_CONTEXT_X30,          0x0f0
    .equ EXC_CONTEXT_SP_EL0,          0x0f8
    .equ EXC_CONTEXT_ELR_EL1,          0x100
    .equ EXC_CONTEXT_SPSR_EL1,          0x108
    .equ EXC_CONTEXT_Q0,          0x110
    .equ EXC_CONTEXT_Q1,          0x120
    .equ EXC_CONTEXT_Q2,          0x130
    .equ EXC_CONTEXT_Q3,          0x140
    .equ EXC_CONTEXT_Q4,          0x150
    .equ EXC_CONTEXT_Q5,          0x160
    .equ EXC_CONTEXT_Q6,          0x170
    .equ EXC_CONTEXT_Q7,          0x180
    .equ EXC_CONTEXT_Q8,          0x190
    .equ EXC_CONTEXT_Q9,          0x1a0
    .equ EXC_CONTEXT_Q10,          0x1b0
    .equ EXC_CONTEXT_Q11,          0x1c0
    .equ EXC_CONTEXT_Q12,          0x1d0
    .equ EXC_CONTEXT_Q13,          0x1e0
    .equ EXC_CONTEXT_Q14,          0x1f0
    .equ EXC_CONTEXT_Q15,          0x200
    .equ EXC_CONTEXT_Q16,          0x210
    .equ EXC_CONTEXT_Q17,          0x220
    .equ EXC_CONTEXT_Q18,          0x230
    .equ EXC_CONTEXT_Q19,          0x240
    .equ EXC_CONTEXT_Q20,          0x250
    .equ EXC_CONTEXT_Q21,          0x260
    .equ EXC_CONTEXT_Q22,          0x270
    .equ EXC_CONTEXT_Q23,          0x280
    .equ EXC_CONTEXT_Q24,          0x290
    .equ EXC_CONTEXT_Q25,          0x2a0
    .equ EXC_CONTEXT_Q26,          0x2b0
    .equ EXC_CONTEXT_Q27,          0x2c0
    .equ EXC_CONTEXT_Q28,          0x2d0
    .equ EXC_CONTEXT_Q29,          0x2e0
    .equ EXC_CONTEXT_Q30,          0x2f0
    .equ EXC_CONTEXT_Q31,          0x300
    .equ EXC_CONTEXT_FPSR,          0x310
    .equ EXC_CONTEXT_FPCR,          0x318
    .equ EXC_CONTEXT_TPIDR_EL0,          0x320

.macro EXC_CONTEXT_RESTORE
    msr     DAIFSet, #0x2
    ldp     x9, x10, [sp, #EXC_CONTEXT_ELR_EL1]
    msr     elr_el1, x9
    msr     spsr_el1, x10
    ldr     x9, [sp, #EXC_CONTEXT_SP_EL0]
    msr     sp_el0, x9
    ldp     q0, q1, [sp, #0x110]
    ldp     q2, q3, [sp, #0x130]
    ldp     q4, q5, [sp, #0x150]
    ldp     q6, q7, [sp, #0x170]
    ldp     q8, q9, [sp, #0x190]
    ldp     q10, q11, [sp, #0x1b0]
    ldp     q12, q13, [sp, #0x1d0]
    ldp     q14, q15, [sp, #0x1f0]
    ldp     q16, q17, [sp, #0x210]
    ldp     q18, q19, [sp, #0x230]
    ldp     q20, q21, [sp, #0x250]
    ldp     q22, q23, [sp, #0x270]
    ldp     q24, q25, [sp, #0x290]
    ldp     q26, q27, [sp, #0x2b0]
    ldp     q28, q29, [sp, #0x2d0]
    ldp     q30, q31, [sp, #0x2f0]
    ldr     x9, [sp, #EXC_CONTEXT_FPSR]
    ldr     x10, [sp, #EXC_CONTEXT_FPCR]
    msr     fpsr, x9
    msr     fpcr, x10
    ldr     x9, [sp, #EXC_CONTEXT_TPIDR_EL0]
    msr     tpidr_el0, x9
    ldp     x0, x1, [sp, #0x000]
    ldp     x2, x3, [sp, #0x010]
    ldp     x4, x5, [sp, #0x020]
    ldp     x6, x7, [sp, #0x030]
    ldp     x8, x9, [sp, #0x040]
    ldp     x10, x11, [sp, #0x050]
    ldp     x12, x13, [sp, #0x060]
    ldp     x14, x15, [sp, #0x070]
    ldp     x16, x17, [sp, #0x080]
    ldp     x18, x19, [sp, #0x090]
    ldp     x20, x21, [sp, #0x0a0]
    ldp     x22, x23, [sp, #0x0b0]
    ldp     x24, x25, [sp, #0x0c0]
    ldp     x26, x27, [sp, #0x0d0]
    ldp     x28, x29, [sp, #0x0e0]
    ldp     x30, xzr, [sp, #EXC_CONTEXT_X30]
.endm

.macro EXC_CONTEXT_SAVE
    stp     x0, x1, [sp, #0x000]
    stp     x2, x3, [sp, #0x010]
    stp     x4, x5, [sp, #0x020]
    stp     x6, x7, [sp, #0x030]
    stp     x8, x9, [sp, #0x040]
    stp     x10, x11, [sp, #0x050]
    stp     x12, x13, [sp, #0x060]
    stp     x14, x15, [sp, #0x070]
    stp     x16, x17, [sp, #0x080]
    stp     x18, x19, [sp, #0x090]
    stp     x20, x21, [sp, #0x0a0]
    stp     x22, x23, [sp, #0x0b0]
    stp     x24, x25, [sp, #0x0c0]
    stp     x26, x27, [sp, #0x0d0]
    stp     x28, x29, [sp, #0x0e0]
    mrs     x9, sp_el0
    stp     x30, x9, [sp, #EXC_CONTEXT_X30]
    mrs     x9, elr_el1
    mrs     x10, spsr_el1
    stp     x9, x10, [sp, #EXC_CONTEXT_ELR_EL1]
    stp     q0, q1, [sp, #0x110]
    stp     q2, q3, [sp, #0x130]
    stp     q4, q5, [sp, #0x150]
    stp     q6, q7, [sp, #0x170]
    stp     q8, q9, [sp, #0x190]
    stp     q10, q11, [sp, #0x1b0]
    stp     q12, q13, [sp, #0x1d0]
    stp     q14, q15, [sp, #0x1f0]
    stp     q16, q17, [sp, #0x210]
    stp     q18, q19, [sp, #0x230]
    stp     q20, q21, [sp, #0x250]
    stp     q22, q23, [sp, #0x270]
    stp     q24, q25, [sp, #0x290]
    stp     q26, q27, [sp, #0x2b0]
    stp     q28, q29, [sp, #0x2d0]
    stp     q30, q31, [sp, #0x2f0]
    mrs     x9, fpsr
    mrs     x10, fpcr
    str     x9, [sp, #EXC_CONTEXT_FPSR]
    str     x10, [sp, #EXC_CONTEXT_FPCR]
    mrs     x9, tpidr_el0
    str     x9, [sp, #EXC_CONTEXT_TPIDR_EL0]
.endm
