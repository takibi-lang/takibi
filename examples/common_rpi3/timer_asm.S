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

/* -- ARM Generic Timer comparator stubs -----------------------------------
   Used by the preemptive-scheduler group (examples/preempt and
   siblings) via examples/common_rpi3/timer.tkb, not by
   examples/common_rpi3/rtc.tkb above (which only ever reads the
   free-running counter, never arms the comparator) -- identical bodies
   to examples/common_qemu/timer_asm.S's versions (pure ARMv8
   architecture, not BCM2837-specific). */

    .global set_cntp_tval
    .type   set_cntp_tval, %function
set_cntp_tval:          /* fn set_cntp_tval(n: i32) */
    msr     cntp_tval_el0, x0
    ret

    .global enable_cntp
    .type   enable_cntp, %function
enable_cntp:            /* fn enable_cntp() */
    mov     x0, #1
    msr     cntp_ctl_el0, x0
    isb
    ret

    .global disable_cntp
    .type   disable_cntp, %function
disable_cntp:           /* fn disable_cntp() */
    msr     cntp_ctl_el0, xzr
    ret

/* task_exit_stub: safety net for when a task function mistakenly returns */
    .global task_exit_stub
    .type   task_exit_stub, %function
task_exit_stub:
.Lpark:
    wfe
    b       .Lpark
