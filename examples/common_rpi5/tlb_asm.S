/* TLB maintenance for examples/vm_page_map's dynamic mapping window on RPi5
   (GitHub issue #67 Stage 2, ported from examples/common_rpi3/tlb_asm.S).

   Only tlb_invalidate_va is ported: RPi3's copy also carries
   tlb_invalidate_asid_va, tlb_invalidate_all_el2, and a conditional second
   `tlbi vaae1is` gated on rpi3_el1_regime_active (needed once EL1&0
   translation regimes and a second address-space root exist, for issue
   #158's fork/exec work). None of that applies here yet: RPi5's
   vm_page_map_rpi5.tkb is EL2-only (matching RPi3's OWN original Stage 2
   scope, before issue #158 added the EL1&0-aware variants) and RPi5's
   AddressSpaceOwner state machine (vm_page_map_core_rpi5.tkb) has only one
   real translation root -- l1_table in examples/common_rpi5/mmu.S, never
   switched -- so address_space_activate/deactivate are pure type-state
   bookkeeping with no TTBR0_EL2 write and therefore no need for
   tlb_invalidate_all_el2 either. Add these back if a future RPi5 milestone
   (a second address-space root, or an EL1&0 regime via el1_smoke) needs
   them, mirroring how RPi3 itself only grew this file over time. */
    .section .text
    .align  2

    .global tlb_invalidate_va
    .type   tlb_invalidate_va, %function
tlb_invalidate_va:        /* fn tlb_invalidate_va(va: usize) */
    dsb     ishst
    lsr     x0, x0, #12
    tlbi    vae2is, x0
    dsb     ish
    isb
    ret
