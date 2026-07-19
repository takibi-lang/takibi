    .text
    .align 2

/* -- ARM Generic Timer system register stubs -----------------------------------
   mrs/msr instructions cannot be used directly from takibi, so a
   one-instruction thin wrapper is provided for each -- same convention
   as examples/common_qemu/timer_asm.S. This file is a separate copy
   (not a shared reference into examples/common_qemu/), matching this
   project's existing convention of every target owning its own
   common_X/ files even where the content is architecture-generic
   AArch64 (see examples/common_rpi3/print.tkb's own header comment for
   the same reasoning). Only the free-running counter read is new here
   (examples/common_qemu/timer_asm.S has no equivalent -- it only ever
   needed the comparator timer, not the counter itself) -- see
   examples/common_rpi3/rtc.tkb for why. */

    .global read_cntfrq
    .type   read_cntfrq, %function
read_cntfrq:            /* fn read_cntfrq() -> i64 */
    mrs     x0, cntfrq_el0
    ret

    .global read_cntpct
    .type   read_cntpct, %function
read_cntpct:             /* fn read_cntpct() -> i64 */
    mrs     x0, cntpct_el0
    ret
