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
3. ~~SRST over the Debug Probe's SWD connector.~~ **RESOLVED (2026-07-25),
   but not via SRST.** Tried for real: OpenOCD's generic `reset halt`
   fails with `bcm2712.cpu0: how to reset?` -- confirms the Debug Probe's
   SWD wiring carries no nSRST line and `bcm2712.cfg` defines no
   BCM2712-specific reset handler, matching community reports found
   during this port's original research. `scripts/rpi5_jtag_reset.sh` now
   reboots the board a different way instead: injects a 2-instruction
   trampoline (`smc #0; b .`) at a fixed unused RAM address and sets
   `x0` to PSCI's `SYSTEM_RESET` function ID (`0x84000009`) before
   resuming -- BCM2712's device tree declares PSCI with method `smc`, and
   TF-A (already confirmed present) implements the standard ARM PSCI
   interface at EL3 regardless of caller EL, the same mechanism Linux's
   own `reboot` uses. Confirmed working for CPU-local restarts:
   reconnects within ~2-3 seconds, lands back in whatever `kernel_2712.img`
   was already resident. (Suggested by another AI the user consulted,
   given full attribution here since the working mechanism came from that
   advice, not this file's own prior research.)
   **CORRECTED same day**: this does NOT reliably reload a DIFFERENT
   `kernel_2712.img` after swapping the SD card's file the way a real
   power cycle does -- confirmed the hard way: swapped from Linux back to
   `jtag_stub.img` (verified 8 bytes on disk), ran this script, and it
   booted Linux again anyway. Use it freely to re-run the SAME image
   (e.g. between `rp1_pcie_smoke` iterations while it stays the stub);
   after changing WHICH file is on the SD card, a real physical power
   cycle is still required.
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

## RP1 PCIe enumeration -- GitHub issue #161

Confirmed via Raspberry Pi's own official "3-pin Debug Connector
Specification" (RP-003139-SP) that this board's single debug connector is
standardized to carry EITHER UART OR SWD, never both -- so simultaneous
SWD debugging and live UART output requires RP1's own, physically
separate `rp1_uart0` (GPIO14/15), which in turn requires bringing up
RP1's PCIe link ourselves. Decided with the user 2026-07-25: pursue this
as its own new milestone, tracked as
https://github.com/takibi-lang/takibi/issues/161.

### Status (2026-07-25 real-hardware session): PCIe link UP, RP1 identifies
### itself; memory-mapped register access still not working

`examples/common_rpi5/pcie.tkb` ports the minimal `pcie-brcmstb.c`
bring-up sequence for BCM2712's third PCIe RC (`pcie2`, attached to RP1).
Progress, all via real-hardware, checkpoint-instrumented bisection
(`examples/rp1_pcie_smoke`, writing a sentinel to a global before each
step so a hang's last-reached step is readable over SWD after
power-cycle recovery -- this technique itself proved essential and is
worth reusing for any future risky bring-up):

- **A real bug found and fixed**: an early version called
  `pcie2_perst_set(true)` immediately after asserting the bridge reset
  (mirroring Linux's own BCM2711-only branch, which does NOT apply to
  BCM2712) -- this HUNG THE BOARD SOLID enough that SWD `halt` itself
  started timing out, recovered only by power-cycling (happened twice
  before being root-caused). `PCIE_MISC_PCIE_CTRL` lives in the same AXI
  register block the bridge reset controls, and that block's own
  register interface is apparently unresponsive while held in reset.
  Fixed by removing that early access entirely (BCM2712 doesn't need it
  -- PERST's hardware POR default already leaves it asserted).
- **A second real gap found and fixed**: BCM2712 needs an MDIO-based PHY
  tuning step (`pcie2_post_setup_bcm2712`, transcribed from Linux's own
  `brcm_pcie_post_setup_bcm2712`) as a genuine PREREQUISITE for link
  training, not optional post-link tuning (confirmed via Linux's own call
  ordering: it runs during `brcm_pcie_setup()`, strictly before
  `brcm_pcie_start_link()`). Without it, every earlier step completed
  cleanly (no hang) but the link never came up. With it: **the link
  reports up** (`PCIE_MISC_PCIE_STATUS`'s DL_ACTIVE+PHYLINKUP bits both
  set) and `pcie2_config_read32(0, 0, 0)` reads back `0x00011de4` --
  vendor `0x1de4` (Raspberry Pi Trading Ltd's own registered PCI vendor
  ID) and device `0x0001` -- a real, correct-looking RP1 identifier, not
  a poison pattern. Note this required bus=0 (RP1 answers there in this
  simple single-device topology), not the bus=1 a standard PCI
  bus-numbering assumption would suggest -- bus=1 only ever returned
  `0xFFFFFFFF`.
- `enable_rp1_uart=1` (an official config.txt setting, per Raspberry
  Pi's own documentation: "firmware initialises RP1 UART0... and doesn't
  reset RP1 before starting the OS") was added to this board's config.txt
  but, tested alone (no PCIe driver code at all), did NOT make
  `rp1_uart0` reachable -- still read `0xDEADDEAD`. Whatever this flag
  does for RP1's own state, it does not appear to leave BCM2712's own
  PCIe RC link trained/usable for a bare-metal payload that skips
  firmware's normal Linux-boot path; left enabled anyway since it may
  still help RP1's own readiness once our own link-up succeeds.
- **Remaining real gap**: even with the link up and RP1 correctly
  identified in config space, a direct memory-mapped read of
  `rp1_uart0`'s FR register (`0x1F00030018`, through the outbound window)
  still returns `0xDEADDEAD`. Most likely cause: RP1's own BAR has not
  been assigned/enabled (real PCI devices don't decode ANY memory-space
  address until the OS/enumerator assigns a BAR and sets the Command
  register's Memory Space Enable bit -- something Linux's own PCI
  subsystem does automatically that nothing does for a bare-metal
  payload). Also unresolved: `pcie2_config_read32` reads at non-zero
  `where` offsets (tried 4 and 0x10) returned the SAME vendor/device ID
  value instead of Command/Status or BAR0 content -- something about how
  `where` maps into the indirect index/data register pair is not yet
  correctly understood. Both are the natural next things to investigate.
- `scripts/rpi5_jtag_reset.sh` was tried for real for the first time
  this session (previously never tested, per Unconfirmed item 3) --
  failed with `bcm2712.cpu0: how to reset?`, confirming the community
  reports found during this port's original research: `bcm2712.cfg`
  needs an explicit `reset_config` line before SRST works over this
  adapter. Manual power-cycling is still required to recover from a hang.

### Status (2026-07-25, continued): outbound window BASE_HI bug fixed,
### RP1 BAR/Command register properly configured, but memory access
### STILL fails -- the config-space `where`-offset mystery WAS resolved

Continuing the same real-hardware session (`scripts/rpi5_jtag_reset.sh`'s
new PSCI-based reset made this MUCH faster to iterate -- see that
script's own header comment, mechanism suggested by another AI the user
separately consulted):

- **The `where`-offset mystery is resolved.** Re-reading
  `brcm_pcie_map_bus()` found the real bug: the INDEX register only ever
  encodes bus/devfn (`where` forced to 0 there); `where` is instead added
  directly to `EXT_CFG_DATA`'s own address (a real windowed region, not a
  single register). An earlier version folded `where` into the index and
  always read/wrote the same fixed `EXT_CFG_DATA` address regardless --
  fixed via `pcie2_config_addr()`, now shared by both
  `pcie2_config_read32`/`pcie2_config_write32`.
- **RP1's Command register showed Memory Space Enable clear (0x0000),
  and BAR0 read back `0xFFFFC000`** -- the classic PCI BAR-size-query
  pattern (implies a 16KB decode window), not a real assigned address.
  Assigned BAR0 to PCI address 0 (matching the outbound window's own
  PCI-side target) and set Command register bits 1 (Memory Space Enable)
  + 2 (Bus Master Enable) -- both writes stuck (BAR0 reads back 0,
  Command reads back 0x0006). **Still no effect on the FR read.**
- **A real, separate bug found and fixed in the outbound window setup
  itself**: `pcie2_outbound_window_setup()` had been computing base/limit
  MB values from the FULL 40-bit `cpu_addr` (`0x1F00000000`) and OR-ing
  them directly into `WIN0_BASE_LIMIT` (a single 32-bit register) --
  silently truncating the result (confirmed by reading the register back
  afterward: `0x0000f000`, not the intended value). `WIN0_BASE_HI`
  (offset `0x4080`) is a SEPARATE register for CPU address bits above 32
  (mirroring `WIN0_HI`'s own split for the PCI-side address) that an
  earlier version never touched at all. Fixed: `WIN0_BASE_HI` now gets
  the real upper bits (`cpu_addr >> 32` = `0x1F`), and `WIN0_BASE_LIMIT`
  is computed from `cpu_addr`'s low 32 bits only. Confirmed via readback
  that all outbound-window registers now hold exactly the intended
  values (`WIN0_LO`/`WIN0_HI`=0, `WIN0_BASE_LIMIT`=0, `WIN0_BASE_HI`=
  `0x1f`) and the link is still up. **Still no effect on the FR read --
  it remains `0xDEADDEAD`.**

So: link up, RP1 correctly identified and its own Command/BAR registers
properly configured, outbound window registers now provably holding the
intended values -- and a direct memory-mapped read of `rp1_uart0`'s FR
register still returns the same poison pattern as before any of this
work started. This means the remaining gap is NOT in anything this file
has touched so far. Leading open hypotheses for a future session (none
yet confirmed): (a) BCM2712's own interconnect/bus-fabric may have a
SEPARATE, chip-level address-routing decision (outside the PCIe RC's own
registers entirely) governing which physical addresses even reach
`pcie2`'s outbound-window logic at all, independent of anything
configured so far; (b) RP1 itself may require more than generic PCI
enumeration to actually respond on the wire -- e.g. a real firmware
upload over the link, matching how some PCIe companion/IO-controller
chips work, which would make `enable_rp1_uart=1`'s documented "firmware
initialises RP1 UART0" behavior an ACTIVE step (loading/kicking RP1's own
firmware), not just leaving PCI state untouched.

### Status (2026-07-25, continued further): Linux-comparison approach
### found and fixed the outbound window size AND the real BAR bug

The suggested next step above -- comparing against a real, working Linux
boot -- is exactly what resolved the remaining gaps. The AP-based SWD
memory read (used throughout this file for `.bss`/plain-RAM addresses)
does NOT work for MMIO registers while Linux's own MMU is active (tried
directly: reads back all-zero, not real values); core-context reads fail
outright (`abort occurred`, physical addresses aren't valid VAs under
Linux's own translation regime). The reliable path instead: SSH into the
running Linux and read registers from userspace directly (`sudo python3`
+ `/dev/mem` for raw MMIO, `sudo lspci -vvv` for RP1's own PCI config
state) -- Linux's own CPU-side access obviously works, sidestepping the
debug-port limitation entirely.

- **Outbound window size was wrong.** Linux's own live
  `WIN0_BASE_LIMIT` is `0xfff00000` (base_mb=0, limit_mb=0xFFF -- the
  full ~4GB window the devicetree's `ranges` property describes), not
  the deliberately-scoped-down 1MB window (base_mb=limit_mb=0) this file
  had been using. Every OTHER register matched Linux's live values
  exactly (`WIN0_LO`/`WIN0_HI`=0, `WIN0_BASE_HI`=`0x1f`) -- strongly
  suggesting `base_mb == limit_mb` encodes a degenerate/zero-sized
  window on this hardware, not an inclusive 1MB range as originally
  assumed. Fixed to match Linux's own full-size window exactly. Also
  found and fixed a smaller `MISC_CTRL` discrepancy the same way: bits
  17/18/21 (part of the burst-size field) were left at their un-set reset
  value; matching Linux's own live `0x263480` fixed that too. **Neither
  fix alone made the FR read succeed.**
- **The real bug, found via `sudo lspci -vvv`**: RP1's Region 1 (BAR1,
  config offset `0x14`) is base `0x1f00000000`, size 4M -- and
  `rp1_uart0` (`0x1F00030000`) falls INSIDE that range. Region 0 (BAR0,
  config offset `0x10`, base `0x1f00410000`, size 16K) is a completely
  different, unrelated window -- `lspci`'s own MSI-X capability entry
  confirms it's specifically the MSI-X vector table/PBA, not general
  register space. **Every earlier attempt this session assigned BAR0**
  (offset `0x10`) to PCI address 0 -- the wrong BAR entirely; BAR1 was
  never touched, left at its own unconfigured/size-query reset state.
  Fixed: `examples/rp1_pcie_smoke` now assigns BAR1 (offset `0x14`), not
  BAR0. Testing this fix on real hardware is in progress as of this
  writing.
- **Also learned the hard way**: `scripts/rpi5_jtag_reset.sh`'s PSCI
  reset does NOT reliably reload a DIFFERENT `kernel_2712.img` after the
  SD card's file is swapped -- see that script's own corrected header
  comment. A real physical power cycle is still required whenever the SD
  card's file actually changes; the PSCI reset is only proven for
  re-running the SAME resident image.

See GitHub issue #161 for tracking.
