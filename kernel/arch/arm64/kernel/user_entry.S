/* EL1/EL0 transition and register-frame mechanics only. Syscall policy and
 * process lifetime remain in Takibi. run_initial_user returns to its EL1
 * caller after exit, so linear VM/page owners stay live on that call frame.
 */
    .section .rodata, "a"
    .align 4
initial_user_payload:
    /* write(9, ..., 1) must return -EBADF. */
    adr     x1, .Luser_message
    mov     x2, #1
    mov     x0, #9
    mov     x8, #64
    svc     #0
    mov     x9, #-9
    cmp     x0, x9
    b.ne    .Luser_fail

    /* write(1, null, 1) must return -EFAULT. */
    mov     x0, #1
    mov     x1, #0
    mov     x2, #1
    mov     x8, #64
    svc     #0
    mov     x9, #-14
    cmp     x0, x9
    b.ne    .Luser_fail

    /* openat/write/close /mutable.txt through the Linux file ABI. */
    mov     x0, #0
    adr     x1, .Lmutable_path
    mov     x2, #1
    mov     x8, #56
    svc     #0
    cmp     x0, #3
    b.ne    .Luser_fail
    mov     x0, #3
    adr     x1, .Lmutable_content
    mov     x2, #7
    mov     x8, #64
    svc     #0
    cmp     x0, #7
    b.ne    .Luser_fail
    mov     x0, #3
    mov     x8, #57
    svc     #0
    cbnz    x0, .Luser_fail

    /* socket/bind/listen/close one IPv4 stream endpoint. */
    mov     x0, #2
    mov     x1, #1
    mov     x2, #0
    mov     x8, #198
    svc     #0
    cmp     x0, #4
    b.ne    .Luser_fail
    mov     x0, #4
    adr     x1, .Lsocket_address
    mov     x2, #16
    mov     x8, #200
    svc     #0
    cbnz    x0, .Luser_fail
    mov     x0, #4
    mov     x1, #1
    mov     x8, #201
    svc     #0
    cbnz    x0, .Luser_fail
    mov     x0, #4
    mov     x1, #0
    mov     x2, #0
    mov     x3, #0
    mov     x8, #242
    svc     #0
    cmp     x0, #5
    b.ne    .Luser_fail
    sub     sp, sp, #32
    mov     x0, #5
    mov     x1, sp
    mov     x2, #32
    mov     x8, #63
    svc     #0
    cmp     x0, #16
    b.ne    .Luser_fail
    mov     x0, #5
    adr     x1, .Lsocket_response
    mov     x2, #19
    mov     x8, #64
    svc     #0
    cmp     x0, #19
    b.ne    .Luser_fail
    add     sp, sp, #32
    mov     x0, #5
    mov     x8, #57
    svc     #0
    cbnz    x0, .Luser_fail
    mov     x0, #4
    mov     x8, #57
    svc     #0
    cbnz    x0, .Luser_fail

    adr     x1, .Luser_message
    mov     x2, #21
    mov     x0, #1
    mov     x8, #64
    svc     #0
    cmp     x0, #21
    b.ne    .Luser_fail
    mov     x0, #0
    mov     x8, #93
    svc     #0
.Luser_fail:
    b       .Luser_fail
.Luser_message:
    .ascii  "hello from userspace\n"
.Lmutable_path:
    .asciz  "/mutable.txt"
.Lmutable_content:
    .ascii  "el0-ok\n"
    .balign 2
.Lsocket_address:
    .hword  2
    .byte   0x1f, 0x90
    .word   0
    .quad   0
.Lsocket_response:
    .ascii  "HTTP/1.0 200 OK\r\n\r\n"
initial_user_payload_end:

    .section .text, "ax"
    .global initial_user_payload_addr
initial_user_payload_addr:
    adrp    x0, initial_user_payload
    add     x0, x0, :lo12:initial_user_payload
    ret

    .global initial_user_payload_len
initial_user_payload_len:
    adrp    x0, initial_user_payload
    add     x0, x0, :lo12:initial_user_payload
    adrp    x1, initial_user_payload_end
    add     x1, x1, :lo12:initial_user_payload_end
    sub     x0, x1, x0
    ret

    .global user_code_sync
user_code_sync:
    mov     x3, x0
    add     x2, x0, x1
.Ldcache_sync:
    dc      cvau, x0
    add     x0, x0, #64
    cmp     x0, x2
    b.lo    .Ldcache_sync
    dsb     ish
    mov     x0, x3
.Licache_sync:
    ic      ivau, x0
    add     x0, x0, #64
    cmp     x0, x2
    b.lo    .Licache_sync
    dsb     ish
    isb
    ret

    .global run_initial_user
    .type run_initial_user, %function
run_initial_user:
    sub     sp, sp, #96
    stp     x19, x20, [sp, #0]
    stp     x21, x22, [sp, #16]
    stp     x23, x24, [sp, #32]
    stp     x25, x26, [sp, #48]
    stp     x27, x28, [sp, #64]
    stp     x29, x30, [sp, #80]
    msr     sp_el0, x1
    mov     x2, #0x3c0
    msr     spsr_el1, x2
    msr     elr_el1, x0
    eret

    .global el0_sync_entry
    .type el0_sync_entry, %function
el0_sync_entry:
    sub     sp, sp, #272
    stp     x0, x1, [sp, #0]
    stp     x2, x3, [sp, #16]
    stp     x4, x5, [sp, #32]
    stp     x6, x7, [sp, #48]
    stp     x8, x9, [sp, #64]
    stp     x10, x11, [sp, #80]
    stp     x12, x13, [sp, #96]
    stp     x14, x15, [sp, #112]
    stp     x16, x17, [sp, #128]
    stp     x18, x19, [sp, #144]
    stp     x20, x21, [sp, #160]
    stp     x22, x23, [sp, #176]
    stp     x24, x25, [sp, #192]
    stp     x26, x27, [sp, #208]
    stp     x28, x29, [sp, #224]
    mrs     x9, sp_el0
    stp     x30, x9, [sp, #240]
    mrs     x9, elr_el1
    mrs     x10, spsr_el1
    stp     x9, x10, [sp, #256]

    mrs     x0, esr_el1
    ldr     x1, [sp, #64]
    ldr     x2, [sp, #0]
    ldr     x3, [sp, #8]
    ldr     x4, [sp, #16]
    ldr     x5, [sp, #24]
    bl      kernel_syscall_dispatch
    mov     x6, x0
    mov     x7, x1
    cmp     x6, #1
    b.eq    .Lsyscall_resume
    cmp     x6, #2
    b.eq    .Lsyscall_exit
    mov     x16, #8
    b       el1_exception_evidence

.Lsyscall_resume:
    str     x7, [sp, #0]
    ldp     x0, x1, [sp, #256]
    msr     elr_el1, x0
    msr     spsr_el1, x1
    ldp     x0, x1, [sp, #0]
    ldp     x2, x3, [sp, #16]
    ldp     x4, x5, [sp, #32]
    ldp     x6, x7, [sp, #48]
    ldp     x8, x9, [sp, #64]
    ldp     x10, x11, [sp, #80]
    ldp     x12, x13, [sp, #96]
    ldp     x14, x15, [sp, #112]
    ldp     x16, x17, [sp, #128]
    ldp     x18, x19, [sp, #144]
    ldp     x20, x21, [sp, #160]
    ldp     x22, x23, [sp, #176]
    ldp     x24, x25, [sp, #192]
    ldp     x26, x27, [sp, #208]
    ldp     x28, x29, [sp, #224]
    ldp     x30, xzr, [sp, #240]
    add     sp, sp, #272
    eret

.Lsyscall_exit:
    mov     x0, x7
    add     sp, sp, #272
    ldp     x19, x20, [sp, #0]
    ldp     x21, x22, [sp, #16]
    ldp     x23, x24, [sp, #32]
    ldp     x25, x26, [sp, #48]
    ldp     x27, x28, [sp, #64]
    ldp     x29, x30, [sp, #80]
    add     sp, sp, #96
    ret
