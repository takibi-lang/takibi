# UART DDB

The kernel debugger is resumable, interrupt-safe, allocation-free, bounded, and
polling-only. When UART remains responsive, use it before adding temporary
logging to scheduler, exception, IRQ, VM, or process code.

Start `make kernelsh-qemu` or `make kernelsh-rpi5`, then press Ctrl-T followed
by lowercase `b`. The host sends one finite serial BREAK; this is not
miniterm's indefinite Ctrl-T/Ctrl-B BREAK toggle.

`make kernelcheck-ddb-qemu` exercises both a real UART BREAK and software `brk`
entry. The normal RPi5 integration suite covers physical Debug Probe BREAK,
inspection, and resume.

## First-pass commands

<!-- DDB-COMMAND-INVENTORY-START -->
`oops`; `regs`; `intr`; `sched`; `current`; `vm`; `fds`; `ps`; `proc PID`;
`bt [PID]`; `trace`; `events`; `xk ADDRESS [COUNT]`; `xp PHYSICAL [COUNT]`;
`xu PID ADDRESS [COUNT]`; `help`; `continue`.
<!-- DDB-COMMAND-INVENTORY-END -->

- `regs`, `intr`, `sched`, `current`: saved CPU, interrupt-entry, scheduler,
  and current-process state.
- `ps`, `proc PID`: bounded process snapshots. A truncated snapshot saying
  `not captured` does not prove that a PID does not exist.
- `bt [PID]`: checked compiler frame chain for the interrupted context or a
  captured non-current process. Any unsupported or damaged boundary stops
  explicitly instead of guessing.
- `vm`, `fds`: the captured current process's address space and bounded file
  descriptor view.
- `trace`: the typed process-lifecycle tail.
- `events`: per-CPU diagnostic rings. Read CPUs independently; no total order
  is claimed across CPUs. Treat `damaged` and `overwritten` as evidence loss.
- `xk ADDRESS [COUNT]`, `xp PHYSICAL [COUNT]`, `xu PID ADDRESS [COUNT]`:
  fault-contained reads of managed ordinary RAM. They reject MMIO and non-RAM
  storage rather than performing a potentially state-changing read.
- `oops`: retained crash evidence.
- `continue`: resume through the compiler-defined saved exception frame.
- `help`: current command summary.

Do not call ordinary logging, allocation, locks, sleeping, filesystem, network,
or scheduler operations from DDB's call graph. Do not add an effect exemption
for debugger code. Mutation, general expressions, and an in-kernel GDB remote
protocol are intentionally absent until a concrete case justifies their safety
cost.
