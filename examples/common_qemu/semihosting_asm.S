    .text
    .align 2

/* -- ARM semihosting file I/O stubs --------------------------------------------
   QEMU is launched with -semihosting-config enable=on,target=native, which
   maps these calls directly onto real host files (already relied on by
   startup.S's SYS_EXIT). Each stub builds an 8-byte-word parameter block on
   the stack (see startup.S's exit_params for the same one-word-per-.quad
   convention on AArch64 semihosting), points x1 at it, sets x0 to the
   operation number, and traps with "hlt #0xf000". Used by examples/fatfs to
   write its in-memory disk image out to a host file for mtools to verify. */

/* fn semihosting_open(name: *u8, name_len: i32, mode: i32) -> i32
   SYS_OPEN (0x01): block = { name_ptr, mode, name_len }.
   mode 5 = "wb" (create/truncate, write, binary). Returns handle, or -1. */
    .global semihosting_open
    .type   semihosting_open, %function
semihosting_open:
    sub     sp, sp, #32
    str     x0, [sp, #0]      /* name ptr */
    str     x2, [sp, #8]      /* mode */
    str     x1, [sp, #16]     /* name_len */
    mov     x1, sp
    mov     x0, #0x01         /* SYS_OPEN */
    hlt     #0xf000
    add     sp, sp, #32
    ret

/* fn semihosting_write(handle: i32, buf: *u8, len: i32) -> i32
   SYS_WRITE (0x05): block = { handle, buf_ptr, len }.
   Returns the number of bytes NOT written (0 = full success). */
    .global semihosting_write
    .type   semihosting_write, %function
semihosting_write:
    sub     sp, sp, #32
    str     x0, [sp, #0]      /* handle */
    str     x1, [sp, #8]      /* buf ptr */
    str     x2, [sp, #16]     /* len */
    mov     x1, sp
    mov     x0, #0x05         /* SYS_WRITE */
    hlt     #0xf000
    add     sp, sp, #32
    ret

/* fn semihosting_close(handle: i32) -> i32
   SYS_CLOSE (0x02): block = { handle }. Returns 0 on success, -1 on failure. */
    .global semihosting_close
    .type   semihosting_close, %function
semihosting_close:
    sub     sp, sp, #16
    str     x0, [sp, #0]      /* handle */
    mov     x1, sp
    mov     x0, #0x02         /* SYS_CLOSE */
    hlt     #0xf000
    add     sp, sp, #16
    ret
