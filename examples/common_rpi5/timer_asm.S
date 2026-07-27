    .text
    .align 2

/* -- ARM Generic Timer system register stubs -----------------------------------
   mrs/msr instructions cannot be used directly from takibi, so a
   one-instruction thin wrapper is provided for each -- same convention
   as examples/common_rpi3/timer_asm.S (pure ARMv8 architecture, not
   BCM2837-specific, so this is a straight copy of that file's own
   read_cntfrq/read_cntpct pair; the RPi3 file's OTHER stubs --
   cntp_tval/enable_cntp/disable_cntp, the one-shot comparator used by
   the preemptive-scheduler group -- are not ported here, since GitHub
   issue #169's first consumer, examples/common_rpi5/pcie.tkb's delay_us,
   only ever reads the free-running counter).  The physical comparator
   stubs below were added for the RPi5 scheduler port. This project's existing
   convention is every target owning its own common_X/ files even where
   the content is architecture-generic AArch64 (see
   examples/common_rpi3/print.tkb's own header comment for the same
   reasoning), not a shared reference into another target's directory. */

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

/* -- ARM Generic Timer physical-comparator stubs ---------------------------
   The BCM2712 uses the architectural CNTP PPI (INTID 30), just as the RPi3
   and QEMU scheduler HALs do.  The GIC routing is target-specific and lives
   in timer.tkb; these are deliberately just the architectural system-register
   accesses. */

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

/* task_exit_stub: safety net for a task function that returns. */
    .global task_exit_stub
    .type   task_exit_stub, %function
task_exit_stub:
.Ltask_exit_park:
    wfe
    b       .Ltask_exit_park
