/* D-cache maintenance for real DMA buffers on RPi5 (GitHub issue #67
   follow-up: RP1's XHCI USB host controllers, examples/rp1_usb_smoke's
   own Command Ring/Event Ring/DCBAA work). Every RPi5 peripheral touched
   before this one (UART, GIC, PCIe config space, the USB Capability/
   Operational registers themselves) is plain CPU-initiated MMIO --
   ordinary loads/stores to Device-nGnRnE memory, no caching involved at
   all. XHCI's own Command Ring/Event Ring/Device Context Base Address
   Array are different in kind: they are ordinary NORMAL WRITE-BACK
   CACHEABLE RAM (examples/common_rpi5/mmu.S's own L1[0] RAM mapping,
   0x705 = AttrIndx 1), read and written by usbhost0/usbhost1 as a REAL
   DMA-capable PCIe bus master, not by the CPU issuing a load/store.

   Whether BCM2712's PCIe root complex / RP1's own upstream DMA path is
   actually cache-coherent with the AP's own caches (many modern SoCs
   support this via SMMU/ACE-Lite snooping) is NOT yet established on
   this board -- rather than assume it works and risk a "no Command
   Completion Event ever arrives" failure that looks identical to a
   dozen OTHER possible XHCI bring-up mistakes, every ring buffer this
   driver hands to the controller is explicitly cleaned (CPU write ->
   real RAM, before ringing a doorbell) or invalidated (real RAM -> CPU
   read, before reading an Event Ring entry the controller just wrote)
   using these two helpers. Cache line size is hardcoded to 64 bytes,
   matching examples/common_rpi3/tlb_asm.S's own rpi3_code_range_sync
   (Cortex-A76, like Cortex-A53, uses a 64-byte D-cache line -- standard
   for this ARMv8 core generation, not re-derived from CTR_EL0 here for
   the same "match established precedent" reasoning that file's own
   comment implies). `dsb sy` (not `dsb ish`), unlike that file's own
   inner-shareable-domain barriers: a PCIe-attached DMA master is not
   guaranteed to be inside the inner-shareable domain the CPU cores
   themselves share, so the full-system barrier is the safe choice for
   DMA-visibility ordering. */
    .section .text
    .align  2

/* void rpi5_dcache_clean_range(usize va, usize len) -- writes back any
   dirty cache lines in [va, va+len) to the Point of Coherency (`dc
   cvac`, not `cvau`'s weaker Point of Unification), so a CPU write made
   before this call is guaranteed visible to a real DMA-capable bus
   master reading the same physical address afterward. Call this AFTER
   writing a buffer the controller is about to read (a TRB, DCBAA entry,
   ERST entry) and BEFORE ringing any doorbell that could make it read
   that memory. */
    .global rpi5_dcache_clean_range
    .type   rpi5_dcache_clean_range, %function
rpi5_dcache_clean_range:
    add     x1, x0, x1
    bic     x2, x0, #63
.Lrpi5_dcache_clean_loop:
    dc      cvac, x2
    add     x2, x2, #64
    cmp     x2, x1
    b.lo    .Lrpi5_dcache_clean_loop
    dsb     sy
    ret

/* void rpi5_dcache_invalidate_range(usize va, usize len) -- clean AND
   invalidate (`dc civac`, not plain `ivac`) any cache lines in
   [va, va+len), so a subsequent CPU read of that physical address is
   guaranteed to see what a real DMA-capable bus master last wrote there
   (not a stale cached copy, and not accidentally losing an unrelated
   dirty line elsewhere in the same cache line by using a destructive
   plain invalidate). Call this AFTER a doorbell/wait that could have let
   the controller write memory (a new Event Ring entry) and BEFORE the
   CPU reads it. */
    .global rpi5_dcache_invalidate_range
    .type   rpi5_dcache_invalidate_range, %function
rpi5_dcache_invalidate_range:
    add     x1, x0, x1
    bic     x2, x0, #63
.Lrpi5_dcache_invalidate_loop:
    dc      civac, x2
    add     x2, x2, #64
    cmp     x2, x1
    b.lo    .Lrpi5_dcache_invalidate_loop
    dsb     sy
    ret

/* void rpi5_dcache_invalidate_only_range(usize va, usize len)
   -- invalidate clean, CPU-read-only DMA receive buffers without writing a
   stale clean cache line back over the device's newly-written bytes. */
    .global rpi5_dcache_invalidate_only_range
    .type   rpi5_dcache_invalidate_only_range, %function
rpi5_dcache_invalidate_only_range:
    add     x1, x0, x1
    bic     x2, x0, #63
.Lrpi5_dcache_invalidate_only_loop:
    dc      ivac, x2
    add     x2, x2, #64
    cmp     x2, x1
    b.lo    .Lrpi5_dcache_invalidate_only_loop
    dsb     sy
    ret
