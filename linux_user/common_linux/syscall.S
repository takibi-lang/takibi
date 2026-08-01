    .text

    .global linux_write
linux_write:
    mov $1, %rax
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
