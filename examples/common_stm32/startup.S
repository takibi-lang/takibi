    .syntax unified
    .thumb

/* -- Vector table (Cortex-M7) -------------------------------------------
   Cortex-M has no analogue of AArch64's VBAR_EL1 + branch-instruction
   table: the CPU auto-loads the initial SP from word 0 and the reset PC
   from word 1 at power-on, and every later exception dispatches through a
   plain function-pointer table entry (no manual all-GPR-save/eret dance
   like examples/common/startup.S's irq_entry -- the hardware auto-stacks
   r0-r3/r12/lr/pc/xPSR on entry). This board boots straight from flash at
   0x08000000, which is also where the vector table must live, so no
   explicit VTOR write is needed. Only Reset is wired to real code here --
   nothing enables an NVIC IRQ yet, so every other vector points at a
   single Default_Handler that just loops. */
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
    .word   Default_Handler     /* PendSV      */
    .word   Default_Handler     /* SysTick     */

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

    /* Zero-initialise BSS (same idea as examples/common/startup.S, same
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

    bl      uart_init
    bl      main

    /* No semihosting host is attached in normal operation on real
       hardware, so unlike the QEMU version there is nothing to exit to:
       park here forever. */
.Lhalt:
    b       .Lhalt

    .thumb_func
Default_Handler:
    b       .
