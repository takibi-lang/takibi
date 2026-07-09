    .syntax unified
    .thumb

/* Flash-execution startup: now used only by examples/http_server's
   kernel_stm32.elf/.bin (see the Makefile's comment on that rule) so a
   demo unit can boot the HTTP server standalone from power-on with no
   debugger attached. Every other STM32 example runs from RAM instead --
   see examples/common_stm32/startup_ram.S. */

/* -- Vector table (Cortex-M7) -------------------------------------------
   Cortex-M has no analogue of AArch64's VBAR_EL1 + branch-instruction
   table: the CPU auto-loads the initial SP from word 0 and the reset PC
   from word 1 at power-on, and every later exception dispatches through a
   plain function-pointer table entry (no manual all-GPR-save/eret dance
   like examples/common_qemu/startup.S's irq_entry -- the hardware auto-stacks
   r0-r3/r12/lr/pc/xPSR on entry). This board boots straight from flash at
   0x08000000, which is also where the vector table must live, so no
   explicit VTOR write is needed.

   PendSV is always wired to a real handler (below): it's the standard
   Cortex-M context-switch mechanism (see PendSV_Handler's comment), shared
   by every preemptive-scheduler example, harmless to include unconditionally
   since nothing ever sets ICSR.PENDSVSET unless a program explicitly enables
   SysTick. SysTick, USART1 (IRQ37), and Ethernet (IRQ61)
   example currently uses) are `.weak`, defaulting to a no-op return rather
   than Default_Handler's infinite loop -- unlike a genuine fault, these only
   fire if a program deliberately enabled them, so hanging is not the safe
   default here. IRQ0-36 are never used by anything; Default_Handler's loop
   is the appropriate catch-all for those (and for real faults). */
    .section .isr_vector, "a"
    .align  2
    .global _vector_table
_vector_table:
    .word   _stack_top          /* initial SP */
    .word   Reset_Handler
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
    /* External interrupts through IRQ61 (Ethernet). */
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
    /* Copy .data from flash (load address) to RAM (run address). QEMU's
       startup.S has no equivalent of this loop: QEMU loads the whole
       image directly into RAM, but on real hardware initialized globals
       live in flash at boot and must be copied out by hand. */
    ldr     r0, =_sidata
    ldr     r1, =_sdata
    ldr     r2, =_edata
.Lcopy_data_loop:
    cmp     r1, r2
    bge     .Lcopy_data_done
    ldr     r3, [r0], #4
    str     r3, [r1], #4
    b       .Lcopy_data_loop
.Lcopy_data_done:

    /* Zero-initialise BSS (same idea as examples/common_qemu/startup.S, same
       symbol names, just 32-bit word stores instead of 64-bit). */
    ldr     r0, =__bss_start
    ldr     r1, =__bss_end
    movs    r2, #0
.Lzero_bss_loop:
    cmp     r0, r1
    bge     .Lzero_bss_done
    str     r2, [r0], #4
    b       .Lzero_bss_loop
.Lzero_bss_done:

    /* No MPU region is configured (unlike an earlier version of this file,
       which marked AXI SRAM1's first 64KB non-cacheable specifically so
       Ethernet DMA ownership transfers couldn't leave descriptor/packet
       data in different versions of a cache line). ARMv7-M's architectural
       default memory map already describes 0x20000000-0x3FFFFFFF (which
       covers both DTCM and AXI SRAM1) as Normal, Write-Back Write-Allocate
       cacheable, shareable, executable -- exactly what's wanted here, with
       no MPU setup at all. AXI SRAM1's DMA descriptors/buffers are
       genuinely cacheable as a result; examples/common_stm32/eth.tkb's
       dma_prepare_tx/dma_prepare_rx/dma_finish_rx calls (real Cortex-M7
       cache-line clean/invalidate, not the barrier-only no-ops they were
       against the old non-cacheable window) are what keep CPU and DMA
       views coherent now -- see CLAUDE.md/HISTORY.md's RAM-execution
       entries for the full reasoning and the real-hardware Ethernet
       validation this change is based on (originally proven via the
       RAM-execution build, then applied here to this Flash-execution
       startup too since the same driver code and memory layout apply
       regardless of where .text/.isr_vector themselves are fetched from).
       examples/common_stm32/startup_ram.S (used by every other STM32
       example) documents the identical no-MPU-needed reasoning. */

    /* Enable both Cortex-M7 L1 caches. The 4KB D-cache is 4-way set
       associative with 32-byte lines, so invalidate all 32 sets in all
       four ways before setting CCR.DC. */
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
    /* Switch Thread mode to use PSP (process stack pointer), reserving the
       top 0x800 (2KB) bytes of the boot stack region exclusively for MSP
       (exception/Handler mode always uses MSP, never PSP, regardless of
       this switch) and starting PSP 2KB below that. Needed before any
       preemptive-scheduler example can safely tick: those treat main() as
       "task 0", switched via the exact same PendSV mechanism as its
       explicitly-created tasks (see examples/common_stm32/scheduler.tkb),
       so main() must already be running on PSP by the time SysTick/PendSV
       can first fire -- PendSV_Handler unconditionally reads/writes PSP,
       but Cortex-M defaults to MSP for everything after reset.

       The 2KB split is not optional headroom -- without it, an earlier
       version of this code set PSP to the *same* address as MSP (a plain
       copy, no offset), so the two stacks fully overlapped rather than
       occupying separate memory: any exception's own stack usage (MSP,
       always starting fresh at the top) silently clobbered whatever
       Thread-mode code (PSP) had already pushed just below that same
       address. This went unnoticed by every preempt/semaphore/condvar/
       msgqueue test (their task functions and SysTick_Handlers are shallow
       enough that the corruption happened not to touch anything that
       mattered) until watchdog's SysTick_Handler -- which calls the real
       function wdt_check(), using more MSP stack depth -- corrupted an
       in-flight PendSV frame and hit a HardFault (confirmed via
       openocd/gdb-multiarch register inspection: CFSR bit 18 INVPC, HFSR
       bit 30 FORCED, LR = 0xFFFFFFFD -- the fault was in the PendSV
       exception-return path itself). Harmless for every other example
       otherwise: ordinary push/pop/call behavior is identical regardless
       of which register is currently selected as the Thread-mode SP. */
    mrs     r0, msp
    sub     r0, r0, #0x800
    msr     psp, r0
    movs    r0, #2
    msr     control, r0
    isb

    bl      main

    /* No semihosting host is attached in normal operation on real
       hardware, so unlike the QEMU version there is nothing to exit to:
       park here forever. */
.Lhalt:
    b       .Lhalt

    .thumb_func
Default_Handler:
    b       .

/* -- PendSV: the Cortex-M preemptive-context-switch mechanism -------------
   Standard Cortex-M RTOS pattern: SysTick_Handler (plain takibi, see each
   scheduler-based example) does per-tick bookkeeping then requests a switch
   by setting ICSR.PENDSVSET; PendSV (lowest priority, so it only runs once
   every other pending exception has been handled) is the only place that
   ever touches a task's process stack pointer.

   r0-r3/r12/lr/pc/xPSR are already hardware-stacked onto the current task's
   process stack on exception entry -- this only needs to additionally save
   r4-r11 (the registers the hardware doesn't save), call the takibi-defined
   `fn pendsv_dispatch(current_sp: usize) -> usize` (exact same shape as
   examples/common_qemu/startup.S's irq_dispatch: argument/return both in r0,
   which lines up naturally since stmdb leaves the decremented SP in r0
   already, and bl's return value is also in r0 per AAPCS), then restore
   r4-r11 from the (possibly different) returned frame and switch PSP to it.
   `ldr lr,=0xFFFFFFFD; bx lr` is the standard EXC_RETURN value: return to
   Thread mode, use PSP (no floating-point context -- takibi has no float
   type, so the FPU lazy-stacking bit is irrelevant here). */
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

/* Weak default: every example so far links against this shared startup.S,
   so pendsv_dispatch must resolve even for the ~35 examples that never use
   PendSV at all (harmless: nothing sets PENDSVSET unless a program enables
   SysTick, so this default is simply never called in those cases). Returns
   r0 (the current sp) unchanged, mirroring examples/common_qemu/startup.S's
   `.weak irq_dispatch` default. */
    .weak   pendsv_dispatch
    .thumb_func
pendsv_dispatch:
    bx      lr

/* -- Weak default IRQ handlers, overridable by a takibi `fn NAME()` ------
   Unlike Default_Handler's infinite loop (the right default for a genuine
   fault), these only fire if a program explicitly enabled the corresponding
   interrupt, so a safe default is a plain no-op return, not a hang. */
    .weak   SysTick_Handler
    .thumb_func
SysTick_Handler:
    bx      lr

    .weak   ETH_IRQHandler
    .thumb_func
ETH_IRQHandler:
    bx      lr
