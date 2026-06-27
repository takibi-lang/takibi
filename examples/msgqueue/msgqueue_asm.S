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

/* ── セマフォ（ldaxr / stlxr による アトミック実装） ──────────────────────────

   sem_wait(s: *int)
     カウンタが正になるまでスピンし、アトミックにデクリメントする。
     ldaxr（load-exclusive + acquire barrier）で読み、
     stxr（store-exclusive）で書き戻す。
     カウンタ == 0 のときは clrex でモニタをクリアして再試行。
     ストア競合（他コアが exclusive を破った）のときも先頭から再試行。  */

    .global sem_wait
    .type   sem_wait, %function
sem_wait:                   /* fn sem_wait(s: *int) */
.Lw_retry:
    ldaxr   w1, [x0]        /* load-exclusive (+ acquire) */
    cbz     w1, .Lw_zero    /* counter == 0: 待機 */
    sub     w2, w1, #1
    stxr    w3, w2, [x0]    /* store-exclusive; w3 == 0 なら成功 */
    cbnz    w3, .Lw_retry   /* 競合 → 最初からやり直し */
    ret
.Lw_zero:
    clrex                   /* exclusive monitor をクリア */
    b       .Lw_retry

/*   sem_post(s: *int)
     アトミックにカウンタをインクリメントする。
     stlxr（store-exclusive + release barrier）で書き戻す。  */

    .global sem_post
    .type   sem_post, %function
sem_post:                   /* fn sem_post(s: *int) */
.Lp_retry:
    ldxr    w1, [x0]        /* load-exclusive */
    add     w2, w1, #1
    stlxr   w3, w2, [x0]   /* store-exclusive (+ release) */
    cbnz    w3, .Lp_retry   /* 競合 → 再試行 */
    ret

/* task_exit_stub: タスク関数が誤って return したときの安全ネット */
    .global task_exit_stub
    .type   task_exit_stub, %function
task_exit_stub:
.Lpark:
    wfe
    b       .Lpark
