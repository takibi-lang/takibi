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
   issue #169's only consumer, examples/common_rpi5/pcie.tkb's delay_us,
   only ever reads the free-running counter). This project's existing
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
