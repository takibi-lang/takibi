    .syntax unified
    .thumb

/* -- RAM-execution startup, for `make hwcheck` only ----------------------
   Sibling of startup.S, used only when linking against link_ram.ld. The
   difference this file exists for: startup.S boots straight from Flash at
   0x08000000 (the vector table lives exactly where the CPU's hardware
   reset sequence always looks: word 0 of address 0x00000000, aliased to
   Flash), so it never needs to touch VTOR at all. That hardware fetch
   cannot itself be redirected to RAM without physically changing the
   board's BOOT pins -- not something a test harness should be doing on
   every run. Instead, scripts/run_hwtest_ram.sh halts the core at reset
   (before any Flash code ever runs), writes this file's linked image
   directly into AXI SRAM1 over the debug port, and then does by hand,
   from the debugger, exactly what silicon would have done automatically
   from Flash: read the initial SP/PC out of word 0/word 1 of this file's
   own _vector_table and load them into the SP/PC registers. This file's
   only remaining job, done in software instead, is the one boot step a
   debugger register poke *cannot* do on its own: point VTOR at this
   image's vector table before any interrupt can fire, since VTOR resets
   to 0x00000000 (the Flash alias) and nothing else will ever correct it.

   No explicit MPU region is configured here (unlike startup.S's Ethernet
   DMA window). ARMv7-M's architectural default memory map already
   describes the whole 0x20000000-0x3FFFFFFF SRAM range -- which covers
   AXI SRAM1 -- as Normal, Write-Back Write-Allocate cacheable, shareable,
   and executable; that is exactly the "genuinely cacheable" behavior this
   RAM-execution path exists to exercise (see CLAUDE.md/HISTORY.md's note
   on why the Ethernet DMA window is deliberately marked non-cacheable
   instead -- this file intentionally does NOT repeat that choice). The
   MPU is left disabled, so every access simply uses that default map. */
    .section .isr_vector, "a"
    .align  2
    .global _vector_table
_vector_table:
    .word   _stack_top          /* initial SP -- read by the harness, not hardware */
    .word   Reset_Handler       /* initial PC -- read by the harness, not hardware */
    .word   Default_Handler     /* NMI         */
    .word   Default_Handler     /* HardFault   */
    .word   Default_Handler     /* MemManage   */
    .word   Default_Handler     /* BusFault    */
    .word   Default_Handler     /* UsageFault  */
    .word   0                   /* Reserved    */
    .word   0
    .word   0
    .word   0
    .word   Default_Handler     /* SVCall      */
    .word   Default_Handler     /* DebugMon    */
    .word   0                   /* Reserved    */
    .word   PendSV_Handler      /* PendSV      */
    .word   SysTick_Handler     /* SysTick     */
    /* External interrupts through IRQ61 (Ethernet) -- same layout as
       startup.S, kept identical even though no RAM-execution example uses
       IRQ37/IRQ61 yet, so a future Ethernet migration changes nothing here. */
    .rept   37                  /* IRQ0-36 */
    .word   Default_Handler
    .endr
    .word   USART1_IRQHandler   /* IRQ37 */
    .rept   23                  /* IRQ38-60 */
    .word   Default_Handler
    .endr
    .word   ETH_IRQHandler      /* IRQ61 */

    .section .text
    .thumb_func
    .global Reset_Handler
Reset_Handler:
    /* Point VTOR at this image's own vector table. Must happen before
       anything below could plausibly cause an exception (a bad load/store
       would fault into the wrong table otherwise) and long before `bl
       main` might enable any peripheral interrupt. */
    ldr     r0, =0xE000ED08     /* SCB_VTOR */
    ldr     r1, =_vector_table
    str     r1, [r0]
    dsb
    isb

    /* No .data copy loop here, unlike startup.S: link_ram.ld gives .data
       the same load address and run address (there is no separate Flash
       copy to copy out of -- the debug probe writes the final bytes
       directly into RAM), so the values are already correct in place. */

    /* Zero-initialise BSS (identical to startup.S). */
    ldr     r0, =__bss_start
    ldr     r1, =__bss_end
    movs    r2, #0
.Lzero_bss_loop:
    cmp     r0, r1
    bge     .Lzero_bss_done
    str     r2, [r0], #4
    b       .Lzero_bss_loop
.Lzero_bss_done:

    /* Enable both Cortex-M7 L1 caches (identical sequence to startup.S).
       Invalidating first is defensive: a genuine core reset already
       leaves both caches disabled/architecturally-invalid, but costs
       nothing to repeat here rather than assume it. Unlike startup.S,
       there is no MPU region to configure first -- see the file header
       comment: the default memory map already makes AXI SRAM1 Normal
       WBWA-cacheable, so enabling the caches is the only step needed for
       this image's own code and data to actually be cached. */
    dsb
    ldr     r0, =0xE000EF60     /* SCB_DCISW */
    movs    r1, #0
.Ldcache_way:
    movs    r2, #0
.Ldcache_set:
    lsls    r3, r1, #30
    orr     r3, r3, r2, lsl #5
    str     r3, [r0]
    adds    r2, r2, #1
    cmp     r2, #32
    blt     .Ldcache_set
    adds    r1, r1, #1
    cmp     r1, #4
    blt     .Ldcache_way
    dsb
    isb

    ldr     r0, =0xE000EF50     /* SCB_ICIALLU */
    movs    r1, #0
    str     r1, [r0]
    dsb
    isb

    ldr     r0, =0xE000ED14     /* SCB_CCR */
    ldr     r1, [r0]
    orr     r1, r1, #(1 << 16)  /* DC */
    orr     r1, r1, #(1 << 17)  /* IC */
    str     r1, [r0]
    dsb
    isb

    /* Switch Thread mode to PSP, same 2KB MSP/PSP split as startup.S (see
       that file's comment for why the split -- not just a copy -- is
       required once a preemptive-scheduler example is in the mix). */
    mrs     r0, msp
    sub     r0, r0, #0x800
    msr     psp, r0
    movs    r0, #2
    msr     control, r0
    isb

    bl      main

.Lhalt:
    b       .Lhalt

    .thumb_func
Default_Handler:
    b       .

/* PendSV/pendsv_dispatch/SysTick_Handler/ETH_IRQHandler: identical to
   startup.S (see that file's comments) -- nothing about RAM execution
   changes any of this. */
    .thumb_func
    .global PendSV_Handler
PendSV_Handler:
    mrs     r0, psp
    stmdb   r0!, {r4-r11}
    bl      pendsv_dispatch
    ldmia   r0!, {r4-r11}
    msr     psp, r0
    ldr     lr, =0xFFFFFFFD
    bx      lr

    .weak   pendsv_dispatch
    .thumb_func
pendsv_dispatch:
    bx      lr

    .weak   SysTick_Handler
    .thumb_func
SysTick_Handler:
    bx      lr

    .weak   ETH_IRQHandler
    .thumb_func
ETH_IRQHandler:
    bx      lr
