/* Minimal EL1 stage-1 tables for the standalone RPi5 kernel.
 *
 * Assembly is limited to system-register and TLBI operations Takibi cannot
 * express. Policy (which owned page may be mapped with which permissions)
 * remains in kernel/mm/address_space.tkb.
 */
    .section .text, "ax"
.macro INIT_ROOT l1, l2, l3
    adrp    x1, \l1
    add     x1, x1, :lo12:\l1
    mov     x2, #0x705
    str     x2, [x1]
    adrp    x2, \l2
    add     x2, x2, :lo12:\l2
    orr     x2, x2, #3
    str     x2, [x1, #8]
    adrp    x2, \l3
    add     x2, x2, :lo12:\l3
    orr     x2, x2, #3
    adrp    x3, \l2
    add     x3, x3, :lo12:\l2
    str     x2, [x3]
    mov     x2, #64
1:
    lsl     x3, x2, #30
    mov     x4, #0x401
    orr     x3, x3, x4
    str     x3, [x1, x2, lsl #3]
    add     x2, x2, #1
    cmp     x2, #66
    b.lo    1b
    mov     x2, #124
2:
    lsl     x3, x2, #30
    mov     x4, #0x401
    orr     x3, x3, x4
    str     x3, [x1, x2, lsl #3]
    add     x2, x2, #1
    cmp     x2, #128
    b.lo    2b
.endm

    .global kernel_mmu_init
    .type kernel_mmu_init, %function
kernel_mmu_init:
    INIT_ROOT kernel_l1_0, user_l2_0, user_l3_0
    INIT_ROOT kernel_l1_1, user_l2_1, user_l3_1

    /* Attr0 Device-nGnRnE; Attr1 Normal WB RA/WA. */
    movz    x0, #0xff00
    msr     mair_el1, x0

    /* 37-bit VA, 40-bit PA, 4KB granule, WB inner-shareable walks,
     * TTBR1 disabled. */
    movz    x0, #0x351b
    orr     x0, x0, #(1 << 23)
    movk    x0, #2, lsl #32
    msr     tcr_el1, x0
    adrp    x1, kernel_l1_0
    add     x1, x1, :lo12:kernel_l1_0
    mov     x2, #1
    lsl     x2, x2, #48
    orr     x1, x1, x2
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
    adrp    x2, user_l3_0
    add     x2, x2, :lo12:user_l3_0
    str     x1, [x2, x0, lsl #3]
    dsb     ishst
    ret

    .global user_pte_read
    .type user_pte_read, %function
user_pte_read:
    adrp    x1, user_l3_0
    add     x1, x1, :lo12:user_l3_0
    ldr     x0, [x1, x0, lsl #3]
    ret

/* user_tlb_invalidate(va): publish one changed leaf descriptor. */
    .global user_tlb_invalidate
    .type user_tlb_invalidate, %function
user_tlb_invalidate:
    dsb     ishst
    lsr     x0, x0, #12
    tlbi    vaae1is, x0
    dsb     ish
    isb
    ret

    .global address_space_pte_write
address_space_pte_write: /* fn(slot, index, value) */
    cbnz    x0, .Las_pte_write_1
    adrp    x3, user_l3_0
    add     x3, x3, :lo12:user_l3_0
    b       .Las_pte_write_store
.Las_pte_write_1:
    adrp    x3, user_l3_1
    add     x3, x3, :lo12:user_l3_1
.Las_pte_write_store:
    str     x2, [x3, x1, lsl #3]
    dsb     ishst
    ret

    .global address_space_pte_read
address_space_pte_read: /* fn(slot, index) */
    cbnz    x0, .Las_pte_read_1
    adrp    x2, user_l3_0
    add     x2, x2, :lo12:user_l3_0
    b       .Las_pte_read_load
.Las_pte_read_1:
    adrp    x2, user_l3_1
    add     x2, x2, :lo12:user_l3_1
.Las_pte_read_load:
    ldr     x0, [x2, x1, lsl #3]
    ret

    .global address_space_activate_root
address_space_activate_root: /* fn(slot) */
    cbnz    x0, .Las_activate_1
    adrp    x1, kernel_l1_0
    add     x1, x1, :lo12:kernel_l1_0
    b       .Las_activate_write
.Las_activate_1:
    adrp    x1, kernel_l1_1
    add     x1, x1, :lo12:kernel_l1_1
.Las_activate_write:
    add     x2, x0, #1
    lsl     x2, x2, #48
    orr     x1, x1, x2
    dsb     ish
    msr     ttbr0_el1, x1
    isb
    ret

    .global address_space_tlb_invalidate
address_space_tlb_invalidate: /* fn(slot, va) */
    dsb     ishst
    add     x0, x0, #1
    lsl     x0, x0, #48
    lsr     x1, x1, #12
    orr     x0, x0, x1
    tlbi    vae1is, x0
    dsb     ish
    isb
    ret

    .global address_space_clear_root
address_space_clear_root: /* fn(slot) */
    mov     x4, x0
    cbnz    x0, .Las_clear_1
    adrp    x1, user_l3_0
    add     x1, x1, :lo12:user_l3_0
    b       .Las_clear_loop_start
.Las_clear_1:
    adrp    x1, user_l3_1
    add     x1, x1, :lo12:user_l3_1
.Las_clear_loop_start:
    mov     x2, #0
.Las_clear_loop:
    str     xzr, [x1, x2, lsl #3]
    add     x2, x2, #1
    cmp     x2, #512
    b.lo    .Las_clear_loop
    dsb     ishst
    add     x4, x4, #1
    lsl     x4, x4, #48
    tlbi    aside1is, x4
    dsb     ish
    isb
    ret

    .section .bss, "aw", %nobits
    .align 12
kernel_l1_0:
    .zero 4096
    .align 12
user_l2_0:
    .zero 4096
    .align 12
user_l3_0:
    .zero 4096
    .align 12
kernel_l1_1:
    .zero 4096
    .align 12
user_l2_1:
    .zero 4096
    .align 12
user_l3_1:
    .zero 4096
