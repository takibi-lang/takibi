/* RPi5 secondary-core EL2 setup.  The debug loader first enters through
   smp_el3_trampoline.S because TF-A keeps secondaries parked at EL3. */
    .section .text
    .global rpi5_secondary_start
rpi5_secondary_start:
    msr     DAIFSet, #0xf

    mrs     x0, hcr_el2
    orr     x0, x0, #0x18
    msr     hcr_el2, x0
    isb

    adrp    x0, exception_vectors
    add     x0, x0, :lo12:exception_vectors
    msr     vbar_el2, x0
    isb

    mrs     x1, mpidr_el1
    ubfx    x1, x1, #8, #2
    sub     x1, x1, #1
    adrp    x0, smp_core1_stack_top
    add     x0, x0, :lo12:smp_core1_stack_top
    add     x0, x0, x1, lsl #14
    mov     sp, x0

    bl      mmu_init_secondary
    mrs     x0, mpidr_el1
    ubfx    x0, x0, #8, #2
    cmp     x0, #1
    b.ne    .Lsecondary_untyped
    mov     x0, #1
    bl      smp_core1_boot_main
    b       .Lsecondary_park
.Lsecondary_untyped:
    bl      smp_core_main
.Lsecondary_park:
    wfe
    b       .Lsecondary_park

    .weak   smp_core1_boot_main
smp_core1_boot_main:
    b       smp_core_main

/* Compatibility ABI used by the existing shared RPi3 SMP examples. */
    .global rpi3_core_id
rpi3_core_id:
    mrs     x0, mpidr_el1
    ubfx    x0, x0, #8, #2
    ret
