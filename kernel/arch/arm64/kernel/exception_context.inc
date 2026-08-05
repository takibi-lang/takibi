/* The one exception-frame shape. Every EL1 exception entry that returns to
 * the interrupted context uses this layout: EL0 sync (syscalls), Lower-EL
 * IRQ, and Current-EL-SPx IRQ. A saved SP_EL1 points at offset zero, and the
 * frame contains every architectural value the scheduler must preserve before
 * selecting a different context -- x0-x30, SP_EL0, ELR_EL1, SPSR_EL1, and the
 * FP/SIMD state q0-q31 + FPSR + FPCR.
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
    .equ EXC_CONTEXT_SIZE,          0x320
    .equ EXC_CONTEXT_X0,            0x000
    .equ EXC_CONTEXT_X30,           0x0f0
    .equ EXC_CONTEXT_SP_EL0,        0x0f8
    .equ EXC_CONTEXT_ELR_EL1,       0x100
    .equ EXC_CONTEXT_SPSR_EL1,      0x108
    .equ EXC_CONTEXT_Q0,            0x110
    .equ EXC_CONTEXT_FPSR,          0x310
    .equ EXC_CONTEXT_FPCR,          0x318

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
.endm

.macro EXC_CONTEXT_RESTORE
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
