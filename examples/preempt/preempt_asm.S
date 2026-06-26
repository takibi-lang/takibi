    .text
    .align 2

/* ── timer_init: GIC + ARM Virtual Timer の初期化 ──────────────────────────
   extern fn timer_init(); として takibi から呼ばれる。
   PPI #27 = AArch64 仮想タイマ割り込み。                                   */

    .global timer_init
    .type   timer_init, %function
timer_init:
    /* GICD_CTLR = 1 (Distributor enable) */
    ldr     x0, =0x08000000
    mov     w1, #1
    str     w1, [x0]

    /* GICD_ISENABLER0 bit30 = PPI #30 (EL1 physical timer) 有効化 */
    ldr     x0, =0x08000100
    mov     w1, #(1 << 30)
    str     w1, [x0]

    /* GICC_PMR = 0xff (全優先度の割り込みを受け入れる) */
    ldr     x0, =0x08010004
    mov     w1, #0xff
    str     w1, [x0]

    /* GICC_CTLR = 1 (CPU interface enable) */
    ldr     x0, =0x08010000
    mov     w1, #1
    str     w1, [x0]

    /* タイマの初回発火値を設定: CNTFRQ_EL0 / 64 ≈ 15 ms @ 62.5 MHz */
    mrs     x0, cntfrq_el0
    lsr     x0, x0, #6
    msr     cntp_tval_el0, x0

    /* CNTP_CTL_EL0 = 1 (EL1 物理タイマ有効化) */
    mov     x0, #1
    msr     cntp_ctl_el0, x0
    isb
    ret

/* ── setup_task_stack: 初期 irq_entry フレームをタスクスタックに積む ────────
   extern fn setup_task_stack(s: *char, f: fn() -> void) -> int;
   x0 = stack_top (スタック末尾の高位アドレス)
   x1 = タスクのエントリ関数ポインタ
   戻り値 w0 = 初期 SP (32 bit; QEMU virt は 4 GB 以内に収まる)

   irq_entry のフレームレイアウト (272 バイト):
     [  0.. 15] x0, x1
     [ 16.. 31] x2, x3
     ...
     [224..239] x28, x29
     [240..255] x30, xzr (padding)
     [256..263] ELR_EL1  ← タスクの PC
     [264..271] SPSR_EL1 ← 0x05 (EL1h, DAIF=0 = IRQ 有効)               */

    .global setup_task_stack
    .type   setup_task_stack, %function
setup_task_stack:
    /* 272 バイトのフレームを確保 */
    sub     x0, x0, #272

    /* フレームをゼロクリア (272 / 8 = 34 回) */
    mov     x2, x0
    mov     x3, #272
.Lzero:
    str     xzr, [x2], #8
    subs    x3, x3, #8
    bne     .Lzero

    /* ELR_EL1 (offset 256) = タスクのエントリ関数 */
    str     x1, [x0, #256]

    /* SPSR_EL1 (offset 264) = EL1h (0x05), DAIF=0 (割り込み有効) */
    mov     x1, #0x05
    str     x1, [x0, #264]

    /* x30 スロット (offset 240) = task_exit_stub
       タスク関数が return したとき WFE ループへ落ちるよう x30 をセット */
    adr     x1, task_exit_stub
    str     x1, [x0, #240]

    /* 戻り値 = フレームの先頭アドレス (w0 = 下位 32 bit) */
    ret

/* タスク関数が誤って return したときの安全ネット */
task_exit_stub:
.Lpark:
    wfe
    b       .Lpark

/* ── irq_dispatch: タイマ割り込みでラウンドロビン・コンテキストスイッチ ────
   startup.S の .weak irq_dispatch を上書きする強いシンボル。
   irq_entry から "bl irq_dispatch" で呼ばれる。呼び出し時点で:
     SP  → 272 バイトの保存フレーム (x0-x30, ELR_EL1, SPSR_EL1)
     x30 = irq_entry 内の戻りアドレス  ← ret で必ず使う
   irq_entry がすべての汎用レジスタを保存済みなので x0-x17 を自由に使える。
   スタックフレームは作らない (leaf 関数)。                                 */

    .global irq_dispatch
    .type   irq_dispatch, %function
irq_dispatch:
    /* step 1: GICC_IAR 読み出し → w1 = 割り込み ID */
    ldr     x0, =0x0801000C
    ldr     w1, [x0]

    /* step 2: EL1 物理タイマ (PPI #30) か確認 */
    cmp     w1, #30
    bne     .Ldispatch_eoi

    /* step 3: タイマ再アーム (CNTFRQ / 64) */
    mrs     x0, cntfrq_el0
    lsr     x0, x0, #6
    msr     cntp_tval_el0, x0

    /* step 4: total_ticks++ */
    ldr     x2, =total_ticks
    ldr     w3, [x2]
    add     w3, w3, #1
    str     w3, [x2]

    /* step 5: current_task インデックスを取得 */
    ldr     x4, =current_task
    ldr     w5, [x4]               /* w5 = current_task; x4 は step 9 で再利用 */

    /* step 6: tick_counts[current_task]++ */
    ldr     x6, =tick_counts
    add     x7, x6, x5, lsl #2    /* x7 = &tick_counts[current_task] */
    ldr     w8, [x7]
    add     w8, w8, #1
    str     w8, [x7]

    /* step 7: tcb_sp[current_task] = sp (現タスクの SP を保存) */
    ldr     x6, =tcb_sp
    add     x7, x6, x5, lsl #2    /* x7 = &tcb_sp[current_task] */
    mov     x8, sp
    str     w8, [x7]               /* 下位 32 bit を保存 */

    /* step 8: total_ticks >= max_ticks なら終了処理 */
    ldr     x6, =max_ticks
    ldr     w6, [x6]
    cmp     w3, w6
    blt     .Ldo_switch

    /* タイマ停止 (CNTP_CTL_EL0 = 0) → 以降の割り込みを抑制 */
    msr     cntp_ctl_el0, xzr

    /* sched_done = 1 */
    ldr     x6, =sched_done
    mov     w7, #1
    str     w7, [x6]

.Ldo_switch:
    /* step 9: next_task = (current_task + 1) % task_count */
    ldr     x6, =task_count
    ldr     w6, [x6]
    add     w5, w5, #1
    udiv    w7, w5, w6
    msub    w5, w7, w6, w5         /* w5 = (current_task + 1) % task_count */
    str     w5, [x4]               /* current_task = next_task */

    /* step 10: next task の SP をロードしてスタック切り替え */
    ldr     x6, =tcb_sp
    add     x7, x6, x5, lsl #2    /* x7 = &tcb_sp[next_task] */
    ldr     w8, [x7]               /* w8 = 次タスクの SP (32 bit) */
    uxtw    x8, w8                 /* 64 bit にゼロ拡張 */
    mov     sp, x8                 /* ← コンテキストスイッチ本体 */

.Ldispatch_eoi:
    /* GICC_EOIR に割り込み ID を書いて完了通知 */
    ldr     x0, =0x08010010
    str     w1, [x0]

    /* x30 = irq_entry の戻りアドレス → eret まで続く restore シーケンスへ */
    ret
