# CPU-local log staging space review

Compared the normal linked QEMU and RPi5 kernels with the
fc86f604c baseline. The workload is ordinary kernel log capture, retained
record publication, UART delivery, and DDB inspection of an unfinished line.
The existing all-CPU log storm verifies record recovery by sequence.

| Boundary | QEMU baseline to candidate | RPi5 baseline to candidate |
| --- | ---: | ---: |
| Text (llvm-size) | 830420 to 830668 B (+248) | 4223760 to 4223992 B (+232) |
| Data (llvm-size) | 4608 to 4616 B (+8) | 5584 to 5592 B (+8) |
| BSS (llvm-size) | 1310720 B unchanged | 1916928 B unchanged |
| Staging array symbol | 2688 B unchanged | 2688 B unchanged |
| Emergency polling array symbol | 4 B added | 4 B added |
| usable_ram_start | 0x40210000 unchanged | 0x7e0000 unchanged |

The normal preexisting fragment, byte, and retained-output paths still
stage into a 672-byte row per CPU. LLVM stack-size records on both targets
show the same 32-byte `uart_putc` and capture entry frames, 48-byte
capture helper frame, 64-byte staging and retention frames, 128-byte
ring write frame, and 96-byte UART line emission frame. These are
individual frames.

The generated capture helper takes two additional AArch64 instructions
on the taken staging path to load the separate polling mode and staging
row. The staging helper still has 67 instructions and the UART line
emission helper's instruction count is unchanged on each target. These
are counts from normal `main.o` disassembly, not hardware cycle or
latency measurements. The functional log storm supplies no isolated timing
measurement for ordinary byte staging.

Normal writers use `CpuHere` to select the staging row. In-kernel DDB copies
scalar state with complete-stop evidence. GDB reads the same debug layout
while stopped externally. The emergency polling bit retains the terminal
fallback and its explicit allowlist entry. The no-authority arm leaves
staging untouched. In both maintained layouts the platform masks the
reported CPU index to two bits and the authority range has four entries,
so that arm is unreachable. A preempt-region identity invariant failure
is a separate fail-stop. Boot resets the current staging row before peers
start. Their untouched rows retain their zeroed BSS values.

Remeasure when the staging layout, polling-mode ownership, or normal log
capture path changes.
