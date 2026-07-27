/* RPi5 secondary-core debug trampoline.
   OpenOCD redirects a TF-A-parked secondary (EL3H) here.  It constructs the
   ordinary non-secure AArch64 EL2 context TF-A would normally install for a
   PSCI CPU_ON return, then erets to rpi5_secondary_start.  This file is not
   linked only into SMP kernels; their loader redirects a secondary here. */
    .section .text
    .global rpi5_el3_secondary_trampoline
rpi5_el3_secondary_trampoline:
    msr     DAIFSet, #0xf
    /* GICD_IGROUPR0 is banked for SGI/PPI state and security-controlled.
       TF-A's parked core has CNTP PPI 30 in Group 0; classify it as
       Non-secure Group 1 while this trampoline still executes at EL3. */
    movz    x3, #0x9080
    movk    x3, #0x7fff, lsl #16
    movk    x3, #0x10, lsl #32
    ldr     w4, [x3]
    orr     w4, w4, #(1 << 30)
    str     w4, [x3]
    /* Initialize the banked CPU interface while secure access is still
       available.  TF-A leaves secondary PMR at zero, which masks even a
       pending, enabled PPI after the core enters Non-secure EL2. */
    movz    x3, #0xa000
    movk    x3, #0x7fff, lsl #16
    movk    x3, #0x10, lsl #32
    ldr     w4, [x3]
    orr     w4, w4, #3
    str     w4, [x3]
    mov     w4, #0xff
    str     w4, [x3, #4]
    dsb     sy
    mov     x0, #0x501              /* SCR_EL3: NS | HCE | RW(AArch64) */
    msr     scr_el3, x0
    mov     x0, #0x3c9              /* EL2h, DAIF masked */
    msr     spsr_el3, x0
    adrp    x0, rpi5_secondary_start
    add     x0, x0, :lo12:rpi5_secondary_start
    msr     elr_el3, x0
    isb
    eret
