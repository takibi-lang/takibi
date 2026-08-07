/* GitHub issue #228: the only two pieces of the EL0 syscall-ABI test
 * payload that stay in raw assembly. Both are called from user_payload.tkb
 * via ordinary AAPCS `extern fn` calls.
 *
 * scheduler_probe_run deliberately pins the exact physical registers
 * (x19-x23, q8) that the kernel's context-switch save/restore path is
 * responsible for -- the test's whole purpose is confirming that path,
 * which only means something if the registers under test are real,
 * specific physical registers rather than whatever an ordinary compiled
 * loop happens to allocate. It is written to be a normal AAPCS callee: it
 * saves/restores every register it uses that AAPCS calls callee-saved
 * (x19-x23, x30, q8) before returning, so its caller sees no side effects
 * beyond the busy-wait's cost and the x0 return value.
 */
    .section .text, "ax"

    .global busy_spin
    .type busy_spin, %function
/* x0 = iteration count. Clobbers only x0 (caller-saved). A tight
 * subs/b.ne loop, matching the original inline fixture's timing exactly --
 * this project's scheduler-preemption tests are calibrated against real
 * wall-clock timing on RPi5 hardware, so this loop body must stay exactly
 * two instructions, the same as before this file existed. */
busy_spin:
.Lbusy_spin_loop:
    subs    x0, x0, #1
    b.ne    .Lbusy_spin_loop
    ret

    .global scheduler_probe_run
    .type scheduler_probe_run, %function
/* x0 = asid_va, x1 = asid_marker (low byte), x2 = simd_pattern (low byte),
 * x3 = busy_count. Returns x0 = 1 on success, 0 on failure. */
scheduler_probe_run:
    sub     sp, sp, #64
    stp     x19, x20, [sp, #0]
    stp     x21, x22, [sp, #16]
    stp     x23, x30, [sp, #32]
    str     q8,       [sp, #48]

    strb    w1, [x0]
    movz    x19, #0xdef0
    movk    x19, #0x9abc, lsl #16
    movk    x19, #0x5678, lsl #32
    movk    x19, #0x1234, lsl #48
    mov     x22, sp
    dup     v8.16b, w2
    mov     x21, x0
    mov     x0, x3
    bl      busy_spin
    mov     x0, x21

    mov     x9, #0
    movz    x20, #0xdef0
    movk    x20, #0x9abc, lsl #16
    movk    x20, #0x5678, lsl #32
    movk    x20, #0x1234, lsl #48
    cmp     x19, x20
    b.ne    .Lscheduler_probe_done
    mov     x23, sp
    cmp     x22, x23
    b.ne    .Lscheduler_probe_done
    umov    x10, v8.d[0]
    and     x11, x2, #0xff
    mov     x12, #0x0101010101010101
    mul     x11, x11, x12
    cmp     x10, x11
    b.ne    .Lscheduler_probe_done
    ldrb    w10, [x0]
    and     w13, w1, #0xff
    cmp     w10, w13
    b.ne    .Lscheduler_probe_done
    mov     x9, #1
.Lscheduler_probe_done:
    mov     x0, x9
    ldp     x19, x20, [sp, #0]
    ldp     x21, x22, [sp, #16]
    ldp     x23, x30, [sp, #32]
    ldr     q8,       [sp, #48]
    add     sp, sp, #64
    ret
