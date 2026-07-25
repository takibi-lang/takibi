# Raspberry Pi 5 (BCM2712) Bare-Metal Bring-Up

## Status: Stage A (UART hello-world spike), connectivity confirmed, no
## example injected onto real hardware yet

This directory is a from-scratch port effort, not a copy of a proven
mechanism the way most of this repo's other RPi3 examples are additions to
an already-working target. Follow this repo's usual incremental-verification
process (see the root `AGENTS.md`): get Stage A's one example (`start`)
running and UART output visible before adding anything else, and do not
wire a `hwcheck-rpi5` target into `allcheck`/`check` until that has
actually happened.

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

- **Debug UART (used by `uart.tkb`)**: BCM2712 has its own on-die PL011,
  independent of RP1/PCIe, wired directly to the Raspberry Pi 5's dedicated
  3-pin debug connector -- the same cable the Debug Probe's SWD connection
  comes in on. Device tree label `_uart0` in
  `raspberrypi/linux`'s `arch/arm64/boot/dts/broadcom/bcm2712.dtsi`
  (`reg = <0x7d001000 0x200>`, translated through the `soc` node's
  `ranges = <0x7c000000 0x10 0x7c000000 0x04000000>` to physical address
  `0x10_7D001000`), aliased as `uart10`/`serial10` in
  `bcm2712-rpi-5-b.dts` (`uart10: &_uart0 { status = "okay"; };`, comment
  "The system UART"). This is NOT one of the four PL011 instances RP1
  exposes on GPIO14/15 -- those need RP1's PCIe link up first, per
  Raspberry Pi's own forum explanation of why the debug UART exists as a
  separate thing at all. Fixed clock `clk_uart` = 9,216,000 Hz (also from
  bcm2712.dtsi) -- NOT RPi3's 48 MHz. 9216000 / (16 * 115200) = 5.000
  exactly, a suspiciously clean divisor that is itself corroborating
  evidence for this number (Broadcom most likely picked 9.216 MHz
  specifically so that 115200 baud needs no fractional divisor at all).
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
2. **No GPIO/pinmux step needed for the debug UART.** Assumed because it's
   wired to a dedicated connector rather than shared/multiplexed GPIO
   pins the way RPi3's UART0/GPIO14-15 are -- unlike RPi3's `uart.tkb`,
   this port's `uart_init()` does no GPIO alt-function configuration at
   all. If no output appears, this is the first thing to question.
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
# flash examples/common_rpi5/jtag_stub.img as the SD card's kernel_2712.img,
# with config.txt containing: kernel=kernel_2712.img / os_check=0
make rpi5-start
```

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
