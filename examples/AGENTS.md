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

## TCP/IP stack and bare-metal HTTP server

The TCP/IP stack and bare-metal HTTP server were the first waypoint toward the
standalone kernel. They ran on QEMU/AArch64 and STM32F746G-DISCOVERY and proved
that Takibi could express nontrivial systems code. The ongoing work then moved
from demonstrating runtime behavior to pushing that behavior's error surface
into compile-time refinement and ownership checks.

Network TX is synchronous despite interrupt-driven completion: it sleeps
rather than spins, but retains the caller until DMA finishes. A truly
asynchronous API would need an affine in-flight handle before callers could
safely reuse the buffer.

When a network test flakes, check the harness's readiness assumption before
the protocol implementation. Historical flakes included a real `tcp.tkb` bug,
but more often the host runner started before the kernel or PHY was ready.

## STM32 notes

Hardware bring-up polling still needs bounded timeouts. MDIO busy, MAC reset,
PHY reset and autonegotiation, and RTC initialization poll status bits with no
useful completion interrupt. A disconnected or failed device can otherwise
block forever; add a monotonic deadline and an actionable error result before
growing these drivers.

The shared high-level entry point calls `platform_init`, `app_main`, and
`platform_shutdown`. QEMU hooks are empty, while the STM32 hooks own UART
setup and drain. If another always-on service needs lifecycle work, introduce
an explicit runtime module that composes drivers instead of coupling UART to
an unrelated device.

STM32 Ethernet bring-up established the DMA/device memory-barrier builtins. A
`dsb` is required between publishing a descriptor and kicking poll demand;
volatile `*io` writes alone do not guarantee that the descriptor reached the
DMA engine first. The target-specific `dma_publish`, `dma_consume`, and
`device_fence` lowerings replace the old handwritten assembly workaround.
Cache-aware `dma_prepare_tx`, `dma_prepare_rx`, and `dma_finish_rx` operations
maintain Cortex-M7 cache lines, while indexed linear owners reject premature
or repeated buffer release.

QEMU TCG does not model caches as storage distinct from RAM, so it cannot
reproduce these coherence failures. This was visible in the STM32 FAT storage
harness: OpenOCD injects and extracts the live `disk` array through the debug
port, bypassing the CPU cache just like DMA. Without explicit cache maintenance,
the same test could pass in QEMU and read or dump stale data on hardware.

## Profiling

QEMU gdbstub PC sampling is useful for CPU-bound experiments, but a poor fit
for network and interrupt-driven I/O because idle wait time dominates samples.

The STM32 HTTP+SD+RTOS and KVS+SD+RTOS demos instead use
`takibi --profile-functions`, which emits fixed DWT `CYCCNT` function and call
path tables. `make profile-stm32-http-server-sdcard-rtos` provisions the card,
warms the server, profiles an `/ICON.PNG` request, dumps the tables through
OpenOCD, and writes a FlameGraph-compatible folded stack file under
`_build/takibi_profile/http_server_sdcard_rtos/`.

`make profile-stm32-kvs-server-sdcard-rtos` profiles a KVS PUT and eventual SD
write-back. `TAKIBI_PROFILE_LOAD=stress` drives it with `scripts/kvs_stress.py`.
The reported cycles are inclusive wall-clock time, so blocking paths include
their wait time.

## STM32 tools

STM32 hardware work needs OpenOCD and stlink-tools. OpenOCD provides SWD and
gdbstub access; `st-flash` and `st-info` provide flashing and probe inspection.
USB passthrough is configured in `.devcontainer/devcontainer.json`. The
`hwcheck-stm32` targets need a connected board; `stm32build` does not.

The live QEMU/GDB DWARF fixture is `dwarf_debug/dwarf_debug.tkb`, with expected
output in `dwarf_debug/dwarf_debug.gdb.expected` and its harness in
`scripts/run_qemutest.sh`.
