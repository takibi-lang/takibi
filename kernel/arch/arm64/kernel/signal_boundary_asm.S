/* EL0 signal fixture: pin physical FPSIMD registers and the interrupted SP.
 * The handler uses the Linux arm64 rt_sigframe ABI, not kernel frame offsets.
 * No shared state or writable globals; AAPCS callee state is saved on stack.
 */
.section .text, "ax"
.global signal_boundary_run
.type signal_boundary_run, %function
signal_boundary_run:
    sub sp, sp, #720
    stp x19, x20, [sp, #0]
    stp x21, x30, [sp, #16]
    str q8, [sp, #32]
    str q9, [sp, #48]
    str q10, [sp, #64]
    str q11, [sp, #80]
    str q12, [sp, #96]
    str q13, [sp, #112]
    str q14, [sp, #128]
    str q15, [sp, #144]
    mrs x9, fpcr
    str x9, [sp, #704]
    mrs x9, fpsr
    str x9, [sp, #712]
    mov x19, x0
    mov x20, sp
    mov x21, #0
    mov x9, #512
    str x9, [sp, #160]
    str xzr, [sp, #168]
    mov x0, #2
    add x1, sp, #160
    mov x2, #0
    mov x3, #8
    mov x8, #135
    svc #0
    cbnz x0, .Lboundary_bad
    mov x8, #172
    svc #0
    mov x1, #10
    mov x8, #129
    svc #0
    cbnz x0, .Lboundary_bad
    mov x9, #0x5a
    dup v0.16b, w9
    dup v1.16b, w9
    dup v2.16b, w9
    dup v3.16b, w9
    dup v4.16b, w9
    dup v5.16b, w9
    dup v6.16b, w9
    dup v7.16b, w9
    dup v8.16b, w9
    dup v9.16b, w9
    dup v10.16b, w9
    dup v11.16b, w9
    dup v12.16b, w9
    dup v13.16b, w9
    dup v14.16b, w9
    dup v15.16b, w9
    dup v16.16b, w9
    dup v17.16b, w9
    dup v18.16b, w9
    dup v19.16b, w9
    dup v20.16b, w9
    dup v21.16b, w9
    dup v22.16b, w9
    dup v23.16b, w9
    dup v24.16b, w9
    dup v25.16b, w9
    dup v26.16b, w9
    dup v27.16b, w9
    dup v28.16b, w9
    dup v29.16b, w9
    dup v30.16b, w9
    dup v31.16b, w9
    mov x9, #0x400000
    msr fpcr, x9
    mov x9, #1
    msr fpsr, x9
    add x0, sp, #168
    mov x1, #8
    cmp x19, #5
    b.ne .Lboundary_suspend
    mov x9, #0x1000
    mov sp, x9
.Lboundary_suspend:
    mov x8, #133
    svc #0
    mrs x13, nzcv
    // Successful delivery must have run our handler and restored its frame.
    cmp x21, #1
    b.ne .Lboundary_bad
    mov x9, sp
    cmp x9, x20
    b.ne .Lboundary_bad
    cmp x19, #4
    b.ne .Lboundary_fp_check
    mov x9, #0xf0000000
    cmp x13, x9
    b.ne .Lboundary_bad
.Lboundary_fp_check:
    mrs x9, fpcr
    mov x10, #0x400000
    cmp x9, x10
    b.ne .Lboundary_bad
    mrs x9, fpsr
    cmp x9, #1
    b.ne .Lboundary_bad
    str q0, [sp, #192]
    str q1, [sp, #208]
    str q2, [sp, #224]
    str q3, [sp, #240]
    str q4, [sp, #256]
    str q5, [sp, #272]
    str q6, [sp, #288]
    str q7, [sp, #304]
    str q8, [sp, #320]
    str q9, [sp, #336]
    str q10, [sp, #352]
    str q11, [sp, #368]
    str q12, [sp, #384]
    str q13, [sp, #400]
    str q14, [sp, #416]
    str q15, [sp, #432]
    str q16, [sp, #448]
    str q17, [sp, #464]
    str q18, [sp, #480]
    str q19, [sp, #496]
    str q20, [sp, #512]
    str q21, [sp, #528]
    str q22, [sp, #544]
    str q23, [sp, #560]
    str q24, [sp, #576]
    str q25, [sp, #592]
    str q26, [sp, #608]
    str q27, [sp, #624]
    str q28, [sp, #640]
    str q29, [sp, #656]
    str q30, [sp, #672]
    str q31, [sp, #688]
    add x9, sp, #192
    mov x10, #64
    mov x11, #0x5a5a
    movk x11, #0x5a5a, lsl #16
    movk x11, #0x5a5a, lsl #32
    movk x11, #0x5a5a, lsl #48
.Lboundary_vector_check:
    ldr x12, [x9], #8
    cmp x12, x11
    b.ne .Lboundary_bad
    subs x10, x10, #1
    b.ne .Lboundary_vector_check
    mov x0, #2
    mov x1, #0
    add x2, sp, #176
    mov x3, #8
    mov x8, #135
    svc #0
    cbnz x0, .Lboundary_bad
    ldr x9, [sp, #176]
    cmp x9, #512
    b.ne .Lboundary_bad
    mov x0, #0
    b .Lboundary_return
.Lboundary_bad:
    mov x0, #1
.Lboundary_return:
    mov sp, x20
    ldr x9, [sp, #704]
    msr fpcr, x9
    ldr x9, [sp, #712]
    msr fpsr, x9
    ldr q8, [sp, #32]
    ldr q9, [sp, #48]
    ldr q10, [sp, #64]
    ldr q11, [sp, #80]
    ldr q12, [sp, #96]
    ldr q13, [sp, #112]
    ldr q14, [sp, #128]
    ldr q15, [sp, #144]
    ldp x19, x20, [sp, #0]
    ldp x21, x30, [sp, #16]
    add sp, sp, #720
    ret
.size signal_boundary_run, .-signal_boundary_run

.global signal_boundary_handler
.type signal_boundary_handler, %function
signal_boundary_handler:
    cmp x0, #10
    b.ne .Lboundary_handler_done
    ldr w9, [x1, #0]
    cmp w9, #10
    b.ne .Lboundary_handler_done
    ldr w9, [x1, #8]
    cbnz w9, .Lboundary_handler_done
    ldr x9, [x1, #168]
    cmp x9, #512
    b.ne .Lboundary_handler_done
    // Signal return restores x21 from mcontext, so store the verdict there.
    mov x9, #1
    str x9, [x1, #480]
    cmp x19, #1
    b.ne .Lboundary_size
    str wzr, [x1, #592]
.Lboundary_size:
    cmp x19, #2
    b.ne .Lboundary_pc
    str wzr, [x1, #596]
.Lboundary_pc:
    cmp x19, #3
    b.ne .Lboundary_pstate
    ldr x9, [x1, #568]
    add x9, x9, #1
    str x9, [x1, #568]
.Lboundary_pstate:
    cmp x19, #4
    b.ne .Lboundary_handler_done
    // Try EL1h and all DAIF masks. The kernel must retain only NZCV.
    mov x9, #0x3c5
    movk x9, #0xf000, lsl #16
    str x9, [x1, #576]
.Lboundary_handler_done:
    movi v0.16b, #0
    movi v1.16b, #0
    movi v2.16b, #0
    movi v3.16b, #0
    movi v4.16b, #0
    movi v5.16b, #0
    movi v6.16b, #0
    movi v7.16b, #0
    movi v8.16b, #0
    movi v9.16b, #0
    movi v10.16b, #0
    movi v11.16b, #0
    movi v12.16b, #0
    movi v13.16b, #0
    movi v14.16b, #0
    movi v15.16b, #0
    movi v16.16b, #0
    movi v17.16b, #0
    movi v18.16b, #0
    movi v19.16b, #0
    movi v20.16b, #0
    movi v21.16b, #0
    movi v22.16b, #0
    movi v23.16b, #0
    movi v24.16b, #0
    movi v25.16b, #0
    movi v26.16b, #0
    movi v27.16b, #0
    movi v28.16b, #0
    movi v29.16b, #0
    movi v30.16b, #0
    movi v31.16b, #0
    msr fpcr, xzr
    msr fpsr, xzr
    ret
.size signal_boundary_handler, .-signal_boundary_handler
.global signal_boundary_restorer
.type signal_boundary_restorer, %function
signal_boundary_restorer:
    mov x8, #139
    svc #0
    // Returning from rt_sigreturn is a fixture failure, without a trap.
    mov x0, #1
    mov x8, #93
    svc #0
.Lboundary_restorer_failed:
    b .Lboundary_restorer_failed
.size signal_boundary_restorer, .-signal_boundary_restorer

/* GitHub issue #726: one syscall that a caught signal may interrupt.
 * signal_interrupt_svc(number, a0, a1, a2, a3, ran) makes the call with x21
 * zero and stores x21 to *ran afterwards. signal_interrupt_handler counts
 * itself in the interrupted context's x21, which rt_sigreturn restores, so
 * *ran says how many handlers ran before the call returned -- including
 * before a call that SA_RESTART reran.
 */
.global signal_interrupt_svc
.type signal_interrupt_svc, %function
signal_interrupt_svc:
    stp x21, x30, [sp, #-16]!
    stp x5, xzr, [sp, #-16]!
    mov x21, #0
    mov x8, x0
    mov x0, x1
    mov x1, x2
    mov x2, x3
    mov x3, x4
    svc #0
    ldp x5, x9, [sp], #16
    str x21, [x5]
    ldp x21, x30, [sp], #16
    ret
.size signal_interrupt_svc, .-signal_interrupt_svc

.global signal_interrupt_handler
.type signal_interrupt_handler, %function
signal_interrupt_handler:
    ldr x9, [x1, #480]
    add x9, x9, #1
    str x9, [x1, #480]
    ret
.size signal_interrupt_handler, .-signal_interrupt_handler

/* GitHub issue #628: a process that makes no syscall still runs its
 * handler, at the return from the timer interrupt that preempts it.
 * signal_spin_run() fills every general register it may -- all but x20 (the
 * SP copy), x21 (the handler count) and x22 (the bound) -- every vector
 * register, FPCR, FPSR and NZCV with known values, then spins without a
 * syscall until signal_spin_handler has run, or the bound runs out. The
 * handler counts itself in the interrupted x21 through the signal frame,
 * as signal_interrupt_handler does, and clobbers what it can; on return
 * every register must hold its value again. x0..x18 are what a syscall
 * return would not have had to keep.
 * Returns 0; 1 when the bound ran out (no handler ran); 2 when a register
 * came back changed; 3 when SP did.
 */
.macro spin_pattern reg, n
    movz \reg, #(0x1100 + \n)
    movk \reg, #(0x5a00 + \n), lsl #16
    movk \reg, #0xa5a5, lsl #48
.endm

.global signal_spin_run
.type signal_spin_run, %function
signal_spin_run:
    sub sp, sp, #192
    stp x19, x20, [sp, #0]
    stp x21, x22, [sp, #16]
    stp x23, x24, [sp, #32]
    stp x25, x26, [sp, #48]
    stp x27, x28, [sp, #64]
    stp x29, x30, [sp, #80]
    stp d8, d9, [sp, #96]
    stp d10, d11, [sp, #112]
    stp d12, d13, [sp, #128]
    stp d14, d15, [sp, #144]
    mrs x9, fpcr
    mrs x10, fpsr
    stp x9, x10, [sp, #160]
    mov x20, sp
    mov x21, #0
    mov x22, #1
    lsl x22, x22, #32
    .irp v, 0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31
    mov w9, #(0x31 + \v)
    dup v\v\().16b, w9
    .endr
    mov x9, #0x400000
    msr fpcr, x9
    mov x9, #1
    msr fpsr, x9
    mov x9, #0xa0000000
    msr nzcv, x9
    .irp n, 0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,23,24,25,26,27,28,29,30
    spin_pattern x\n, \n
    .endr
    // No syscall and no flag-setting instruction until the handler ran.
.Lspin_loop:
    cbnz x21, .Lspin_ran
    sub x22, x22, #1
    cbnz x22, .Lspin_loop
    mov x0, #1
    b .Lspin_return
.Lspin_ran:
    mrs x21, nzcv
    mov x22, #0xa0000000
    cmp x21, x22
    b.ne .Lspin_bad
    .irp n, 0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,23,24,25,26,27,28,29,30
    spin_pattern x22, \n
    cmp x\n, x22
    b.ne .Lspin_bad
    .endr
    // Each vector register against its byte; v0 is checked first, since
    // it then serves as the scratch for the rest.
    .irp v, 0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31
    mov w9, #(0x31 + \v)
    dup v0.16b, w9
    cmeq v0.16b, v0.16b, v\v\().16b
    uminv b0, v0.16b
    umov w9, v0.b[0]
    cmp w9, #0xff
    b.ne .Lspin_bad
    .endr
    mrs x21, fpcr
    mov x22, #0x400000
    cmp x21, x22
    b.ne .Lspin_bad
    mrs x21, fpsr
    cmp x21, #1
    b.ne .Lspin_bad
    mov x21, sp
    cmp x21, x20
    b.ne .Lspin_sp
    mov x0, #0
    b .Lspin_return
.Lspin_sp:
    mov x0, #3
    b .Lspin_return
.Lspin_bad:
    mov x0, #2
.Lspin_return:
    mov sp, x20
    ldp x9, x10, [sp, #160]
    msr fpcr, x9
    msr fpsr, x10
    ldp d8, d9, [sp, #96]
    ldp d10, d11, [sp, #112]
    ldp d12, d13, [sp, #128]
    ldp d14, d15, [sp, #144]
    ldp x19, x20, [sp, #0]
    ldp x21, x22, [sp, #16]
    ldp x23, x24, [sp, #32]
    ldp x25, x26, [sp, #48]
    ldp x27, x28, [sp, #64]
    ldp x29, x30, [sp, #80]
    add sp, sp, #192
    ret
.size signal_spin_run, .-signal_spin_run

.global signal_spin_handler
.type signal_spin_handler, %function
signal_spin_handler:
    ldr x9, [x1, #480]
    add x9, x9, #1
    str x9, [x1, #480]
    // Clobber what the interrupted context must get back.
    .irp n, 3,4,5,6,7,8,10,11,12,13,14,15,16,17,18
    mov x\n, #0
    .endr
    .irp v, 0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31
    movi v\v\().16b, #0
    .endr
    mov x9, #0
    cmp x9, #1
    msr fpcr, xzr
    msr fpsr, xzr
    ret
.size signal_spin_handler, .-signal_spin_handler
