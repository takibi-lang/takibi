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
