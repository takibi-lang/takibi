    .text
    .align 2

/* ── ARM Generic Timer system register stubs ──────────────────────────────────
   mrs/msr instructions cannot be used directly from takibi,
   so a one-instruction thin wrapper is provided for each.  */

    .global read_cntfrq
    .type   read_cntfrq, %function
read_cntfrq:            /* fn read_cntfrq() -> int */
    mrs     x0, cntfrq_el0
    ret

    .global set_cntp_tval
    .type   set_cntp_tval, %function
set_cntp_tval:          /* fn set_cntp_tval(n: int) */
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
