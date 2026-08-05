/* GitHub issue #225: kernel_initramfs_start/_end are referenced directly
 * from .tkb via `extern symbol` (kernel/user/initramfs_extern.tkb) -- a
 * bare reference to either name evaluates to its own address, so the former
 * kernel_initramfs_addr/_len accessor functions are gone; that arithmetic
 * is now ordinary .tkb in kernel/fs/initramfs.tkb. */
    .section .rodata, "a"
    .align 4
    .global kernel_initramfs_start
kernel_initramfs_start:
    .incbin "kernel/build/user/initramfs.cpio"
    .global kernel_initramfs_end
kernel_initramfs_end:
