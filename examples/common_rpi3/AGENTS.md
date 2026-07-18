# Raspberry Pi 3B (BCM2837) Bare-Metal Bring-Up

GitHub issue #140. Status: `examples/hello` proven working end to end
(JTAG-injected, "Hello, World!" observed over UART0) -- the only example
ported so far. This is a JTAG-only bring-up: nothing here writes to the
SD card as a real `kernel8.img`; see "Why JTAG injection, not an SD card
kernel" below.

## Hardware

- Board: Raspberry Pi 3B, SoC BCM2837 (quad Cortex-A53, AArch64).
- Peripheral base 0x3F000000 (differs from BCM2835's 0x20000000 and
  BCM2711's 0xFE000000 -- do not reuse this directory's addresses for a
  different Raspberry Pi model).
- JTAG probe: Olimex ARM-USB-TINY-H, wired to GPIO22-27 (the standard
  6-pin ARM JTAG GPIO header: TRST/RTCK/TDO/TCK/TDI/TMS). `config.txt`
  needs `enable_jtag_gpio=1` for these pins to carry JTAG signals.
- `config.txt` also needs `dtoverlay=disable-bt`. On Raspberry Pi 3B,
  UART0 (PL011, the peripheral `uart.tkb` drives) is internally routed
  to the onboard Bluetooth module by default -- GPIO14/15's ALT0 pinmux
  step in `uart_init()` is necessary but not sufficient on its own.
  Confirmed empirically: without this overlay, `uart_init()`'s register
  writes all land exactly as intended (verified by reading GPFSEL1/
  UART0_CR/LCRH/IBRD/FBRD/FR back over JTAG after a run -- FR even
  showed TXFE=1, transmit-complete) yet nothing reached the header pins,
  while a known-good UART cable/port (confirmed working for an actual
  Raspbian login) sat silent; adding this overlay and re-flashing fixed
  it with zero driver changes. This overlay is applied by the GPU
  firmware while processing `config.txt`, before it jumps to
  `kernel8.img` -- confirmed to take effect for this bare-metal stub
  exactly as it would for Linux, even though nothing here ever parses a
  device tree.
- UART: a separate, standalone USB-serial dongle (not the JTAG probe's
  own auxiliary channel) wired to GPIO14 (TXD0)/GPIO15 (RXD0)/GND. See
  "Identifying the right /dev/ttyUSB* device" below -- do not assume a
  fixed `ttyUSB0`/`ttyUSB1` numbering, it is not stable across replug.
- This devcontainer sees both over `/dev-host` (a read-only bind mount
  of the host's `/dev`) -- `/dev-host/ttyUSB*` opens fine O_RDWR despite
  the `ro` mount (same convention the Makefile's `STM32_SERIAL_DEV`
  already relies on, see Makefile's comment next to that variable).

## Identifying the right /dev/ttyUSB* device

`scripts/rpi_uart_dev.sh` resolves this by name, not by number: it scans
`/dev-host/serial/by-id/usb-*`, drops anything whose by-id label
contains `JTAG` (the Olimex probe's own auxiliary UART channel -- a
plain ttyUSB can never carry actual JTAG signaling either way, since
JTAG needs 4 lines (TCK/TMS/TDI/TDO) and a ttyUSB only exposes 2
(TX/RX); openocd talks to the probe over raw USB/libusb, not through any
ttyUSB node), and errors out (rather than guessing) if zero or more than
one candidate remains. Run it to get the live path:
```
scripts/rpi_uart_dev.sh   # -> /dev-host/ttyUSBn
```

## Why JTAG injection, not an SD card kernel

The board's SD card currently runs a full Raspberry Pi OS (Trixie,
arm64 lite) with `enable_jtag_gpio=1` appended to `config.txt` -- Linux
boots normally, JTAG is just also wired up. Injecting a bare-metal
payload's PC/SP directly into a *live* Linux core via JTAG halt+resume
is not safe: confirmed live (read-only `halt`/`reg`/`resume`, see git
history around 2026-07-18) that the running core sits at EL1H with the
MMU and both caches on, executing a kernel virtual address -- our
bare-metal code assumes MMU off and physical==virtual, so resuming into
it with a raw physical PC would fault or corrupt kernel state, not run
cleanly.

STM32's equivalent hardware harness (`scripts/run_hwtest_ram.sh`) avoids
this with `reset halt`: a real hardware reset lands the CPU at a known,
clean vector table before any Flash code has run. That option does not
exist here -- the standard 6-pin Raspberry Pi JTAG GPIO header carries
no system reset line, so OpenOCD's `reset` cannot restart the GPU
firmware's boot sequence (confirmed: `target/bcm2837.cfg` defines no
`reset_config`/SRST handling of its own).

The workaround: `jtag_stub.S`, a standalone 8-byte `wfe`-loop image, is
flashed as the SD card's `kernel8.img` in place of Raspbian. On power-up
the GPU firmware still does its own job (DRAM/clock init) exactly as it
would for a real OS, then jumps to this stub instead of Linux -- core 0
parks in an infinite `wfe` with MMU/caches off and no OS state to
protect. From there, `scripts/rpi3_jtag_load.sh` can safely `halt` and
verify (by checking the halted core's MMU state, see "Load and run"
below) that it caught a bare-metal image and not still-running Raspbian,
before injecting a real payload. **A physical power cycle is required to
reach this state at least once** -- OpenOCD alone cannot get there from
a live Raspbian boot. After that, repeated injections in the same power
cycle are safe without another power cycle (see "Load and run").

## Build

```
make examples/common_rpi3/jtag_stub.img   # SD card kernel8.img (one-time flash)
make examples/hello/kernel_rpi3.elf       # the injected payload
```

`RPI3_TARGET := aarch64-none-elf`, `RPI3_CPU := cortex-a53` (Makefile).
Only `examples/hello` has a build rule so far -- deliberately not folded
into a batch `EXAMPLES`-style list yet (see Makefile's comment at the
Raspberry Pi section); add more one at a time as each is ported and
verified, matching this project's YAGNI stance (see root AGENTS.md).

`jtag_stub.img` is a raw binary (`llvm-objcopy-19 -O binary`), not an
ELF -- the GPU firmware's loader expects a flat binary at a fixed
address (0x80000, `jtag_stub.ld`), not an ELF container.

`examples/hello/kernel_rpi3.elf` loads at 0x200000 (`link.ld`),
deliberately different from the stub's 0x80000, so a JTAG session's
`load_image` target is never the same address the stub itself occupied.

## Preparing the SD card

Only two things on the boot partition are project-specific; everything
else (`bootcode.bin`, `start.elf`, `fixup.dat`, `cmdline.txt`, etc.) is
generic Raspberry Pi firmware already installed by the OS image and is
never touched:

| file | source | action |
|---|---|---|
| `kernel8.img` | `examples/common_rpi3/jtag_stub.img` | overwrite |
| `config.txt` | existing file | append `enable_jtag_gpio=1` and `dtoverlay=disable-bt` |

`scripts/rpi3_prepare_sdcard.sh /path/to/mounted/boot/partition`
automates both steps: backs up the original `kernel8.img` once (to
`kernel8.img.orig`, so restoring Raspbian later is just
`cp kernel8.img.orig kernel8.img`), then overwrites it with a freshly
built `jtag_stub.img`, then appends the two `config.txt` lines only if
not already present (idempotent, safe to re-run). Must run wherever the
SD card is actually mounted -- this devcontainer has no raw SD card
reader access (see "Hardware" above), so in practice that means the
host, not inside this container; the repo checkout is expected to be
reachable from there (e.g. a shared devcontainer workspace bind mount).

## Load and run

```
scripts/rpi3_jtag_load.sh examples/hello/kernel_rpi3.elf
```

Two-pass, both over the same `interface/ftdi/olimex-arm-usb-tiny-h.cfg`
+ `target/bcm2837.cfg`:
1. **Read-only safety check**: `halt`, read `pc` + MMU state, `resume`
   immediately. If the halted core's MMU is not off, the script refuses
   to go further -- it has almost certainly caught still-running
   Raspbian (confirmed always MMU-on), and the board is left running
   exactly as found (this pass never writes anything). This is
   deliberately NOT a narrow PC-range check against `jtag_stub.S`'s
   address alone: a *previous* injected payload's own halt loop is just
   as safe to catch and overwrite (MMU/caches still off, `startup.S`
   never enables them), so one power cycle covers any number of
   subsequent injections in the same session -- this is what makes
   `scripts/run_hwtest_rpi3.sh` (`make hwcheck-rpi3`) practical to run
   more than once without re-flashing/re-power-cycling between examples.
2. **Injection**: only reached if the check above passed. `halt`,
   `load_image` the ELF, set `sp`/`pc` from the ELF's own `stack_top`
   symbol and entry point (via `llvm-nm-19`/`llvm-readelf-19`, not
   hardcoded -- mirrors `scripts/run_hwtest_ram.sh`'s
   `ram_load_and_run_seeded`), `resume`.

Then watch the UART device from "Identifying the right /dev/ttyUSB*
device" above at 115200 baud for the example's output, e.g.:
```
stty -F "$(scripts/rpi_uart_dev.sh)" 115200 raw -echo
cat "$(scripts/rpi_uart_dev.sh)"
```

## Automated integration test (`make hwcheck-rpi3`)

`scripts/run_hwtest_rpi3.sh` (invoked by `make hwcheck-rpi3`) automates
the above into a pass/fail suite, modeled on `scripts/run_hwtest_ram.sh`'s
`read_until_quiet` idle-detection capture (reused verbatim) diffed
against each example's existing `.expected` fixture. NOT part of `make
check`/`make allcheck` -- like `make hwcheck-stm32`, it needs physical
hardware, and unlike it, the very first run in a session additionally
needs the board already power-cycled into `jtag_stub.S` (see "Why JTAG
injection, not an SD card kernel" above); `scripts/run_hwtest_rpi3.sh`
distinguishes that failure mode (JTAG injection itself failing, almost
always the MMU-state check refusing a still-Raspbian board) from an
actual test failure (injection succeeded, UART output didn't match), so
the fix (power-cycle vs. a real bug) is never ambiguous from the output.
Only `examples/hello` is wired in so far -- add one `run_hw_test_rpi3`
line per newly-ported example, matching `RPI3_EXAMPLES` in the Makefile.

## `sudo` warning specific to this devcontainer

**Do not run `openocd` (or anything touching the JTAG/UART USB devices)
with `sudo` inside this devcontainer.** Counter-intuitively, `sudo`
makes JTAG *worse* here: this container's root (via `sudo`) has Docker's
default reduced capability set (confirmed via `/proc/self/status`
`CapEff`), missing `CAP_SYS_ADMIN`/`CAP_SYS_RAWIO` among others, which
was observed to corrupt DAP-level JTAG transactions ("Invalid ACK (7)"
from OpenOCD, reproduced consistently) even though the simpler IDCODE
scan still succeeded. The unprivileged `vscode` user (in the `plugdev`
group, with direct `/dev/bus/usb` access via this project's
`.devcontainer/devcontainer.json` `--device-cgroup-rule`) has strictly
more effective access to the USB device than `sudo` does in this
specific container, and is what every command above assumes.

## UART0 (PL011) driver notes (`uart.tkb`)

- GPIO14/15 must be switched to ALT0 and have their pull-up/down
  explicitly disabled (old-style `GPPUD`/`GPPUDCLK0` handshake -- this
  SoC predates BCM2711's per-pin `GPIO_PUP_PDN_CNTRL_REGn` registers)
  before UART0's own registers do anything useful.
- Baud divisor assumes a 48MHz UART clock (the documented default core
  clock the GPU firmware leaves UART0 running from). If a future example
  changes `core_freq`/PLL settings, this divisor calculation in
  `uart_init()` needs revisiting.
- Deliberately does not define `uart_isr_getc`/`uart_rx_ready`/
  `uart_tx_isr` (unlike `examples/common_qemu/uart.tkb` and
  `examples/common_stm32/uart.tkb`) -- nothing here uses interrupts yet,
  and BCM2837's interrupt controller is the legacy Broadcom one, not the
  GICv2 `examples/common_qemu/gic.tkb` targets. Add these only once a
  real interrupt-driven example needs them.
- `startup.S` defines no exception vector table for the same reason.
