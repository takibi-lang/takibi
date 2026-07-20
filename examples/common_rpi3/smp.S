/* Raspberry Pi 3B secondary-core entry for examples/smp_handoff.

   The JTAG loader starts core 0 first and points core 1 here only after the
   primary has built the shared translation tables.  This code establishes
   clean per-core architectural state, installs those tables, and enters the
   Takibi half of the demo on a dedicated stack.

   On completion core 1 disables its caches/MMU and returns to the firmware's
   secondary-core spin loop at 0x7c.  That low address is outside every
   injected payload; it is also where OpenOCD observes core 1 before its first
   launch on this board. */
    .section .text
    .global rpi3_secondary_start
rpi3_secondary_start:
    msr     DAIFSet, #0xf

    mrs     x0, sctlr_el2
    bic     x0, x0, #(1 << 0)
    bic     x0, x0, #(1 << 1)
    bic     x0, x0, #(1 << 2)
    bic     x0, x0, #(1 << 12)
    msr     sctlr_el2, x0
    isb

    /* Core 1 is launched from the firmware spin loop with all caches and the
       MMU disabled (confirmed by OpenOCD).  Core 0 already issued IALLUIS
       before loading this entry.  A set/way D-cache invalidate here faulted
       before VBAR_EL2 could be installed on the first hardware attempt, so
       there is no stale enabled cache state to sweep on this cold secondary. */
    ic      ialluis
    dsb     ish
    isb

    adrp    x0, exception_vectors
    add     x0, x0, :lo12:exception_vectors
    msr     vbar_el2, x0
    isb

    adrp    x0, smp_core1_stack_top
    add     x0, x0, :lo12:smp_core1_stack_top
    mov     sp, x0

    bl      mmu_init_secondary
    bl      smp_secondary_main

    /* The shared set/way sweep faults on this secondary core (both before and
       after SCTLR.C is enabled), so retire this payload's own VA range with
       DC IVAC instead.  No live dirty data remains: core 0 has acknowledged
       and verified the returned buffer before smp_secondary_main returns. */
    dsb     sy
    movz    x0, #0x20, lsl #16       /* injected image base: 0x200000 */
    adrp    x1, stack_top
    add     x1, x1, :lo12:stack_top
.Lsmp_invalidate_range:
    dc      ivac, x0
    add     x0, x0, #64
    cmp     x0, x1
    b.lo    .Lsmp_invalidate_range
    ic      ialluis
    dsb     sy
    isb

    mrs     x0, sctlr_el2
    bic     x0, x0, #(1 << 0)
    bic     x0, x0, #(1 << 2)
    bic     x0, x0, #(1 << 12)
    msr     sctlr_el2, x0
    isb

    mov     x0, #0x7c
    br      x0
