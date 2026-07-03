    .syntax unified
    .thumb
    .align 2

/* -- Memory barrier for the Ethernet DMA descriptor hand-off ---------------

   examples/common_stm32/eth.tkb writes DMA descriptor fields (status/
   control word, buffer pointer, length) into AXI SRAM, then pokes a
   "poll demand" register (ETH_DMATPDR/ETH_DMARPDR) to prompt the Ethernet
   DMA engine to fetch that descriptor immediately. `*io` writes in takibi
   are volatile (the compiler won't reorder or drop them), but volatile
   alone does not guarantee the Cortex-M7's write buffer has actually
   retired the SRAM write to memory before the very next store (the
   poll-demand register write, a different peripheral on a different bus)
   is issued -- the DMA engine can then race ahead and read a stale
   descriptor (OWN bit still 0) before the real update has landed.

   Confirmed empirically during hardware bring-up: an already-"stuck"
   transmit descriptor (DMA never touching it) unstuck itself instantly the
   moment a poll-demand write was reissued after enough real time had
   passed for the earlier SRAM write to settle -- i.e. a missing barrier
   between the descriptor write and the poll-demand kick, not a logic bug
   in the descriptor fields themselves (which were already byte-for-byte
   correct). A `dsb` (Data Synchronization Barrier) forces all prior memory
   accesses to complete before the next instruction executes, which is the
   standard ARM-recommended fix for "write to memory, then kick a DMA
   engine that reads it" sequences. */
    .thumb_func
    .global eth_dsb
eth_dsb:
    dsb
    bx      lr
