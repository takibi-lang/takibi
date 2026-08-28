/* Minimal DTB-capturing spin stub for Raspberry Pi 5 (BCM2712) SWD
   bring-up. Built
   standalone (no takibi, no link against any HAL) and flashed as the SD
   card's kernel_2712.img -- see examples/common_rpi5/AGENTS.md.

   Same purpose as examples/common_rpi3/jtag_stub.S: give a debugger a
   clean, known, non-Linux halting point. RPi5's boot chain (EEPROM
   bootloader -> TF-A BL31, which hands 64-bit payloads off at EL2 per
   Trusted Firmware-A's own rpi5 platform docs) runs first exactly as it
   would for a real OS, but instead of booting Linux, config.txt's
   kernel=/os_check=0 settings point it at this stub. The first 64 bytes are
   a standard arm64 Image header, so firmware can perform its normal DTB
   handoff even though the payload is not Linux. The stub validates x0's
   FDT header, copies the complete blob to [0x100000, 0x200000), then parks
   in an infinite wfe loop with MMU/caches off and no OS state to corrupt.
   From there OpenOCD can halt core 0 and inject a real payload
   via `load_image` + PC/SP register pokes + `resume`, same technique as
   RPi3. Whether OpenOCD's `reset halt` can restart the whole boot chain
   here (the official Debug Probe's dedicated connector may carry a real
   SRST line, unlike RPi3's 6-pin GPIO header) is UNCONFIRMED as of this
   writing -- see scripts/rpi5_jtag_reset.sh's header comment.

   The previous raw 8-byte stub received a plausible x0 whose target was
   zero-filled, not an FDT. This version does not trust the register: magic,
   totalsize, alignment, and the one-MiB destination bound are checked before
   any source byte is copied. The copy is memmove-safe in case firmware placed
   its blob inside the destination window. OpenOCD independently checks the
   copied magic before overwriting RAM or resuming Takibi. */

    .equ DTB_COPY_START, 0x100000
    .equ DTB_COPY_LIMIT, 0x100000
    .equ FDT_MAGIC_LE,  0xedfe0dd0

    .section .text.boot, "ax"
    .global _start
_start:
    /* Standard 64-byte arm64 Image header. code0 branches over the data. */
    b       .Lcapture
    nop
    .quad   0x80000
    .quad   _image_end - _start
    .quad   0x2                 /* little-endian, 4K pages */
    .quad   0
    .quad   0
    .quad   0
    .long   0x644d5241          /* "ARM\x64", little-endian */
    .long   0

.Lcapture:
    /* x0 is the arm64 boot protocol's physical FDT address. */
    tst     x0, #7
    b.ne    .Linvalid
    ldr     w1, [x0]
    movz    w2, #0x0dd0
    movk    w2, #0xedfe, lsl #16
    cmp     w1, w2
    b.ne    .Linvalid
    ldr     w1, [x0, #4]
    rev     w1, w1              /* FDT fields are big-endian */
    cmp     w1, #40
    b.lo    .Linvalid
    mov     w2, #DTB_COPY_LIMIT
    cmp     w1, w2
    b.hi    .Linvalid

    mov     x2, #DTB_COPY_START
    cmp     x0, x2
    b.eq    .Lspin
    add     x3, x0, x1
    cmp     x2, x0
    b.lo    .Lcopy_forward
    cmp     x2, x3
    b.hs    .Lcopy_forward

    /* Destination starts inside the source range: copy backwards. */
    add     x4, x0, x1
    add     x5, x2, x1
.Lcopy_backward_loop:
    cbz     x1, .Lspin
    sub     x4, x4, #1
    sub     x5, x5, #1
    ldrb    w6, [x4]
    strb    w6, [x5]
    sub     x1, x1, #1
    b       .Lcopy_backward_loop

.Lcopy_forward:
    mov     x4, x0
    mov     x5, x2
.Lcopy_forward_loop:
    cbz     x1, .Lspin
    ldrb    w6, [x4], #1
    strb    w6, [x5], #1
    sub     x1, x1, #1
    b       .Lcopy_forward_loop

.Linvalid:
    /* Make a failed fresh boot distinguishable from a stale prior copy. */
    mov     x1, #DTB_COPY_START
    str     wzr, [x1]

.Lspin:
    wfe
    b       .Lspin

    .global _image_end
_image_end:
