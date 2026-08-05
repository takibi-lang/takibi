/* Writable RAM-backed ext2 fixture. The filesystem core sees only the block
 * interface; a later RPi5 storage driver can provide the same operations.
 *
 * GitHub issue #225: kernel_ext2_image_start/_end are referenced directly
 * from .tkb via `extern symbol` (kernel/user/ext2_image_extern.tkb) -- a
 * bare reference to either name evaluates to its own address, so the former
 * kernel_ext2_image_addr/_len accessor functions (adrp/add/ret and an
 * end-minus-start subtraction) are gone; that arithmetic is now ordinary
 * .tkb in kernel/drivers/block/memory.tkb. */
    .section .data, "aw"
    .align 10
    .global kernel_ext2_image_start
kernel_ext2_image_start:
    .incbin "kernel/build/user/ext2.img"
    .global kernel_ext2_image_end
kernel_ext2_image_end:
