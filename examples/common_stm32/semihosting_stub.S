    .syntax unified
    .thumb
    .align 2

/* -- No-op stand-ins for examples/fatfs/fatfs.tkb's semihosting extern fns --
   STM32 has no ARM semihosting host-file I/O the way QEMU does (this
   project's QEMU tests rely on -semihosting-config enable=on,target=native;
   nothing equivalent exists for the real board). fatfs.tkb is one shared
   file compiled for both targets and declares these four `extern fn`s
   unconditionally, so the STM32 link needs *some* symbol to satisfy them --
   same idea as examples/common_qemu/stm32_stub.tkb's no-op stand-in for an
   STM32-only symbol a shared file's dead-on-QEMU code still references,
   just the reverse direction and in assembly since these are `extern fn`
   (an unmangled symbol name is an external ABI contract, not overloadable).

   fatfs.tkb's own app_main() does not gate its logic on these calls
   succeeding -- see its Phase 1 comment: the STM32 hardware test harness
   (scripts/run_hwtest_ram.sh) instead injects/extracts examples/fatfs's
   `disk` array directly over the debug port with OpenOCD's
   load_image/dump_image, timed around a breakpoint so it happens instead
   of (not racing) whatever these stubs do. */

/* fn semihosting_open(name: *u8, name_len: i32, mode: i32) -> i32
   Always fails: there is no host file to open on this target. */
    .thumb_func
    .global semihosting_open
semihosting_open:
    movs    r0, #0
    mvns    r0, r0      /* r0 = -1 */
    bx      lr

/* fn semihosting_read(handle: i32, buf: *u8, len: i32) -> i32
   Returns len (0 bytes actually read), matching ARM semihosting's own
   "number of bytes NOT transferred" convention for a fully-failed call. */
    .thumb_func
    .global semihosting_read
semihosting_read:
    mov     r0, r2
    bx      lr

/* fn semihosting_write(handle: i32, buf: *u8, len: i32) -> i32
   Same convention as semihosting_read above. */
    .thumb_func
    .global semihosting_write
semihosting_write:
    mov     r0, r2
    bx      lr

/* fn semihosting_close(handle: i32) -> i32 */
    .thumb_func
    .global semihosting_close
semihosting_close:
    movs    r0, #0
    bx      lr
