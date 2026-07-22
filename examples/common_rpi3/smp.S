/* Fixed Raspberry Pi 3B secondary-core trampoline shared by SMP examples.

   Keep policy out of this file: it only establishes the privileged per-core
   execution environment Takibi cannot express yet (SP, VBAR_EL2, MMU/cache)
   and enters smp_core_main().  That one Takibi function is also called by
   app_main on core 0, so all four cores choose their own role in .tkb code.
   A returning Takibi entry is parked only as a failsafe. */
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

    /* HCR_EL2 is per-core state.  Route physical IRQ/FIQ to EL2 on every
       secondary just as startup.S does on core 0; otherwise a local timer
       can become pending after DAIF.I is cleared but is still routed toward
       EL1, so an EL2-resident secondary never takes the interrupt. */
    mrs     x0, hcr_el2
    orr     x0, x0, #0x18
    msr     hcr_el2, x0
    isb

    /* Secondary cores are launched from the firmware spin loop with caches
       and MMU disabled.  Core 0 already issued the shareable I-cache
       invalidation after loading this image. */
    ic      ialluis
    dsb     ish
    isb

    adrp    x0, exception_vectors
    add     x0, x0, :lo12:exception_vectors
    msr     vbar_el2, x0
    isb

    /* The three 16KB secondary stacks are contiguous. */
    mrs     x1, mpidr_el1
    and     x1, x1, #3
    sub     x1, x1, #1
    adrp    x0, smp_core1_stack_top
    add     x0, x0, :lo12:smp_core1_stack_top
    add     x0, x0, x1, lsl #14
    mov     sp, x0

    bl      mmu_init_secondary

    /* Mint core 1's CpuOwner at the privileged boundary.  Takibi does not yet
       promote a runtime `id == 1` branch into a static index equality, so the
       one typed secondary needed today has a narrow hook.  Cores 2-3 retain
       policy-free role selection in smp_core_main. */
    mrs     x0, mpidr_el1
    and     x0, x0, #3
    cmp     x0, #1
    b.ne    .Lsmp_untyped_entry
    mov     x0, #1
    bl      smp_core1_boot_main
    b       .Lsmp_returned

.Lsmp_untyped_entry:
    bl      smp_core_main

.Lsmp_returned:
    wfe
    b       .Lsmp_returned

    .weak   smp_core1_boot_main
smp_core1_boot_main:
    b       smp_core_main
