    .section .rodata, "a"
    .align 4
kernel_initramfs_start:
    .incbin "kernel/build/user/initramfs.cpio"
kernel_initramfs_end:

    .section .text, "ax"
    .global kernel_initramfs_addr
kernel_initramfs_addr:
    adrp    x0, kernel_initramfs_start
    add     x0, x0, :lo12:kernel_initramfs_start
    ret

    .global kernel_initramfs_len
kernel_initramfs_len:
    adrp    x0, kernel_initramfs_start
    add     x0, x0, :lo12:kernel_initramfs_start
    adrp    x1, kernel_initramfs_end
    add     x1, x1, :lo12:kernel_initramfs_end
    sub     x0, x1, x0
    ret
