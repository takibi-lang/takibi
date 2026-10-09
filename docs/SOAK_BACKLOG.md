# Soak backlog

Situations that a few-minute `make allcheck` almost never meets, collected
for the continuous soak that will run them against the latest HEAD on
dedicated hardware (GitHub issue #702). One row per situation. This file is
an index: the reasoning and evidence for each row live on its issue.

A soak finds; a deterministic lane closes. A row here is not coverage. When
the soak finds a defect, that defect still gets a lane that opens its window
on every run before its issue closes (#584). The column "Today" says what the
short suite does instead, so the gap between the two stays visible.

Add a row when a lane has to approximate a situation it cannot produce
naturally -- by stopping a core in GDB, setting a flag, or forcing an
ordering -- or when a failure is understood to need hours of load to recur.

| Situation the soak should meet naturally | Today | Issue |
| --- | --- | --- |
| A peer holds the console lock while it keeps running (IRQs masked), and a UART BREAK arrives; DDB must enter and report without that holder stopping | the DDB lane arms `kernel_ddb_console_hold_armed` from GDB and stops the holder at `console_ddb_hold_checkpoint`, so the holder is frozen rather than running | #701 |
| Process churn on four cores: fork, exec, exit and reap interleaving with wait4 and signals, for hours | `kernelcheck-race-window-*-qemu` lanes hold one known window each; the churn itself runs only at natural boundaries | #584 |
| A spread child reaches CPU 0 EL0 late under four-core load while its parent waits on CPU 1, then the real timer makes it leave with no CPU 0 successor | the shared fixture observes the actual timer leave; the missed-arrival negative deliberately keeps CPU 0 closed instead of producing a naturally delayed arrival | #705 |
| A fatal exception interrupts the initiating CPU while it retains VM, process-image or FD pool metadata ownership | the shared boot fixture holds each real pool guard deliberately while a full machine stop queries the diagnostic mint and verifies Busy; it does not cause an actual fault halfway through metadata updates | #637 |
| A completed freelist contention participant returns to its idle loop before the primary disarms the phase under uneven core scheduling | the 678 QEMU overlay delays primary disarm and requires the old secondary loop to fail; the ordinary boot uses the same phase-wide completion bound | #678 |
| A host deschedules a probe participant across the old wall-clock arrival deadline, or a participant keeps ticking without entering its armed probe | the peer-tick QEMU lane masks IRQs during a 750 ms delay before each probe entry; the refusal control suppresses entries while timer interrupts continue | #651 |
| A tick arrives between an earlier measurement and stop acknowledgement, then release is observed before another tick | the resume control forces a pre-stop tick and freezes the later observation at the actual release baseline; reverting the trusted ticket mint must falsely admit resume | #730 |
| A naturally stalled shell under sustained host load retains peer output, XOFF or an incomplete input line | the console GDB lane seeds these states before boot to prove decoding; the load loop reports observed load but does not guarantee a stall or its cause | #679 |
| Four-core process churn reaches a natural ASID wrap while a peer initiates the stop | the shortened QEMU finder jumps the unassigned counter forward at phase two; the seeded GDB lane checks decoding and refusal, not natural wrap timing | #643 |
