    .section .text.start
    .global _start
_start:
    call main

    mov $60, %rax
    xor %rdi, %rdi
    syscall

.Lhalt:
    hlt
    jmp .Lhalt

    .section .note.GNU-stack,"",@progbits
