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

/* ── setup_task_stack: 初期 irq_entry フレームをタスクスタックに積む ────────────
   fn setup_task_stack(s: *char, f: fn() -> void) -> int
   x0 = stack_top、x1 = タスクのエントリ関数ポインタ
   戻り値 w0 = フレーム先頭アドレス（32 bit）

   irq_entry フレームレイアウト (272 バイト):
     [  0..239] x0-x30 ペア保存領域（ゼロクリアで初期化）
     [240..255] x30 スロット ← task_exit_stub（誤 return 時の安全ネット）
     [256..263] ELR_EL1 ← タスクのエントリ PC
     [264..271] SPSR_EL1 ← 0x05 (EL1h, DAIF=0 = IRQ 有効)

   64 bit ポインタを特定オフセットに書く必要があるため takibi では書けず assembly に残す。 */

    .global setup_task_stack
    .type   setup_task_stack, %function
setup_task_stack:
    sub     x0, x0, #272            /* フレーム先頭 = stack_top - 272 */
    mov     x2, x0
    mov     x3, #272
.Lzero:
    str     xzr, [x2], #8
    subs    x3, x3, #8
    bne     .Lzero
    str     x1, [x0, #256]          /* ELR_EL1 = タスクのエントリ関数 */
    mov     x1, #0x05
    str     x1, [x0, #264]          /* SPSR_EL1 = EL1h, DAIF=0 */
    adr     x1, task_exit_stub
    str     x1, [x0, #240]          /* x30 スロット = task_exit_stub */
    ret                              /* w0 = フレーム先頭（下位 32 bit）*/

task_exit_stub:
.Lpark:
    wfe
    b       .Lpark
