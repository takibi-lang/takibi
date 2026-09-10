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
`oops`; `regs`; `intr`; `sched`; `current`; `vm`; `fds`; `ps`; `wait`;
`proc PID`; `bt [PID|cpu N]`; `trace`; `events`; `xk ADDRESS [COUNT]`;
`xp PHYSICAL [COUNT]`; `xu PID ADDRESS [COUNT]`; `help`; `continue`.
<!-- DDB-COMMAND-INVENTORY-END -->

- `regs`, `intr`, `sched`, `current`: saved CPU, interrupt-entry, scheduler,
  and current-process state.
- `ps`, `proc PID`: bounded process snapshots. A truncated snapshot saying
  `not captured` does not prove that a PID does not exist.
- `wait`: who is waiting for what, derived from the same snapshot. A parent
  blocked collecting a child names that child; UART, network, deadline and
  signal waits are event nodes, because the kernel does not know which future
  process will deliver them and a guess would read as a finding. `awaited=1`
  on the header means something is blocked on the exit of the process that is
  currently running -- the shape a non-preemptible stall takes. A parent whose
  child is not in the snapshot reports `child unknown` rather than attaching
  to whatever now answers to that number, and the trailer counts those.
- `bt [PID|cpu N]`: checked compiler frame chain. Three explicit selections,
  because they are three different questions: bare `bt` is the CPU running the
  debugger, `bt cpu N` is another CPU stopped by DDB's world stop, and
  `bt PID` is a saved non-running process. A process that is Running is
  resolved through the CPU holding it rather than through its saved SP, which
  is historical. `cpu N` refuses in two distinguishable ways -- a CPU that
  never acknowledged the stop is `not stopped here`, and one whose published
  root moved during the read is `root changed during capture`; neither is
  presented as a trace. Any unsupported or damaged boundary stops explicitly
  instead of guessing.
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
