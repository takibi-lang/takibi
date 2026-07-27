/* RPi5 secondary-core debug trampoline.
   OpenOCD redirects a TF-A-parked secondary (EL3H) here.  It constructs the
   ordinary non-secure AArch64 EL2 context TF-A would normally install for a
   PSCI CPU_ON return, then erets to rpi5_secondary_start.  This file is not
   linked only into SMP kernels; their loader redirects a secondary here. */
    .section .text
    .global rpi5_el3_secondary_trampoline
rpi5_el3_secondary_trampoline:
    msr     DAIFSet, #0xf
    mov     x0, #0x501              /* SCR_EL3: NS | HCE | RW(AArch64) */
    msr     scr_el3, x0
    mov     x0, #0x3c9              /* EL2h, DAIF masked */
    msr     spsr_el3, x0
    adrp    x0, rpi5_secondary_start
    add     x0, x0, :lo12:rpi5_secondary_start
    msr     elr_el3, x0
    isb
    eret
