    .section .text.boot
    .global _start
_start:
    /* Set up stack pointer */
    adrp    x0, stack_top
    add     x0, x0, :lo12:stack_top
    mov     sp, x0

    /* Install exception vector table */
    adrp    x0, exception_vectors
    add     x0, x0, :lo12:exception_vectors
    msr     vbar_el1, x0
    isb

    /* Enable IRQ and FIQ (clear DAIF.I and DAIF.F).
       GICv2 デフォルト（GICC_CTLR.FIQEn=0）では Group0 SPI は IRQ として届く（0x280）。
       FIQEn=1 にした場合に備えて FIQ も有効化しておく。GIC 未初期化時は全割り込み
       無効なので既存例題への影響はない。割り込みを使うプログラムが GIC を初期化する。 */
    msr     DAIFClr, #0x3
    isb

    /* Zero-initialise BSS */
    adrp    x0, __bss_start
    add     x0, x0, :lo12:__bss_start
    adrp    x1, __bss_end
    add     x1, x1, :lo12:__bss_end
    cmp     x0, x1
    b.ge    .Lbss_done
.Lbss_loop:
    str     xzr, [x0], #8
    cmp     x0, x1
    b.lt    .Lbss_loop
.Lbss_done:

    bl      main

    /* AArch64 semihosting: SYS_EXIT (0x18)
       On AArch64 the extended format is always used:
       x1 must point to a two-word parameter block:
         [0] ADP_Stopped_ApplicationExit (0x20026)
         [1] exit code (0 = success)                */
    mov     x0, #0x18
    adrp    x1, exit_params
    add     x1, x1, :lo12:exit_params
    hlt     #0xf000

    /* Should not reach here */
.Lhalt:
    wfe
    b       .Lhalt

/* ── IRQ helpers callable from takibi ──────────────────────────────────────── */

/* enable_irq(): DAIF.I ビットをクリアして IRQ を有効にする */
    .global enable_irq
enable_irq:
    msr     DAIFClr, #0x2
    isb
    ret

/* disable_irq(): DAIF.I ビットをセットして IRQ を無効にする */
    .global disable_irq
disable_irq:
    msr     DAIFSet, #0x2
    isb
    ret

/* ── Default (no-op) irq_dispatch ──────────────────────────────────────────── */
/* takibi プログラムが irq_dispatch を定義した場合、そちらが優先される（強いシンボル）*/
    .weak   irq_dispatch
irq_dispatch:
    ret

    .section .rodata
    .align  3
exit_params:
    .quad   0x20026    /* ADP_Stopped_ApplicationExit */
    .quad   0          /* exit code: 0               */

/* ── Exception vector table (2KB アライン必須) ─────────────────────────────── */
    .section .text.vectors
    .align  11         /* 2^11 = 2048 バイトアライン */
    .global exception_vectors
exception_vectors:
    /* EL1t (SP_EL0 使用時) */
    b       .                   /* 0x000: Synchronous */
    .align  7
    b       irq_entry           /* 0x080: IRQ         */
    .align  7
    b       irq_entry           /* 0x100: FIQ (Group0 with FIQEn=1) */
    .align  7
    b       .                   /* 0x180: SError      */
    /* EL1h (SP_EL1 使用時: reset 後のデフォルト) */
    .align  7
    b       .                   /* 0x200: Synchronous */
    .align  7
    b       irq_entry           /* 0x280: IRQ  ← 通常はここに来る */
    .align  7
    b       irq_entry           /* 0x300: FIQ         */
    .align  7
    b       .                   /* 0x380: SError      */
    /* Lower EL (AArch64) */
    .align  7
    b       .                   /* 0x400: Synchronous */
    .align  7
    b       .                   /* 0x480: IRQ         */
    .align  7
    b       .                   /* 0x500: FIQ         */
    .align  7
    b       .                   /* 0x580: SError      */
    /* Lower EL (AArch32) */
    .align  7
    b       .                   /* 0x600: Synchronous */
    .align  7
    b       .                   /* 0x680: IRQ         */
    .align  7
    b       .                   /* 0x700: FIQ         */
    .align  7
    b       .                   /* 0x780: SError      */

/* ── IRQ エントリ: 全汎用レジスタ + ELR/SPSR を保存して irq_dispatch を呼ぶ ── */
irq_entry:
    sub     sp,  sp,  #272
    stp     x0,  x1,  [sp, #0]
    stp     x2,  x3,  [sp, #16]
    stp     x4,  x5,  [sp, #32]
    stp     x6,  x7,  [sp, #48]
    stp     x8,  x9,  [sp, #64]
    stp     x10, x11, [sp, #80]
    stp     x12, x13, [sp, #96]
    stp     x14, x15, [sp, #112]
    stp     x16, x17, [sp, #128]
    stp     x18, x19, [sp, #144]
    stp     x20, x21, [sp, #160]
    stp     x22, x23, [sp, #176]
    stp     x24, x25, [sp, #192]
    stp     x26, x27, [sp, #208]
    stp     x28, x29, [sp, #224]
    stp     x30, xzr, [sp, #240]
    mrs     x0,  elr_el1
    mrs     x1,  spsr_el1
    stp     x0,  x1,  [sp, #256]

    bl      irq_dispatch

    ldp     x0,  x1,  [sp, #256]
    msr     elr_el1,  x0
    msr     spsr_el1, x1
    ldp     x0,  x1,  [sp, #0]
    ldp     x2,  x3,  [sp, #16]
    ldp     x4,  x5,  [sp, #32]
    ldp     x6,  x7,  [sp, #48]
    ldp     x8,  x9,  [sp, #64]
    ldp     x10, x11, [sp, #80]
    ldp     x12, x13, [sp, #96]
    ldp     x14, x15, [sp, #112]
    ldp     x16, x17, [sp, #128]
    ldp     x18, x19, [sp, #144]
    ldp     x20, x21, [sp, #160]
    ldp     x22, x23, [sp, #176]
    ldp     x24, x25, [sp, #192]
    ldp     x26, x27, [sp, #208]
    ldp     x28, x29, [sp, #224]
    ldp     x30, xzr, [sp, #240]
    add     sp,  sp,  #272
    eret
