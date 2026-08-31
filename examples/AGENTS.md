# Historical examples

This tree contains historical STM32 and RPi5 code. It records the language and
bare-metal milestones that led to the standalone kernel and `linux_user/`.

## Maintenance scope

This tree is not a target for new feature work. Do not add features here, port
new `kernel/` behavior into it, refactor it, or update it merely to keep parity
with `kernel/`. Modify an example's own `.tkb` or build files only when the user
explicitly asks for that historical artifact to change.

We occasionally run `make -f examples/Makefile allcheck` from the repository
root to test the STM32 side. A genuine compiler regression that breaks existing,
unchanged code should be fixed rather than left to bit-rot. A failure caused by
an intentional maintained-surface change does not by itself justify updating
this tree; report the historical incompatibility instead.

Historical RPi5 hardware execution is opt-in and is not part of the routine
guarantee. Current RPi5 hardware behavior is maintained under `kernel/`.

## Extracting a test

Copy rather than blindly moving when extracting a test into `linux_user/`.
Some files are independently cross-compiled for STM32 or exercised on RPi5
hardware, so removing them could silently drop hardware regression coverage.
Check the relevant hardware-test scripts before removing anything and default
to leaving the original in place when unsure.

## Layout

Each example directory normally contains one `.tkb` file compiled unmodified
for its supported targets. Read its leading comment for what it demonstrates.
The shared HAL directories mirror function names and signatures so one source
file can build for multiple targets:

- `common/` contains platform-independent logic.
- `common_qemu/` contains the QEMU/AArch64 virt HAL and has nested guidance in
  `common_qemu/AGENTS.md`.
- `common_stm32/` contains the STM32F746G-DISCOVERY HAL and has nested guidance
  in `common_stm32/AGENTS.md`.
- `common_rpi5/` contains the historical RPi5 HAL and has nested guidance in
  `common_rpi5/AGENTS.md`.

Files that exist only to resolve a cross-target name collision or shared-file
dependency explain that reason in their own header comment.

## Build commands

Always invoke this Makefile from the repository root; do not change directory
into this tree first.

```bash
make -f examples/Makefile qemutest
make -f examples/Makefile stm32build
make -f examples/Makefile check
make -f examples/Makefile hwcheck-stm32
make -f examples/Makefile hwcheck-stm32-net
make -f examples/Makefile stress-stm32-kvs-server-sdcard-rtos
make -f examples/Makefile hwcheck-rpi5
make -f examples/Makefile hwcheck-rpi5-net
make -f examples/Makefile perfcheck
make -f examples/Makefile allcheck
make -f examples/Makefile clean
```

`allcheck` builds all historical targets, then runs the QEMU and STM32 lanes;
the RPi5 hardware lanes remain opt-in. The RPi5 storage suites reformat the
attached USB drive.

The Makefile enables parallel builds by default. Pass `-j1` when serial output
is more useful for diagnosing a failure.

## Build-system invariants

Every object rule names `_build/default/bin/main.exe` as a normal prerequisite.
This ensures that a real compiler change rebuilds unchanged `.tkb` sources and
prevents stale objects from producing a false pass. Do not replace this with an
order-only dependency on a phony build target.

The root Makefile is the only place that invokes `dune build`. Targets here
forward to the root `build` and `test` targets. Do not add an independent
`dune build`, `dune test`, or `dune exec` invocation to a parallel make graph:
concurrent Dune processes can race on `_build/.lock`, fail nondeterministically,
or hang.

## Target notes

QEMU/AArch64 machine, UART, RTC, GIC, timer, virtio-net, DMA, and test-harness
details live in `common_qemu/AGENTS.md`.

STM32 Cortex-M7 bring-up, USART, RTC, NVIC, scheduling, Ethernet DMA, and
hardware-test details live in `common_stm32/AGENTS.md`.

The TCP/IP progression and the rationale for its incremental construction are
recorded in `HISTORY.md`; each example's header gives its local purpose.

The live QEMU/GDB DWARF fixture is `dwarf_debug/dwarf_debug.tkb`, with expected
output in `dwarf_debug/dwarf_debug.gdb.expected` and its harness in
`scripts/run_qemutest.sh`.
