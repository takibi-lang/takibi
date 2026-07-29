/* Writable RAM-backed ext2 fixture. The filesystem core sees only the block
 * interface; a later RPi5 storage driver can provide the same operations. */
    .section .data, "aw"
    .align 10
kernel_ext2_image_start:
    .incbin "kernel/build/user/ext2.img"
kernel_ext2_image_end:

    .section .text, "ax"
    .global kernel_ext2_image_addr
kernel_ext2_image_addr:
    adrp    x0, kernel_ext2_image_start
    add     x0, x0, :lo12:kernel_ext2_image_start
    ret

    .global kernel_ext2_image_len
kernel_ext2_image_len:
    adrp    x0, kernel_ext2_image_start
    add     x0, x0, :lo12:kernel_ext2_image_start
    adrp    x1, kernel_ext2_image_end
    add     x1, x1, :lo12:kernel_ext2_image_end
    sub     x0, x1, x0
    ret
