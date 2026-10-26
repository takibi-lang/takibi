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

/* GitHub issue #892: an SA_SIGINFO SIGCHLD handler and its SA_RESTORER
 * trampoline, so the payload can read the siginfo the kernel's own signal
 * frame carries (exit notify -> ProcessRecord.sigchld_* -> TakenSignal ->
 * syscall_signal_frame_write). This payload has no writable globals
 * (buildcheck_user_payload_no_rw_globals.py), so the handler finds its
 * record through TPIDR_EL0, which the kernel saves per process and nothing
 * else in this payload uses. The record is 40 bytes of the caller's stack:
 * +0 handler runs (incremented), then the last siginfo's si_signo (+8),
 * si_code (+16), si_pid (+24) and si_status (+32), each widened to u64. */
    .global sigchld_probe_arm
    .type sigchld_probe_arm, %function
/* x0 = record address. */
sigchld_probe_arm:
    msr     tpidr_el0, x0
    ret

    .global sigchld_probe_handler_address
    .type sigchld_probe_handler_address, %function
sigchld_probe_handler_address:
    adr     x0, sigchld_probe_handler
    ret

    .global sigchld_probe_restorer_address
    .type sigchld_probe_restorer_address, %function
sigchld_probe_restorer_address:
    adr     x0, sigchld_probe_restorer
    ret

/* x0 = signum, x1 = siginfo, x2 = ucontext. Clobbers x9-x10 only. */
sigchld_probe_handler:
    mrs     x9, tpidr_el0
    ldr     x10, [x9]
    add     x10, x10, #1
    str     x10, [x9]
    ldr     w10, [x1, #0]
    str     x10, [x9, #8]
    ldr     w10, [x1, #8]
    str     x10, [x9, #16]
    ldr     w10, [x1, #16]
    str     x10, [x9, #24]
    ldr     w10, [x1, #24]
    str     x10, [x9, #32]
    ret

sigchld_probe_restorer:
    mov     x8, #139
    svc     #0

/* GitHub issue #1138: a SIGUSR1 handler for user_payload's sigaltstack
 * probe, found like the SIGCHLD one through TPIDR_EL0. Its record (the
 * caller's, 104 bytes): +0 runs (incremented), +8 the handler's SP, +16
 * what sigaltstack(NULL, record+56) answered there, +24 what
 * sigaltstack(record+80, NULL) answered, +32/+40/+48 the frame's uc_stack
 * ss_sp, ss_flags and ss_size, +56 the stack_t that query wrote, +80 the
 * stack_t the caller prepared for the change. Returns through
 * sigchld_probe_restorer. */
    .global altstack_probe_handler_address
    .type altstack_probe_handler_address, %function
altstack_probe_handler_address:
    adr     x0, altstack_probe_handler
    ret

/* x0 = signum, x1 = siginfo, x2 = ucontext. Clobbers x0, x1, x8-x10. */
altstack_probe_handler:
    mrs     x9, tpidr_el0
    ldr     x10, [x9]
    add     x10, x10, #1
    str     x10, [x9]
    mov     x10, sp
    str     x10, [x9, #8]
    ldr     x10, [x2, #16]
    str     x10, [x9, #32]
    ldr     w10, [x2, #24]
    str     x10, [x9, #40]
    ldr     x10, [x2, #32]
    str     x10, [x9, #48]
    mov     x0, #0
    add     x1, x9, #56
    mov     x8, #132
    svc     #0
    str     x0, [x9, #16]
    add     x0, x9, #80
    mov     x1, #0
    mov     x8, #132
    svc     #0
    str     x0, [x9, #24]
    ret

/* GitHub issue #1147: mmap(NULL, length, prot, flags, -1, 0) for
 * user_payload's shared-mapping probe. svc5 sets x0-x4 only, and Linux
 * refuses an offset (x5) that is not page-aligned, so x5 is zeroed here. */
    .global shared_probe_mmap
    .type shared_probe_mmap, %function
shared_probe_mmap:
    mov     x3, x2
    mov     x2, x1
    mov     x1, x0
    mov     x0, #0
    mov     x4, #-1
    mov     x5, #0
    mov     x8, #222
    svc     #0
    ret
