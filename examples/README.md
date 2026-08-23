# Takibi examples

`examples/` contains executable proofs for the Takibi language, compiler, and
bare-metal hardware support. These programs range from small syntax fixtures
to schedulers, filesystems, device drivers, TCP/IP servers, and Linux-ABI
experiments.

The standalone Linux-compatible kernel is not an example. It lives under
[`kernel/`](../kernel/README.md) and must not depend on sources in this tree.

## Source layout

Most application directories contain one primary `.tkb` source file whose
header explains the feature it proves. Shared code is separated by platform:

```text
examples/<name>/       one application or focused compiler/hardware fixture
examples/common/       platform-neutral runtime, networking, FAT12, and RTOS
examples/common_qemu/  QEMU virt AArch64 startup and HAL
examples/common_stm32/ STM32F746G-DISCOVERY startup and HAL
examples/common_aarch64/ architecture-neutral AArch64 support
examples/common_rpi5/  Raspberry Pi 5 startup and RP1 platform support
examples/common_rpi3/  legacy Raspberry Pi 3 support
```

Platform-neutral applications expose `app_main()`. A shared Takibi runtime
calls `platform_init()`, `app_main()`, and `platform_shutdown()`, while the
Makefile supplies the appropriate target HAL and minimal startup assembly.

## What the examples cover

Representative groups include:

- language basics: `start`, `hello`, `fibonacci`, `array`, `struct`, `enum`,
  `refined`, `narrow`, `for`, and the `*_suite` programs;
- ownership and VM: `page_pool`, `vm_page_map`, `copy_on_write`,
  `process_vm_smoke`, `el0_smoke`, and `el0_elf_load`;
- scheduling and synchronization: `scheduler`, `preempt`, `semaphore`,
  `condvar`, `msgqueue`, `rtos_demo`, and `chan_rendezvous`;
- networking: `net_echo`, `arp_reply`, `icmp_echo`, `tcp_echo`,
  `http_server`, and `kvs_server`;
- storage: in-memory FAT12, STM32 SDMMC, RPi5 USB Mass Storage, HTTP from
  storage, and persistent RTOS KVS workloads;
- tooling: DWARF/GDB fixtures, optimizer checks, and QEMU or STM32 profiling
  probes.

This is not a fixed catalog. The Makefile is authoritative for which examples
are ported to each target, and each `.tkb` header is authoritative for that
program's current contract.

## Target policy

Maintenance priority is:

1. Raspberry Pi 5: primary real-hardware reference for examples.
2. QEMU/AArch64: deterministic compiler and integration-test reference.
3. STM32F746G-DISCOVERY: compatibility maintenance; existing examples remain
   supported, but new feature growth is not planned.
4. Raspberry Pi 3B: legacy reference outside the freshness policy. See
   [`common_rpi3/AGENTS.md`](common_rpi3/AGENTS.md).

The RPi5 example port reuses architecture-neutral code where practical, but
RP1, STM32, QEMU virt, and RPi3 peripherals keep separate HALs. A target
abstraction is added only when a second concrete implementation needs it.

## Build and test targets

Run these from the repository root, always with `-f examples/Makefile` (never
`cd examples` first -- every target below is a path relative to the repo
root). These targets live in their own Makefile, separate from the root
`Makefile`'s `kernel/` targets, specifically so a plain `make <target>` at
the repo root cannot accidentally run an examples-only check in place of the
intended kernel one -- see the root [`AGENTS.md`](../AGENTS.md)'s Build
Commands section.

### No physical hardware required

```bash
make -f examples/Makefile build          # build the Takibi compiler
make -f examples/Makefile test           # compiler unit tests
make -f examples/Makefile qemubuild      # build maintained QEMU/AArch64 examples
make -f examples/Makefile qemutest       # run QEMU and host-side integration checks
make -f examples/Makefile stm32build     # cross-build all ported STM32 examples
make -f examples/Makefile linuxbuild     # build the Linux/AMD64 userspace examples
make -f examples/Makefile linuxcheck     # run and compare the Linux/AMD64 examples
make -f examples/Makefile optimizercheck # inspect selected generated objects
make -f examples/Makefile check          # langcheck + test + stm32build + qemutest
```

`make -f examples/Makefile check` is the normal hardware-independent regression target. Builds fan
out over all available cores by default; use `make -f examples/Makefile -j1 check` to force serial
recipes.

### Real hardware required

```bash
make -f examples/Makefile hwcheck-stm32          # STM32 UART integration suite, RAM execution
make -f examples/Makefile hwcheck-stm32-net      # STM32 Ethernet and storage network suite
make -f examples/Makefile hwcheck-rpi5           # RPi5 SWD/UART suite
make -f examples/Makefile hwcheck-rpi5-net       # RPi5 Ethernet and USB-backed server suite
make -f examples/Makefile perfcheck              # real-board profiling mechanism smoke tests
make -f examples/Makefile allcheck               # build all targets, then run QEMU + STM32 lanes
```

`make -f examples/Makefile allcheck` requires an STM32 board. It builds all
covered artifacts once, including the historical RPi5 set, then runs the
independent QEMU and STM32 lanes in parallel. Tests sharing the STM32 board
remain serial inside that lane. RPi5 execution is available only through the
explicit `hwcheck-rpi5` and `hwcheck-rpi5-net` targets and is not part of the
routine green guarantee. Raw logs are written under `_build/allcheck-logs/`.

The sustained STM32 KVS concurrency workload is deliberately separate:

```bash
make -f examples/Makefile stress-stm32-kvs-server-sdcard-rtos
```

It can be tuned with `TAKIBI_STRESS_CONCURRENCY`,
`TAKIBI_STRESS_DURATION`, `TAKIBI_STRESS_FIXED_KEY`, and the operation-ratio
variables documented in the Makefile.

### Interactive server conveniences

```bash
make -f examples/Makefile qemu-http-server
make -f examples/Makefile qemu-kvs
make -f examples/Makefile stm32-http-server
make -f examples/Makefile stm32-http-server-sdcard
make -f examples/Makefile stm32-http-server-sdcard-rtos
```

The `qemu-*` targets run under QEMU. The `stm32-*` targets load the selected
server and stream its UART output; they are useful for an interactive browser
demo, while `hwcheck-*` is the reproducible integration suite.

## QEMU/AArch64

QEMU uses the `virt` machine and an AArch64 CPU. `make -f examples/Makefile qemutest` builds each
maintained fixture, boots it, and compares UART or host-observed behavior. The
network examples use the QEMU virtio-net HAL and host-side test scripts.

Start with:

```bash
make -f examples/Makefile qemutest
```

Use the individual `qemu-*` targets when keeping a server alive for manual
inspection. The DWARF regression and CPU-bound PC-sampling profiler also use
QEMU's gdbstub. Network/interrupt-driven programs spend most sampled time in
idle and are not meaningful targets for that CPU-bound profiler.

## STM32F746G-DISCOVERY hardware

### Equipment

- STM32F746G-DISCOVERY board;
- micro-USB cable connected to the on-board ST-LINK port;
- for network tests, an Ethernet cable and a dedicated host NIC;
- for SD-backed tests, the dedicated test SD card.

The devcontainer contains OpenOCD and `stlink-tools`. Confirm probe access:

```bash
st-info --probe
```

The UART device is normally detected automatically. Override an ambiguous
device with, for example:

```bash
STM32_SERIAL_DEV=/dev/ttyACM1 make -f examples/Makefile hwcheck-stm32
```

### UART suite

```bash
make -f examples/Makefile hwcheck-stm32
```

The suite loads test images into RAM and compares captured UART output. It does
not consume flash endurance.

### Ethernet suite and browser demo

The STM32 examples use `192.168.10.2/24` by default. Configure the directly
wired host NIC:

```bash
sudo ip addr add 192.168.10.1/24 dev <interface>
sudo ip link set <interface> up
ETH_TEST_IFACE=<interface> make -f examples/Makefile hwcheck-stm32-net
```

The network checker needs raw-packet privileges. The scripts confine elevated
execution to the host packet checks. For an interactive demo:

```bash
ETH_TEST_IFACE=<interface> make -f examples/Makefile stm32-http-server
```

Open `http://192.168.10.2/`. Ctrl-C stops the UART viewer; the board continues
running until reset or power loss.

`hwcheck-stm32-net` also exercises SD-backed workloads and may rewrite the
dedicated test card. Do not attach media containing valuable data.

## Raspberry Pi 5 example hardware

### Equipment and one-time boot setup

- Raspberry Pi 5 and a Raspberry Pi Debug Probe connected over SWD;
- the Debug Probe UART connected to RP1 UART0 on GPIO14/GPIO15 and ground;
- a Raspberry Pi OS boot SD card prepared with the project's spin stub;
- for network tests, a directly wired Ethernet NIC;
- a dedicated sacrificial USB Mass Storage device.

Build the spin stub, install it on the mounted boot partition outside the
container when necessary, then power-cycle the board:

```bash
make -f examples/Makefile examples/common_rpi5/jtag_stub.img
scripts/rpi5_prepare_sdcard.sh /path/to/mounted/boot/partition
```

The preparation script backs up `kernel_2712.img` once, installs the stub, and
adds `os_check=0`. A warm reset does not reliably reload a changed SD-card
image, so power-cycle after replacing it. Full bring-up rationale and wiring
notes are retained in [`common_rpi5/AGENTS.md`](common_rpi5/AGENTS.md).

### UART suite

```bash
make -f examples/Makefile hwcheck-rpi5
```

The runner resets to the resident stub before each case, injects an ELF into
RAM over SWD, and compares RP1 UART output. The Debug Probe serial interface is
resolved by USB identity rather than unstable `ttyACM` numbering. Override it
when needed:

```bash
RPI5_SERIAL_DEV=/dev/ttyACM1 make -f examples/Makefile hwcheck-rpi5
```

WARNING: storage cases in this suite reformat the attached USB device. Use
only the dedicated sacrificial drive.

### Ethernet suite

The RPi5 examples use `192.168.20.2/24` by default:

```bash
sudo ip addr add 192.168.20.1/24 dev <interface>
sudo ip link set <interface> up
ETH_TEST_IFACE=<interface> make -f examples/Makefile hwcheck-rpi5-net
```

This runs real ARP, ICMP, TCP, HTTP, KVS, and USB-backed persistence checks.
It also rewrites the sacrificial USB device. Use
`make -f examples/Makefile hwcheck-rpi5-net-l2` for the smaller ARP/ICMP-only lane.

Do not run OpenOCD itself with `sudo` inside the devcontainer. USB device
permissions should be fixed at the host/container boundary instead.

## Raspberry Pi 3 legacy target

RPi3 remains available for historical JTAG/UART and LAN9514 USB-Ethernet
coverage:

```bash
make -f examples/Makefile hwcheck-rpi3
make -f examples/Makefile hwcheck-rpi3-net
```

It requires its own SD spin stub, JTAG probe, UART adapter, and sacrificial
storage. New users should start with RPi5. See
[`common_rpi3/AGENTS.md`](common_rpi3/AGENTS.md) for the legacy procedure.

## Additional dependencies

Beyond the compiler dependencies in the top-level README, example workflows
use:

```text
qemu-system-aarch64
llvm-mc-19 and ld.lld-19
gdb-multiarch
mtools
openocd and stlink-tools
Python 3 and host raw-socket access for network checks
```

The maintained versions and USB permissions are already configured by the
repository devcontainer.
