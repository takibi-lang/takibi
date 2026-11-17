/* Negative ABI fixture only: a valid borrowed first span and a deliberately
 * invalid one-byte null tail. No address is retained after the syscall. */
.text
.global user_payload_readv_invalid_tail
.type user_payload_readv_invalid_tail, %function
/* x0 = fd, x1 = borrowed output, x2 = first capacity; x0 = raw result. */
user_payload_readv_invalid_tail:
    sub sp, sp, #32
    stp x1, x2, [sp]
    mov x9, #0
    mov x10, #1
    stp x9, x10, [sp, #16]
    mov x1, sp
    mov x2, #2
    mov x8, #65
    svc #0
    add sp, sp, #32
    ret
.size user_payload_readv_invalid_tail, .-user_payload_readv_invalid_tail
