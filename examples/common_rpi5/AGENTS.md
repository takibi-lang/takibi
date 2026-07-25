# Raspberry Pi 5 (BCM2712) Bare-Metal Bring-Up

## Status (2026-07-25): injection mechanism fully proven on real hardware;
## UART output blocked on a real, substantial new dependency (RP1 PCIe)

`examples/start`'s payload has been successfully injected and run to
completion on real hardware multiple times (confirmed via post-run memory
reads landing exactly on `.Lhalt`, matching `startup.S`'s own compiled
tail sequence byte-for-byte) -- the SWD catch/inject/safety-check mechanism
itself (`scripts/rpi5_jtag_load.sh`, `scripts/rpi5_prepare_sdcard.sh`) is
proven and working. **What is NOT yet working is UART output.** This
directory is a from-scratch port effort, not a copy of a proven mechanism
the way most of this repo's other RPi3 examples are additions to an
already-working target -- follow this repo's usual incremental-verification
process (see the root `AGENTS.md`), and do not wire a `hwcheck-rpi5` target
into `allcheck`/`check` until real UART output has actually been seen.

**The real blocker, confirmed 2026-07-25 through extensive real-hardware
debugging (see "A real bug this port found" and "UART investigation"
below), is architectural, not a bug: this board's single 3-pin debug
connector can carry EITHER UART OR SWD, never both at once** (Raspberry
Pi's own official "3-pin Debug Connector Specification", RP-003139-SP --
this is a hardware-level standard, not something software can route
around). Getting simultaneous SWD debugging and live UART output
therefore requires RP1's own, physically separate GPIO14/15-routed
`rp1_uart0` -- which in turn requires bringing up RP1's PCIe link
ourselves, since Linux's own PCI subsystem is what does this during a
normal OS boot and nothing does it for a bare-metal payload. **Tracked as
GitHub issue #161** -- see "UART investigation" below for the full
evidence trail that led here.

**Real hardware connectivity confirmed 2026-07-25** (read-only
`halt`/`reg pc`/`resume` via `scripts/rpi5_jtag_load.sh`'s own check
pass): OpenOCD connects cleanly over the official Debug Probe
(CMSIS-DAP/SWD) to all four `bcm2712.cpuN` targets. This same check
immediately caught a real bug in the safety logic ported from RPi3 --
see "A real bug this port found" below -- before any actual injection was
attempted, exactly the kind of thing this repo's incremental-verification
process is meant to catch early.

## A real bug this port found: RPi3's "EL2H means safe" check is unsound
## on RPi5, because of VHE

The SD card in the board used for this test carries the same Raspberry Pi
OS image previously used on RPi3B (not yet reflashed with
`jtag_stub.img`), so it was expected to be halted mid-boot or similar --
instead, the read-only check found the core **genuinely executing live
Raspberry Pi OS** at halt time: `current mode: EL2H`, `MMU: enabled,
D-Cache: enabled, I-Cache: enabled`, PC `0xffffd06fcf296448` (a canonical
high AArch64 kernel VA, not a physical/stub address).

`scripts/rpi5_jtag_load.sh`'s original safety check was a direct copy of
RPi3's own "refuse to inject unless halted at EL2H" logic, which relies on
Linux always dropping to EL1 for the kernel proper -- true on BCM2837's
Cortex-A53 (ARMv8.0), which has no VHE support at all. BCM2712's
Cortex-A76 is ARMv8.1+, where VHE (Virtualization Host Extensions) is
mandatory, and a VHE-aware Linux kernel (the modern default when hardware
supports it) runs its WHOLE ordinary kernel at EL2H (`HCR_EL2.E2H=1`)
instead of dropping to EL1 at all. So on this board, EL2H by itself
proves nothing -- a live, genuinely-running Raspberry Pi OS can look
identical to our own bare-metal payload at the exception-level check
alone.

**Fix**: both `scripts/rpi5_jtag_load.sh` and `scripts/rpi5_jtag_reset.sh`
now also require **MMU disabled** (parsed from OpenOCD's own halt report,
which already prints "MMU: enabled"/"MMU: disabled" for aarch64 targets --
no extra register read needed). This works because Stage A's
`startup.S` never calls `mmu_init` for either the jtag_stub or the real
payload (see that file's header comment) -- so anything we ever inject at
this stage always runs with the MMU off, while genuine Raspberry Pi OS
always runs with it on. Re-running the corrected check against the same
live board confirmed it now correctly refuses (`MMU enabled` -> refused,
no write ever issued). **This check will need revisiting once a future
milestone adds `mmu_init` here** (mirroring RPi3's own history), since our
own code would then also show MMU enabled.

`scripts/rpi5_jtag_reset.sh` was NOT run against this live board (unlike
the read-only load-check pass, `reset halt` really does reboot the SoC --
see that script's own updated warning). Actually injecting `examples/start`
still requires flashing `examples/common_rpi5/jtag_stub.img` as this SD
card's `kernel_2712.img` first; that has not happened yet either.

**Root cause, confirmed by reading `scripts/rpi3_prepare_sdcard.sh`**: this
SD card was prepared by dd'ing a stock Raspberry Pi OS image and then
running `rpi3_prepare_sdcard.sh` -- which only ever overwrites `kernel8.img`
and appends RPi3-specific `config.txt` lines (`enable_jtag_gpio=1`,
`dtoverlay=disable-bt`). A modern Raspberry Pi OS boot partition ships its
own real `kernel_2712.img` alongside `kernel8.img` for RPi5 support, and
RPi5's firmware **prefers `kernel_2712.img` over `kernel8.img` whenever
both are present**. So this SD card's real, untouched `kernel_2712.img`
is exactly what an RPi5 boots from it, regardless of `kernel8.img` being
the RPi3 jtag_stub -- fully explaining the live-OS state the connectivity
check found, not a fluke. `scripts/rpi5_prepare_sdcard.sh` (new) is the
RPi5-correct equivalent: overwrites `kernel_2712.img` specifically (backed
up to `kernel_2712.img.orig` first) and appends `os_check=0` (not RPi3's
GPIO-JTAG-specific lines, irrelevant here).

## UART investigation (2026-07-25): wrong address, then a real RP1/PCIe
## dependency, all found via real hardware -- no output yet

With the SD card correctly prepared, injection succeeded cleanly and
repeatably (`scripts/rpi5_jtag_load.sh` catches the stub at `0x80004`,
loads `examples/start/kernel_rpi5.elf`, resumes it) -- confirmed by
reading memory back afterward and finding the core parked at an address
whose surrounding instructions exactly match `startup.S`'s own compiled
`mov x0,#0 / bl main / .Lhalt: wfe / b .Lhalt` tail sequence, i.e. the
whole payload ran to completion. But the UART capture (`cat` on the
Debug Probe's ttyACM device, from this same devcontainer, over
`/dev-host/ttyACM*` -- bind-mounted read-only per `.devcontainer/
devcontainer.json`, confirmed both read and write work over it despite
the `ro` mount) was consistently empty.

Diagnosis proceeded in stages, each ruling out a real candidate cause
rather than guessing:

1. **Capture pipeline itself confirmed working**: sending a real Raspberry
   Pi OS a `\r\n` over this exact path produced a real, correctly-echoed
   shell prompt (`kiwamu@rpi5:~$`). An earlier apparent "0 bytes" result
   against a live, already-logged-in OS was a false alarm two levels deep:
   first a picocom session on the user's own host was competing for the
   same byte stream (serial data isn't broadcast to multiple readers), and
   separately, an idle shell prompt simply has nothing new to send unless
   something (a keypress) provokes a response.
2. **Register readback initially looked consistent, but for the WRONG
   UART**: `uart_init()`'s writes to `0x10_7D001000` (this file's original
   `_uart0`/uart10 target) read back exactly as written (`CR=0x301`,
   `LCRH=0x70`, `FBRD=0`, `FR=0x80` i.e. TXFE/empty) -- real, valid,
   persisting hardware, just not the UART physically wired to the Debug
   Probe's cable.
3. **`dmesg` from a live, currently-running Raspberry Pi OS (reached over
   this exact same cable) gave the decisive answer**: `console=ttyAMA0`,
   and `1f00030000.serial: ttyAMA0 at MMIO 0x1f00030000 ... is a PL011
   AXI` -- i.e. RP1's `rp1_uart0` (PCIe-attached; `raspberrypi/linux`'s
   `rp1.dtsi`, `rp1_uart0: serial@30000`, `reg = <0xc0 0x40030000 0x0
   0x100>`, PCIe-translated to this CPU-side address), NOT BCM2712's own
   `_uart0`/uart10 at `0x10_7D001000` this file originally assumed from
   general Raspberry Pi documentation. `tty` inside that live shell
   confirmed `/dev/ttyAMA0` directly.
4. **RP1's UART clock is PLL-derived, not a static devicetree
   `fixed-clock`** (unlike BCM2712's own `_uart0`), so no frequency could
   be read from a devicetree source directly. `vcgencmd measure_clock
   uart` on the real board reported 44,000,244 Hz, within ~0.5% of
   44,236,800 Hz (44.2368 MHz) -- a well-known standard UART reference
   clock chosen historically because it divides evenly for common baud
   rates. `uart.tkb` was updated to `0x1F00030000`/IBRD=24/FBRD=0
   accordingly, and rebuilt/re-injected -- **still no output**.
5. **Root cause of that remaining silence, confirmed conclusively**: a
   direct real-hardware read of FR (`0x1F00030018`) from our bare-metal
   payload (MMU off, no OS, right after injection) returned `0xDEADDEAD`
   -- a classic PCIe "read failed / unmapped" poison pattern. Also
   confirmed: OpenOCD's own SWD debug-port memory access CANNOT reach this
   address at all (reads return all-zero even while Linux is actively and
   correctly using it) -- a debug-tooling limitation of the AP's own bus
   routing, not evidence about real hardware state; the poison-pattern
   read from our OWN CPU-executed code is the reliable evidence here.
   **RP1's PCIe link/BAR window is not established by firmware (TF-A/
   EEPROM) before handing off to an EL2 payload -- it is Linux's own PCI
   subsystem that enumerates and maps it during a normal OS boot**, which
   our bare-metal code never runs.
6. **Went back to check whether `_uart0`/uart10 (BCM2712-native, no PCIe
   dependency) might still be reachable after all**: edited `cmdline.txt`
   to `console=serial10,115200` (the devicetree alias for `_uart0`) and
   rebooted real Raspberry Pi OS. SSH confirmed the board still booted
   fully, but **no output at all appeared on the same physical Debug
   Probe cable this time** -- conclusively showing this specific board's
   debug connector is wired to RP1's `uart0`, not BCM2712's `uart10`,
   contradicting this file's original assumption (based on general
   Raspberry Pi documentation about why `uart10` exists at all).

**Net result**: the injection mechanism is fully proven; UART output is
blocked on a real, substantial new dependency (RP1 PCIe bring-up) that
Stage A did not anticipate. See "Next steps" below for the options
discussed with the user on 2026-07-25 (chose to keep investigating
`uart10` further before committing to RP1 PCIe work, given the
`cmdline.txt` test above -- that path is now closed on this board, so RP1
PCIe enumeration is the only remaining route to real bare-metal UART
output on this specific hardware).

## Why RPi5, given RPi3 bring-up (issues #140/#153/#154/#156/#157/#158) is
## already extensive and working

The user acquired a Raspberry Pi 5, its official 27W USB-C PD supply, the
official Debug Probe (CMSIS-DAP over SWD), and the official active cooler,
for three concrete reasons: better parts availability than RPi3B, a
PCIe-attached Ethernet path as a potential future subject, and a more
stable debug connection than RPi3's setup. RPi3's own JTAG bring-up notes
(see `examples/common_rpi3/AGENTS.md`) already recorded transient
`Invalid ACK`/`JTAG-DP STICKY ERROR` flakiness on its 6-pin GPIO JTAG header
with a generic FTDI adapter, and separately noted that CMSIS-DAP is not
supported by BCM2837's debug port at all -- moving to a board with a real,
dedicated SWD debug connector was flagged there as a "full board-port
rewrite," not a stability tweak, and this directory is that rewrite,
requested explicitly once the hardware was in hand.

## Sourced facts

Gathered from primary sources (Linux kernel device tree, Trusted Firmware-A
docs, OpenOCD community configs) rather than assumed, since Broadcom does
not publish a public BCM2712 datasheet the way it once did for BCM2835.

- **Debug UART (used by `uart.tkb`) -- CORRECTED, see "UART investigation"
  below**: general Raspberry Pi documentation and the device tree both
  describe BCM2712's own on-die PL011 (`_uart0`/`uart10`/`serial10`,
  physical `0x10_7D001000`, fixed `clk_uart`=9,216,000 Hz) as "The system
  UART", independent of RP1/PCIe, and this file originally assumed it was
  therefore what the physical debug connector carries. **On the real
  board actually used for this port, that assumption was empirically
  wrong**: `console=serial10` produced no output at all on the Debug
  Probe's cable, while `console=serial0` (RP1's `rp1_uart0`, PCIe-attached,
  physical `0x1F00030000`) does. `uart.tkb` now targets `0x1F00030000`
  (IBRD=24/FBRD=0 for ~44.2368MHz uartclk, measured via `vcgencmd
  measure_clock uart`) -- getting output through it requires RP1 PCIe
  enumeration our bare-metal code does not yet do (see "UART
  investigation"). Whether this BCM2712-uart10-vs-RP1-uart0 wiring is
  board-revision-specific or affects every RPi5 is unknown; do not assume
  the original documentation-based claim was entirely wrong, only that it
  does not describe this specific board.
- **EL2 handoff, and why EL2H alone is NOT a safety signal here**:
  Trusted Firmware-A's own RPi5 platform docs
  (`trustedfirmware-a.readthedocs.io/en/latest/plat/rpi5.html`) describe
  their BL31 port as "a minimal BL31 implementation capable of booting
  64-bit EL2 payloads such as Linux and EDK2" -- same handoff level as
  RPi3's GPU firmware. RPi3's own `scripts/rpi3_jtag_load.sh` safety check
  ("refuse to inject unless halted at EL2H") relies on Linux always
  dropping further to EL1 for the kernel proper, which is true on
  BCM2837's Cortex-A53 (ARMv8.0, no VHE). BCM2712's Cortex-A76 is
  ARMv8.1+, where VHE (Virtualization Host Extensions) is mandatory, and a
  VHE-aware kernel runs its WHOLE ordinary kernel at EL2H instead --
  confirmed the hard way (see "A real bug this port found" above): a live
  connectivity test found genuine, running Raspberry Pi OS sitting at
  EL2H. `scripts/rpi5_jtag_load.sh`/`rpi5_jtag_reset.sh` now also require
  MMU disabled, not EL2H alone.
- **GIC-400 (GICv2)**: BCM2712 has a real ARM GIC-400, unlike BCM2837's
  bespoke non-GIC interrupt controller (`examples/common_rpi3/intc.tkb`).
  Distributor at physical `0x10_7FFF9000`, CPU interface at
  `0x10_7FFFA000` (from the same bcm2712.dtsi, `ranges`-translated the same
  way as the UART above). Not used yet (Stage A is polling-only) --
  flagged here because `examples/common_qemu/gic_regs.tkb`/`gic.tkb`
  already implement generic GICv2 register access for QEMU's virt machine
  and may be reusable here with just the base address swapped, once an
  interrupt-driven RPi5 example is attempted.
- **Boot image**: RPi5 firmware defaults to loading `kernel_2712.img` (a
  16K-page-optimized image name introduced alongside BCM2711/BCM2712,
  falling back to `kernel8.img` if absent); `config.txt` needs
  `os_check=0` to skip Raspberry Pi OS's own kernel-image validation for a
  bare-metal payload. Default `armstub` (TF-A BL31, already handing off at
  EL2 per above) does not need overriding for Stage A.
- **Reset config source**: `examples/common_rpi5/bcm2712.cfg` was supplied
  by the user, originally from
  https://www.raspi.jp/2024/03/raspberry-pi-5-hardware-debbuging/, itself a
  derivative of OpenOCD's own `target/bcm2711.cfg` (SPDX
  `GPL-2.0-or-later`, confirmed working there against real hardware).
  Vendored into this repo because upstream OpenOCD 0.12.0 does not ship a
  `bcm2712.cfg` at all.

## What's deliberately NOT ported yet (Stage A scope)

Unlike `examples/common_rpi3/startup.S` (which accreted MMU setup, IRQ/HVC/
EL0 vector handling, and HCR_EL2 routing over many later milestones), this
directory's `startup.S` has none of that yet: no `mmu_init`, no interrupt
unmasking, no HVC/lower-EL vectors -- every exception vector just spins.
Add each piece back only once a concrete example actually needs it, the
same order RPi3 itself was built in. Do not port RPi3's USB host stack
(`usb_dwc2.tkb`/`usb_hub.tkb`/`usb_host.tkb`/`lan9514.tkb`) or its
Ethernet driver at all -- RPi5's Ethernet path is PCIe-attached (via RP1),
architecturally unrelated to RPi3's USB-attached LAN9514, and is its own
future subject if pursued, not a port of the existing driver.

## Explicitly UNCONFIRMED -- check these first if Stage A does not work

1. **`jtag_stub.ld`'s 0x80000 load address.** Assumed by analogy with
   RPi3's own kernel8.img convention; not verified against RPi5 firmware's
   actual default load address for a non-Image-header raw kernel.
2. ~~No GPIO/pinmux step needed for the debug UART.~~ **RESOLVED (was the
   wrong question)** -- see "UART investigation" above: the real blocker
   was a wrong UART address (RP1's `uart0`, not BCM2712's `uart10`), and
   RP1's own uninitialized PCIe link, not a GPIO/pinmux step.
3. **SRST over the Debug Probe's SWD connector.** `scripts/
   rpi5_jtag_reset.sh` attempts a plain `reset halt`; whether the official
   Debug Probe's dedicated connector actually wires a usable SRST line
   (unlike RPi3's 6-pin GPIO header, which has none) is unconfirmed --
   deliberately NOT tested yet against the live board (see "A real bug
   this port found" above: this board can be running a real, in-use
   Raspberry Pi OS session, and `reset halt` really does reboot the SoC,
   unlike the read-only connectivity check). Community reports (Raspberry
   Pi forums) mention needing an explicit `reset_config` line in some
   setups -- do not paper over a failure here by inventing a BCM2712
   watchdog-register address; no primary source for one was found during
   this port's research.
4. **MPIDR_EL1 core-numbering.** Assumed `mpidr_el1 & 3` still yields the
   plain 0-3 core number, same as BCM2837, since BCM2712 is also a single
   quad-core cluster -- not independently verified.

## Identifying the UART device: RPi5's Debug Probe and the STM32 board's
## ST-Link both enumerate as ttyACM*

Once both boards are plugged in for combined STM32+RPi5 testing (the
user's stated plan, retiring RPi3B), `/dev-host/ttyACM0`/`ttyACM1` numbering
is NOT stable across replug/container-recreate, and is shared between two
completely different boards -- confirmed live in this devcontainer
(`/dev-host/serial/by-id/usb-STMicroelectronics_STM32_STLink_...-if02` ->
`ttyACM0`, `usb-Raspberry_Pi_Debug_Probe__CMSIS-DAP__...-if01` -> `ttyACM1`
at the time of writing, but the numbers themselves are not to be relied
upon). `st-info` cannot help distinguish them: it talks to ST-Link probes
directly over USB (libusb), not through a ttyACM node, and does not
recognize the Debug Probe (a different USB vendor ID) at all. Same fix as
`scripts/rpi_uart_dev.sh` already applies to RPi3's own JTAG-probe-vs-console
ambiguity: `scripts/rpi5_uart_dev.sh` resolves the right device by its
`/dev/serial/by-id` label (matching `*Raspberry_Pi_Debug_Probe*`), not by
number. The Makefile's `RPI5_SERIAL_DEV` (same convention as
`STM32_SERIAL_DEV`/`RPI3_SERIAL_DEV`) overrides the auto-detected device if
ever needed.

## Build and try (no `make hwcheck-rpi5` yet -- see Status above)

```
make examples/common_rpi5/jtag_stub.img
# on the host, with the SD card's boot partition mounted:
scripts/rpi5_prepare_sdcard.sh /path/to/mounted/boot/partition
# power-cycle the board, then:
make rpi5-start
```

`scripts/rpi5_prepare_sdcard.sh` -- NOT `rpi3_prepare_sdcard.sh` -- is
required even if this SD card was already run through the RPi3 version;
see "Root cause" above for why overwriting only `kernel8.img` is not
enough on RPi5.

`make rpi5-start` builds `examples/start/kernel_rpi5.elf`, attaches a UART
reader via `scripts/rpi5_uart_dev.sh`'s auto-detected device, then injects
the payload via `scripts/rpi5_jtag_load.sh`. It deliberately does NOT call
`scripts/rpi5_jtag_reset.sh` first (unlike RPi3's equivalent
`rpi3-http-server` target) -- whether `reset halt` even works here is
itself Unconfirmed item 3 above, and folding it into the very first load
attempt would make it unclear which step actually failed. If the board is
not already parked at the stub (e.g. it just booted Raspberry Pi OS
instead), flash the stub and power-cycle by hand first, or try
`scripts/rpi5_jtag_reset.sh` on its own.

## Next steps: RP1 PCIe enumeration -- GitHub issue #161

Confirmed via Raspberry Pi's own official "3-pin Debug Connector
Specification" (RP-003139-SP) that this board's single debug connector is
standardized to carry EITHER UART OR SWD, never both -- so simultaneous
SWD debugging and live UART output requires RP1's own, physically
separate `rp1_uart0` (GPIO14/15), which in turn requires bringing up
RP1's PCIe link ourselves. Decided with the user 2026-07-25: pursue this
as its own new milestone, tracked as
https://github.com/takibi-lang/takibi/issues/161 (host-bridge init, link
training, BAR/ATU window setup -- likely comparable in scope to the RPi3
USB host stack). See that issue for the full scope; update it and this
file together as work proceeds, same as this repo's other multi-session
milestones (issues #153/#154/#156/#157/#158).
