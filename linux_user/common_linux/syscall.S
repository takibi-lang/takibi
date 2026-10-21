    .text

    .global linux_write
linux_write:
    mov $1, %rax
    syscall
    ret

    // GitHub issue #882: linux_syscall(nr, a0, a1, a2, a3), for the
    // fixtures that compare against the host kernel itself.
    .global linux_syscall
linux_syscall:
    mov %rdi, %rax
    mov %rsi, %rdi
    mov %rdx, %rsi
    mov %rcx, %rdx
    mov %r8, %r10
    syscall
    ret

    .global linux_exit
linux_exit:
    mov $60, %rax
    syscall

.Lexit_halt:
    hlt
    jmp .Lexit_halt

    .section .note.GNU-stack,"",@progbits
