    .text
    .align 2

/* ── ARM Generic Timer システムレジスタスタブ ──────────────────────────────────
   mrs/msr 命令は takibi から直接使えないため、各1命令の薄いラッパーを用意する。  */

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

/* task_exit_stub: タスク関数が誤って return したときの安全ネット */
    .global task_exit_stub
    .type   task_exit_stub, %function
task_exit_stub:
.Lpark:
    wfe
    b       .Lpark
