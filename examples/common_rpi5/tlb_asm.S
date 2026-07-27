/* TLB maintenance for examples/vm_page_map's dynamic mapping window on RPi5
   (GitHub issue #67 Stage 2, ported from examples/common_rpi3/tlb_asm.S).

   The ASID-qualified and whole-EL2 operations accompany RPi5's two-root
   address-space port.  EL1&0 maintenance remains separate; these examples
   exercise the EL2 regime on both cores. */
    .section .text
    .align  2

    .global tlb_invalidate_va
    .type   tlb_invalidate_va, %function
tlb_invalidate_va:        /* fn tlb_invalidate_va(va: usize) */
    dsb     ishst
    lsr     x0, x0, #12
    tlbi    vae2is, x0
    adrp    x2, rpi5_el1_regime_active
    add     x2, x2, :lo12:rpi5_el1_regime_active
    ldr     x3, [x2]
    cbz     x3, .Ltlb_va_done
    tlbi    vaae1is, x0
.Ltlb_va_done:
    dsb     ish
    isb
    ret

    .global tlb_invalidate_asid_va
    .type   tlb_invalidate_asid_va, %function
tlb_invalidate_asid_va:   /* fn tlb_invalidate_asid_va(asid: usize, va: usize) */
    dsb     ishst
    lsr     x1, x1, #12
    lsl     x0, x0, #48
    orr     x0, x0, x1
    tlbi    vae2is, x0
    adrp    x2, rpi5_el1_regime_active
    add     x2, x2, :lo12:rpi5_el1_regime_active
    ldr     x3, [x2]
    cbz     x3, .Ltlb_asid_done
    tlbi    vaae1is, x1
.Ltlb_asid_done:
    dsb     ish
    isb
    ret

    .global tlb_invalidate_all_el2
    .type   tlb_invalidate_all_el2, %function
tlb_invalidate_all_el2:
    dsb     ishst
    tlbi    alle2is
    dsb     ish
    isb
    ret

    .global rpi3_code_range_sync
rpi3_code_range_sync:
    add     x1, x0, x1
    bic     x2, x0, #63
.Lcode_clean:
    dc      cvau, x2
    add     x2, x2, #64
    cmp     x2, x1
    b.lo    .Lcode_clean
    dsb     ish
    bic     x2, x0, #63
.Lcode_invalidate:
    ic      ivau, x2
    add     x2, x2, #64
    cmp     x2, x1
    b.lo    .Lcode_invalidate
    dsb     ish
    isb
    ret
