/* Minimal EL1 stage-1 tables for the standalone RPi5 kernel.
 *
 * Assembly is limited to system-register and TLBI operations Takibi cannot
 * express. Policy (which owned page may be mapped with which permissions)
 * remains in kernel/mm/address_space.tkb.
 */
    .section .text, "ax"
    .global kernel_mmu_init
    .type kernel_mmu_init, %function
kernel_mmu_init:
    adrp    x1, kernel_l1
    add     x1, x1, :lo12:kernel_l1

    /* 0..1GB RAM: Normal WB, inner-shareable, EL1-only RW. */
    mov     x2, #0x705
    str     x2, [x1]

    /* 0x40000000 user window: L1 -> L2 -> L3. */
    adrp    x2, user_l2
    add     x2, x2, :lo12:user_l2
    orr     x2, x2, #3
    str     x2, [x1, #8]
    adrp    x2, user_l3
    add     x2, x2, :lo12:user_l3
    orr     x2, x2, #3
    adrp    x3, user_l2
    add     x3, x3, :lo12:user_l2
    str     x2, [x3]

    /* BCM2712 PCIe/GIC windows at L1[64..65], Device-nGnRnE. */
    mov     x2, #64
.Lbcm_device:
    lsl     x3, x2, #30
    mov     x4, #0x401
    orr     x3, x3, x4
    str     x3, [x1, x2, lsl #3]
    add     x2, x2, #1
    cmp     x2, #66
    b.lo    .Lbcm_device

    /* RP1 outbound PCIe window at L1[124..127], Device-nGnRnE. */
    mov     x2, #124
.Lrp1_device:
    lsl     x3, x2, #30
    mov     x4, #0x401
    orr     x3, x3, x4
    str     x3, [x1, x2, lsl #3]
    add     x2, x2, #1
    cmp     x2, #128
    b.lo    .Lrp1_device

    /* Attr0 Device-nGnRnE; Attr1 Normal WB RA/WA. */
    movz    x0, #0xff00
    msr     mair_el1, x0

    /* 37-bit VA, 40-bit PA, 4KB granule, WB inner-shareable walks,
     * TTBR1 disabled. */
    movz    x0, #0x351b
    orr     x0, x0, #(1 << 23)
    movk    x0, #2, lsl #32
    msr     tcr_el1, x0
    msr     ttbr0_el1, x1
    isb
    tlbi    vmalle1
    dsb     ish
    isb

    mrs     x0, sctlr_el1
    orr     x0, x0, #1
    orr     x0, x0, #(1 << 2)
    orr     x0, x0, #(1 << 12)
    bic     x0, x0, #(1 << 1)
    msr     sctlr_el1, x0
    isb
    ret

/* user_pte_write(index, value): one 4KB PTE in the 2MB user window. */
    .global user_pte_write
    .type user_pte_write, %function
user_pte_write:
    adrp    x2, user_l3
    add     x2, x2, :lo12:user_l3
    str     x1, [x2, x0, lsl #3]
    dsb     ishst
    ret

    .global user_pte_read
    .type user_pte_read, %function
user_pte_read:
    adrp    x1, user_l3
    add     x1, x1, :lo12:user_l3
    ldr     x0, [x1, x0, lsl #3]
    ret

/* user_tlb_invalidate(va): publish one changed leaf descriptor. */
    .global user_tlb_invalidate
    .type user_tlb_invalidate, %function
user_tlb_invalidate:
    lsr     x0, x0, #12
    tlbi    vae1is, x0
    dsb     ish
    isb
    ret

    .section .bss, "aw", %nobits
    .align 12
kernel_l1:
    .zero 4096
    .align 12
user_l2:
    .zero 4096
    .align 12
user_l3:
    .zero 4096
