# Raspberry Pi 3B (BCM2837) Bare-Metal Bring-Up

## SMP ownership handoff (issue #6, working baseline)

`examples/smp_handoff` is the first deliberately narrow SMP milestone.  It
starts cores 1-3 with private 16KB stacks and the translation tables core 0
has already built, then transfers one linear `BufferOwner` between cores 0
and 1 through a stable owner
slot protected by the existing `ldaxr`/`stlxr` semaphore.  The corresponding
64-byte, cache-line-aligned static buffer stays in place: core 0 initializes
it, core 1 increments every byte, and core 0 verifies the result after the
same owner returns.  Only the erased ownership authority crosses the mailbox;
the payload is not copied.

The hardware bring-up exposed an A53-specific prerequisite that the page
table's Inner-Shareable attributes do not replace: every participating core
must set `CPUECTLR_EL1.SMPEN` before enabling its D-cache.  Without it the
payload happened to make the core-1-to-core-0 trip, but core 1 never observed
core 0's final mailbox acknowledgement.  `mmu_init` and
`mmu_init_secondary` now set SMPEN before setting `SCTLR_EL2.C`.

The first, unrefined baseline was deliberately committed before enabling
`--forbid-trap`, following the repository-wide baseline-then-hardening rule.
The baseline passed on real
hardware: the complete UART fixture matched, and an immediately following
ordinary single-core `hello` injection also passed.  The desk-side build is `make
examples/smp_handoff/kernel_rpi3.elf`.  Its hardware test is wired into `make
hwcheck-rpi3`; the runner sets `RPI3_SMP_CORES=4` only for this fixture.
The subsequent hardening step enables `--forbid-trap` on its dedicated build
rule and records two protocol-specific negative fixtures: use after send and
double send are both rejected because the sending call consumes the linear
owner.  The buffer accessor's private raw-pointer field-decay remains a
documented trusted implementation detail because Takibi does not yet parse
assignment through an array-valued struct field (`s.field[i] = v`); callers
cannot obtain that pointer and must present the owner token.

The ordinary JTAG loader continues to touch core 0 only.  With
`RPI3_SMP_CORES=4`, it starts core 0 first, waits 200ms for page-table and BSS
initialization, then redirects cores 1-3 from their firmware spin loops to
one fixed `smp.S` trampoline.  The trampoline performs only the privileged
setup Takibi cannot yet express: it chooses the core's private stack, installs
VBAR_EL2 and the shared MMU tables, and calls `smp_core_main`.  Core 0 reaches
that same Takibi function through ordinary `app_main`; role selection and
intentional `interrupt_wait()` parking therefore live in `.tkb`, not assembly.
`startup.S` also dispatches nonzero cores through the same weak secondary hook
for non-JTAG boot paths; only an SMP-linked image overrides it.

Current scope is four started cores, one fixed SPSC owner slot between cores
0 and 1, and one fixed buffer; cores 2 and 3 deliberately park themselves in
Takibi.  There is no generic task launcher, IPI layer, scheduler integration,
allocator, or load balancing.  Missing synchronization is still a runtime
protocol property rather than something the current ownership checker can
express; that gap is an input to the later memory-model work.  Issue #67's
fixed page pool is the next concrete milestone.

GitHub issue #140. Status: 63 examples ported and passing `make
hwcheck-rpi3`/`make hwcheck-rpi3-net` -- every example in the top-level
`EXAMPLES` list EXCEPT
`fatfs` (needs SD-card-shaped
block storage, see "Out of scope: SD-card-storage examples" below).
`net_echo`/`arp_reply`/`icmp_echo`/`tcp_echo`/`http_server`/`kvs_server` are ported and passing on real
hardware, including `net_echo` at the maximum 1514-byte Ethernet frame
size, over the USB host stack this board did not have as of the previous
status line here. Full list:
`start`/`hello`/`print_int`/`print_hex`/`print_ptr`/`mem`/`array`/
`fizzbuzz`/`fibonacci`/`bubblesort`/`ringbuf`/`callstack`/`crc8`/
`djb2`/`bump`/`scheduler`/`struct`/`struct_refined`/`refined`/
`narrow`/`for`/`loop`/`enum`/`nonexhaustive`/`bitops`/`align`/`packed`/
`struct_align`/`const_global`/`sizeof_offsetof`/`slice`/`foreach`/
`int64`/`indexed_view`/`tcp_conn_view`/`klock_guard`/`percpu`/
`affine_escape_via_index`/`align_ptr_proof`/`linear_obligation`/
`tuple_pair`/`field_lease`/`inet_checksum`/`ip_parse`/`tcp_parse`/
`rtc`/`timer`/`echo`/`irq`/`preempt`/`semaphore`/`condvar`/`msgqueue`/
`watchdog`/`rtos_demo`/`chan_rendezvous`/`net_echo`/`arp_reply`/
`icmp_echo`/`tcp_echo`/`http_server`/`kvs_server`. This covers `hwcheck-stm32`'s "plain compute" set
(extended with plain-compute examples STM32 already had but this
board's own list had not picked up yet: `slice`/`foreach`/`int64`/
`indexed_view`/`tcp_conn_view`) plus `rtc`/`timer` (see "RTC" below)
plus the two UART-RX-interrupt examples plus the full
preemptive-scheduler group (see "Interrupts" below) plus eight examples
that had never been ported to ANY real hardware target before,
QEMU-only until now (`klock_guard`/`percpu`/`affine_escape_via_index`/
`align_ptr_proof`/`linear_obligation`/`tuple_pair`/`field_lease` are
all pure compute or compute plus `disable_irq`/`enable_irq` -- no new
HAL work at all; `chan_rendezvous` got the same `rpi3_irq_dispatch`
treatment as `semaphore`/`condvar`/`msgqueue`, since it predates
`examples/common/rtos.tkb` and still carries its own inline
`SchedState`/`irq_dispatch`) plus the three Ethernet examples
(`net_echo`/`arp_reply`/`icmp_echo`) and `tcp_echo` the "USB host stack" section below
covers in full. This is a JTAG-only bring-up: nothing
here writes to the SD card as a real `kernel8.img`; see "Why JTAG
injection, not an SD card kernel" below.

**Issue #93 test-suite batching pilot.** The eight small, side-effect-free
cases `hello`/`print_int`/`print_hex`/`print_ptr`/`mem`/`array`/`struct`/
`struct_refined` now share `examples/basic_suite/kernel_rpi3.elf`.
`scripts/run_hwtest_rpi3.sh` performs one watchdog reset and one JTAG load
for the suite, then splits its marked UART stream and compares every case
against its original `.expected` fixture. The visible per-case PASS/FAIL
count and localization are unchanged; seven resets and seven loads are
removed. `start` deliberately remains standalone as the minimal platform
runtime/init/shutdown integration fixture. Interrupt, scheduler, SMP, USB,
storage, and network cases are not part of this first pilot because their
state and control-flow boundaries need separate treatment.

The next pass expanded the same mechanism substantially. An 18-case
`type_system_suite` covers refinement/layout/integer/ownership/view examples,
and a 14-case `algorithm_suite` covers loops, collections, small algorithms,
and the three pure packet-parser examples. Together with `basic_suite`, 40
logical PASS/FAIL cases now require only three resets and three JTAG loads
instead of 40, saving 37 of each while retaining every original fixture.
The combined address space exposed and fixed only ordinary global-name
collisions plus one real isolation dependency: `packed` had assumed an
uninitialized padding byte would be zero on a fresh stack. It now initializes
that byte explicitly before inspecting the representation, so its result no
longer depends on whether another test previously used the stack.

The redundant UART-only `net_echo` invocation was subsequently removed from
`make hwcheck-rpi3`. The complete frame round-trip test remains in
`make hwcheck-rpi3-net`, matching STM32's current placement; `usb_probe` still
provides the ordinary suite's UART-visible end-to-end USB/LAN9514/PHY bring-up
coverage, so a second reset, JTAG load, and `net_init()` adds no distinct
coverage there.

**Ethernet and USB are required, not optional, for this board** (per
the project owner, 2026-07-19) -- unlike STM32F746G-DISCOVERY's
on-chip Ethernet MAC, BCM2837 has NO on-chip Ethernet at all; its
Ethernet is a SMSC LAN9514 chip wired behind the SoC's internal USB2
hub, reachable only through a full USB host stack (DesignWare Hi-Speed
USB2 OTG controller driver + USB hub enumeration + the LAN9514's own
USB-Ethernet class protocol). Separately, this board's only SD card
slot is already committed to holding `config.txt`/`kernel8.img` for the
JTAG-catch boot path (see "Out of scope: SD-card-storage examples"
below), so `fatfs`-family testing on this board will need USB mass
storage instead of SD. The Ethernet half of the shared USB-host
foundation is complete; the USB Mass Storage block device itself
(GitHub issue #145) is now also complete and proven on real hardware
-- see "USB Mass Storage (issue #145)" below. Porting the `fatfs`-family
examples themselves onto it is the remaining follow-on work.

## Out of scope: SD-card-storage examples

STM32's `fatfs`/`sdcard`/`http_server_sdcard`/`http_server_sdcard_rtos`/
`kvs_server_sdcard_rtos`/`rtos_fatfs_sdcard` (and equivalents) use a
*second*, dedicated SD card wired to a separate SDMMC/SPI peripheral,
purely as block storage -- unrelated to how the board boots. Raspberry
Pi 3B has only one SD card slot, and it is already committed to boot
duty here (`bootcode.bin`/`start.elf`/`fixup.dat`/`config.txt`/
`kernel8.img`, see "Preparing the SD card" below). Porting any
SD-card-storage example to this target would mean sharing that same
physical card between "how the board boots" and "a FAT filesystem the
running example reads/writes" -- a fundamentally different, riskier
arrangement than STM32's two-independent-cards setup, and deliberately
out of scope for this target using the SD card. Do not port these
against the SD card, even once other examples using real
interrupts/timers land -- fatfs-family testing on this board is
expected to use USB mass storage instead. The DWC2/hub foundation now
exists; the remaining work is USB Mass Storage Bulk-Only Transport,
the minimal SCSI command set, and a 512-byte block-device adapter.

## USB host stack (Ethernet milestone)

GitHub issue #140's Ethernet requirement, scoped: DWC2 host controller
+ minimal USB hub bring-up on the LAN9514's internal Ethernet port +
the LAN9514's SMSC95xx-family vendor protocol + a `net_init`/
`net_rx_*`/`net_transmit` HAL matching `examples/common_stm32/eth.tkb`/
`examples/common_qemu/virtio_mmio.tkb`'s existing shape, so
`net_echo.tkb` and siblings run unmodified. USB mass storage is a
deliberate follow-on, not in scope here. **No QEMU/simulation model
exists for any of this** -- unlike every other feature in this project,
each piece below is verified directly on real hardware, one
UART-checkable milestone at a time, before the next starts; see
HISTORY.md's corresponding entries for the full narrative and the plan
file this work followed. Register-level facts throughout are drawn from
public documentation and the `uspi`/Circle bare-metal USB library (R.
Stange, https://github.com/rsta2/uspi -- the established reference
implementation for exactly this SoC+chip combination), not from
anything this project had prior knowledge of.

Confirmed facts, load-bearing for every milestone below:
- LAN9514 = 5-port USB hub with the Ethernet function wired to one
  internal port; the SoC's DWC2 controller has exactly this one device
  on its root port -- every external USB-A port on the board is a
  further downstream hub port of the SAME chip. USB VID:PID =
  `0x0424:0xec00`. No EEPROM on this board, so the MAC address must be
  assigned by software, not read from the chip.
- DWC2 core register base `0x3F980000` (peripheral base `0x3F000000` +
  BCM2835's known `0x980000` USB offset -- the same base-substitution
  pattern already used for UART/VC-controller/QA7 elsewhere in this
  directory). Host register block/channel register layout: see
  `uspi`'s `dwhci.h` (channel stride `0x20`, up to 16 channels).
- USB core interrupt is VC controller **bank 1**, bit 9 (`Enable_IRQs_1`/
  `pending_1`, register `0x3F00B210`/`0x3F00B200`) -- a *different* bank
  than UART0 (bank 2, bit 25, `intc.tkb`). Source: the same
  `irq-bcm2835.c` IRQ table `intc.tkb`'s own header comment already
  cites for UART0.
- **The USB power domain must be enabled via the VideoCore mailbox
  property interface before any DWC2 register does anything
  meaningful** -- a genuinely new prerequisite subsystem, not something
  DWC2 bring-up can skip (see "Milestone 1" below).
- Ethernet test setup already exists: RPi3's Ethernet port is a
  physical point-to-point link to this devcontainer host's `enp5s0`
  (`192.168.20.1/24`). `examples/common_rpi3/netconfig.tkb` uses
  `OUR_IP = 192.168.20.2`, following
  `examples/common_stm32/netconfig.tkb`'s exact established
  point-to-point convention (STM32 uses its own dedicated NIC,
  `enp4s0`/`192.168.10.2`; QEMU uses `192.0.2.1` via SLIRP).

**DMA/cache-coherency decision**: this project's `dma_prepare_tx`/
`dma_prepare_rx`/`dma_finish_rx` compiler builtins (`examples/
common_stm32/eth.tkb`'s existing mechanism) now
lower to a genuine `dc cvac`/`dc ivac` VA-range loop on AArch64 (same
algorithm the retired `cache_asm.S` used by hand, now in
`lib/llvm_gen.ml` itself; issue #146).
`mailbox.tkb`'s `mbox_call`/`usb_dwc2.tkb`'s `dwc2_control_transfer`/
`dwc2_bulk_out`/`dwc2_bulk_in` were migrated to call the standard
builtins directly (their pointer parameters widened to `*align(32) T`,
the builtins' own proof requirement for the invalidate direction --
satisfied trivially everywhere here since every real buffer involved
`ctrl_data_buf`/`ctrl_setup_buf`/`eth_rx_buf`/`eth_tx_buf`/`power_msg`
is already declared `align(64)` or stricter), matching how
`examples/common_stm32/eth.tkb` already used these builtins directly.
`cache_asm.S` and its `dcache_clean_range`/`dcache_invalidate_range`
stubs are retired -- deleted, along with their `Makefile` link wiring --
now that nothing calls them. Verified against the same 58/58
`make hwcheck-rpi3` and 6/6 `make hwcheck-rpi3-net` (including the
maximum 1486-byte payload and the full tcp_echo/http_server/kvs_server
suite) this section's milestones already required.

**Milestone 1 (done): VideoCore mailbox.** `examples/common_rpi3/
mailbox.tkb` (new): MMIO base `0x3F00B880` (peripheral base + BCM2835's
known `0xB880` offset), `mbox_call()`/`mbox_power_on_usb()` (property
tag `0x00028001`, device id 3, state bits `0x3`). Bus-address
translation uses the `0xC0000000 | addr` alias (VideoCore's own L2
cache DISABLED for this buffer) rather than `0x40000000` (L2 cache
enabled) specifically because this project has no way to flush the
GPU's own separate L2 cache from the ARM side -- see `mailbox.tkb`'s
own header comment. New RPi3-only example `examples/usb_probe/
usb_probe.tkb` (no QEMU/STM32 equivalent, same reasoning as
`examples/rtc`/`examples/timer`): prints `mailbox: ok`/`fail`. Passed
on the first real-hardware attempt. 57/57 `make hwcheck-rpi3`.

**Milestone 2 (done): DWC2 core + host port bring-up.**
`examples/common_rpi3/usb_dwc2.tkb` (new): core register base
`0x3F980000` (Core Global CSRs) / `0x3F980400` (Host Global CSRs,
`DWC2_CORE_BASE + 0x400` -- the standard DWC_otg layout, cross-checked
against `uspi`'s own relative offsets: its `HOST_CFG`/`PORT`/channel-block
offsets land exactly on the well-known `HCFG`(0x400)/`HPRT`(0x440)/
`HCCHAR(0)`(0x500) addresses once applied relative to this base).
`dwc2_soft_reset()`/`dwc2_core_init()` (select the built-in UTMI+ PHY,
enable DMA mode)/`dwc2_flush_fifos()`/`dwc2_host_port_power_on()`/
`dwc2_host_port_connected()`/`dwc2_host_port_reset()` -- every polling
loop here uses a bounded iteration count, not an unbounded spin,
deliberately not repeating the gap root `AGENTS.md`'s Known Limitations
flags for STM32's own PHY/MDIO waits; the two places DWC2 itself defines
a fixed settle time (port reset assert/recovery) use a `delay_ms()`
busy-wait built on `read_cntfrq()`/`read_cntpct()` (reused as-is from
`timer_asm.S`, no new assembly stub needed).

`usb_probe.tkb` grew to print the vendor ID register, reset/flush
status, and port connect/status after reset. Passed on the first real
attempt: vendor ID `0x4f54280a` (the expected Synopsys "OT" + version
ASCII-prefixed ID pattern, confirming the register offset), port
detected connected, and after reset the port status
(`0x0000100d`) shows `ENABLE` set -- meaning DWC2's own hardware state
machine found a valid device (the LAN9514, always present on this
board's single root port) and enabled the port on its own, one step
further than milestone 2 set out to prove. 57/57 `make hwcheck-rpi3`;
`make qemutest`/`make stm32build` unaffected (RPi3-only files).

**Milestone 3 (done): control transfers + root-device enumeration.**
`usb_dwc2.tkb` grew host-channel programming (channel register block at
`DWC2_HOST_BASE + 0x100 + chan*0x20`, stride/bit layout per `uspi`'s
`dwhci.h`) and the standard 3-stage control-transfer state machine
(SETUP PID 3 / data stage starting DATA1 / status stage opposite the
data direction, IN when there is no data stage). `usb_probe` runs the
canonical enumeration: GET_DESCRIPTOR(8 bytes, addr 0, max-packet 8) ->
learn `bMaxPacketSize0` (64) -> SET_ADDRESS(1) -> full 18-byte
descriptor at the new address. Result: VID:PID `0424:9514`, class
`0x09` -- the LAN9514's HUB function, not the `0424:ec00` Ethernet
function the plan originally predicted at this stage: the root-port
device is the hub; `ec00` is the Ethernet function device that will
only appear behind the hub's internal port during milestone 4's
second-level enumeration. Re-running the whole suite without a chip
reset also proved re-injection idempotency: enumeration succeeds even
when the previous run left the device configured at address 1 (the
fresh soft reset + port reset returns it to address 0 every run).

This milestone was the hard one -- persistent `HCINT.XACT_ERROR` on
every transfer across many attempts. Fixed by a BATCH of changes
applied together (root cause not isolated to a single one; ablating on
real hardware was judged not worth the JTAG cycles): (1) completion
detection redesigned to wait for `HCINT.HALTED` and then classify the
accompanying bits, u-boot/CSUD-style, instead of aborting on the first
latched `XACT_ERROR` -- in buffer-DMA mode the core retries failed
transactions internally (3-strikes) and error bits latch per-ATTEMPT,
so first-error-wins aborts transfers the hardware would have finished;
timeout path force-halts the channel (`CHDIS`) so it stays reusable;
(2) `GUSBCFG.ForceHostMode` + the Synopsys-documented 25ms mode-settle
wait, plus explicit `PHYSEL_FS` (bit 6) clear -- both inherited-state
hazards; (3) uspi's BCM-specific AHB tuning (`WAIT_AXI_WRITES` set, AXI
burst field zeroed). Also in place from the failed attempts, all
individually insufficient but all kept as correct: `PCGCCTL = 0`
(PHY clock un-gating), explicit FIFO partition programming
(1024/1024/1024 words), `HCCHAR.MultiCnt = 1`, VC bus-address
translation on `HCDMA` (same `0xC0000000` alias as the mailbox),
explicit `HCSPLT = 0`, `AHB_IDLE` polling after soft reset. Diagnostics
that localized the problem and stay in the fixture as permanent
liveness checks: `GINTSTS.CurMod` ("mode: host") and an HFNUM
frame-counter delta ("sof: running"). 57/57 `make hwcheck-rpi3`; no
shared files touched.

**Milestone 4 (done): minimal hub driver + Ethernet-function
enumeration.** `examples/common_rpi3/usb_hub.tkb` (new): just enough of
USB 2.0 chapter 11 -- hub descriptor read (type `0x29`, `bNbrPorts`),
`SET_PORT_FEATURE(PORT_POWER/PORT_RESET)`, `GET_PORT_STATUS`,
change-bit clears -- to power/reset the LAN9514's ports; port numbers
are parameters throughout so a future mass-storage milestone can reuse
it against an external port unchanged. No hotplug polling, no
split-transaction support for FS/LS devices behind the hub (YAGNI: the
one target device is high-speed and permanently attached). Protocol
encodings cross-checked against U-Boot's `common/usb_hub.c` (the
closest-in-shape polling implementation; per the licensing-hygiene
discussion, structural references prefer BSD-licensed NetBSD/OpenBSD
sources where code shape rather than protocol facts is borrowed).
Result: hub reports 5 ports; port 1 has a high-speed device (speed
bits read AFTER port reset -- they are only valid once the port is
enabled, a pre-reset read reports full-speed defaults); enumerated at
address 2 as VID:PID `0424:ec00` -- the Ethernet function, exactly as
milestone 3's corrected prediction expected.

One diagnosis-by-hardware round-trip along the way:
`SET_CONFIGURATION` (standard request 9) was originally missing
entirely. The hub tolerated a class GET_DESCRIPTOR while still in
Address state (returned its port count fine) but reported every port
as empty until configured -- spec-permitted behavior for any
class-specific functionality before the Configured state. Lesson
recorded in `dwc2_set_configuration`'s own comment. 57/57
`make hwcheck-rpi3`.

**Milestone 5 (done): LAN9514 vendor protocol + PHY link.**
`examples/common_rpi3/lan9514.tkb` (new): the chip has no
memory-mapped registers at all -- every access is a USB vendor-specific
control transfer (`bRequest` `0xA0` write / `0xA1` read, `wIndex` =
register offset, 4-byte little-endian data stage) to the Ethernet
FUNCTION device milestone 4 found behind the hub. Register map/bit
layout cross-checked between NetBSD's `sys/dev/usb/if_smscreg.h`
(BSD-licensed, preferred as the structural reference) and Linux's
`drivers/net/usb/smsc95xx.c` (protocol facts only): `HW_CFG` lite
reset -> `PM_CTRL` PHY reset -> software MAC assignment via
`ADDRL`/`ADDRH` (this board has no EEPROM, confirmed earlier -- a
locally-administered address, `02:00:20:00:00:02`, the same pattern
`examples/common_stm32/netconfig.tkb`'s own `OUR_MAC` already uses) ->
PHY autonegotiation through the `MII_ADDR`/`MII_DATA` bridge registers
(the LAN95xx family's internal PHY is always MII address 1) -- same
IEEE 802.3 clause-22 register set `eth.tkb` already drives on the
STM32's LAN8742A, only the transport differs. Every register poll
(lite reset, PHY reset, MII busy, BMCR reset, link-up) is bounded, none
exceeding a few seconds.

This is the first milestone whose success genuinely depends on the
physical Ethernet cable, not just the board itself: `usb_probe` now
autonegotiates and links up against this devcontainer's own `enp5s0`
(see the point-to-point wiring note above), confirmed with `eth id:
0x0000ec00` (`ID_REV`'s upper half mirrors the USB PID, a free
consistency check) and `eth link: up`. Real hardware timing exposed the
SAME idle-quiet-capture gotcha `rtc`/`timer` hit long ago, worse here:
`lan9514_wait_link()`'s bounded poll can genuinely pause up to 5s with
zero UART output while autonegotiation completes, longer than the
capture harness's default quiet threshold -- fixed the same way, a
generous per-test override (20s max / 7s quiet) on this one
`run_hw_test_rpi3` call. 57/57 `make hwcheck-rpi3`; `make
qemutest`/`make stm32build` unaffected (RPi3-only files).

**Milestone 6 (done): bulk data path + `net_init` HAL parity.**
`examples/common_rpi3/eth.tkb` (new) consolidates the whole chain
milestones 1-5 proved independently (mailbox -> DWC2 -> hub -> LAN9514)
behind the exact `net_init`/`net_rx_wait`/`net_rx_acquire`/`net_rx_len`/
`net_rx_frame`/`net_rx_release`/`net_transmit`/`net_tx_complete`/
`net_rx_finish`/`net_read_mac` API `examples/common_stm32/eth.tkb`/
`examples/common_qemu/virtio_mmio.tkb` already expose -- so
`examples/net_echo/net_echo.tkb` compiles and runs against it
completely unmodified. `examples/common_rpi3/netconfig.tkb` (new):
`OUR_IP = 192.168.20.2`, a locally-administered `OUR_MAC` (this board
has no EEPROM). `dwc2_find_bulk_endpoints()` (`usb_dwc2.tkb`) parses
the config descriptor for the Ethernet function's own bulk IN/OUT
endpoint numbers and max-packet sizes; `dwc2_bulk_in`/`dwc2_bulk_out`
add persistent per-endpoint DATA0/DATA1 toggle tracking (the DWC2 core
advances HCTSIZ.PID within one buffer-DMA channel activation; software
must preserve its final value for the next activation) and STALL
recovery via `CLEAR_FEATURE(ENDPOINT_HALT)`.

Architectural note: unlike `eth.tkb`/`virtio_mmio.tkb`'s real DMA
descriptor rings with interrupt-driven completion, USB bulk transfers
here are synchronous (`dwc2_channel_transfer` busy-waits per call) --
this driver uses a single fixed RX buffer and TX buffer (`desc` is
always 0) rather than a multi-descriptor pool; `net_transmit()`
performs the actual write synchronously, so `net_tx_complete()` has
nothing further to wait for. The linear/affine ownership types still
enforce the same "one CPU-owned RX frame, one in-flight TX" discipline
the API contract promises.

Two real bugs found via `examples/net_echo/net_echo.tkb` +
`scripts/eth_net_echo_test.py` against this devcontainer's `enp5s0`:
- **Bulk endpoints need their OWN max-packet size, not ep0's.** Using
  the control endpoint's 64-byte max packet for bulk transfers (both
  are high-speed, but bulk uses 512) produced a bizarre-looking
  "successful zero-byte transfer" on every bulk IN attempt -- fixed by
  reading `wMaxPacketSize` from each bulk endpoint's own descriptor.
- **Bulk DATA toggles advance per USB packet, not per whole transfer.**
  The first implementation unconditionally flipped its saved PID once
  after every successful bulk call. That is correct only for an odd
  packet count. A 534-byte transfer uses two 512-byte bulk packets, so
  the device correctly kept the same next PID while software flipped
  it; the following transfer then started out of phase. Linux mainline
  and Raspberry Pi's production `dwc_otg` driver both save the final
  HCTSIZ.PID, U-Boot's `wait_for_chhltd()` does the same, and USPi/Circle
  advance their endpoint PID only when the actual packet count is odd.
  `dwc2_channel_transfer()` now captures the hardware-updated PID at
  every halt and both bulk wrappers reuse it. The apparent large-frame
  STALL limit was a sequence effect after the first even-packet frame,
  not a LAN9514 transfer-size limit: the unchanged real-hardware test
  now echoes all 6 payload sizes, including 1000 and the maximum 1486
  bytes.

New `make hwcheck-rpi3-net` (`scripts/run_hwtest_rpi3_net.sh`) -- originally
the network-functional counterpart to `hwcheck-rpi3`'s UART-only net_echo
bring-up check, split out exactly the way `hwcheck-stm32`/
`hwcheck-stm32-net` already are and for the same reason (network tests
need CAP_NET_RAW + a physical cable, not just JTAG+UART, so they stay
out of `make check`/`make allcheck`). Mirrors `run_hwtest_net_ram.sh`'s
shape, reusing `scripts/eth_net_echo_test.py`/`eth_arp_reply_test.py`/
`eth_icmp_echo_test.py`/`eth_tcp_echo_test.py`/
`eth_http_server_test.py`/`eth_kvs_server_test.py` against `enp5s0`.
Real fixes needed along the
way, all worth remembering for any future sudo+network test script in
this repo:
- `sudo` resets the environment by default, so any env var a test
  script needs must be passed as part of the invoked command (`sudo
  ETH_TEST_IFACE=... python3 ...`), not just exported in the wrapping
  shell script -- omitting this made the first attempt silently fall
  back to STM32's own `enp4s0`/`192.168.10.x`/MAC and produced a
  100%-fail run indistinguishable at first glance from a genuine board
  bug.
- This board's `net_init()` (full USB enumeration, several real
  seconds) is measurably slower than STM32's MDIO-only link bring-up,
  so unlike `run_hwtest_net_ram.sh` (whose own comment says no fixed
  sleep is needed) this script needs an explicit settle sleep after the
  JTAG load -- the per-frame retry budget alone was not enough.
- `eth_arp_reply_test.py`/`eth_icmp_echo_test.py` hardcoded STM32's own
  subnet (`192.168.10.x`) and MAC (`00:80:E1:00:00:00`) as plain
  constants, unlike `eth_net_echo_test.py`'s already-env-var-driven
  `ETH_TEST_IFACE` -- generalized both to `ETH_TEST_SUBNET`/
  `ETH_TEST_MAC` env vars (defaulting to STM32's existing values, so
  its own invocation needs no change), with `run_hwtest_rpi3_net.sh`
  setting both to this board's own values
  (`192.168.20`/`02:00:20:00:00:02`) by default.
- `scripts/rpi3_jtag_load.sh` (JTAG) never runs under `sudo` in this
  script -- only the raw-socket Python test does, the same privilege
  separation this document's own "sudo warning" section already
  requires for this devcontainer's USB-based JTAG/UART access.

58/58 `make hwcheck-rpi3` (UART-only checks); `make hwcheck-rpi3-net`
passes all six examples, with `net_echo` at 6/6 payload sizes plus
complete `arp_reply`/`icmp_echo`/`tcp_echo`/`http_server`/`kvs_server`
checks. `make qemutest` (132/132) and
`make stm32build` unaffected.

**Milestone 7**: `arp_reply`/`icmp_echo`/`tcp_echo`/`http_server`/`kvs_server` ported and
passing on real hardware, and the bulk-OUT STALL is now root-caused and
fixed (see above). The unchanged shared `tcp_echo.tkb` passes its full
real-link sequence: rejection cases, TCP-options SYN, handshake, data
echo, close, and reconnect. The unchanged shared `http_server.tkb` also
passes two sequential requests through the host's real TCP/IP stack,
including cold ARP resolution and the response-counter increment.
The unchanged shared `kvs_server.tkb` passes set/get/overwrite/delete,
parser errors, full-table/list, and tombstone-reuse tests. The three
requested application ports are therefore complete. Their shared
application sources already build under `--forbid-trap` in the existing
QEMU/STM32 rules. The separate RPi3 baseline-to-hardened pass is now
complete too: every RPi3 compile group uses `RPI3_TAKIBI_FLAGS :=
--forbid-trap`, covering all 63 examples and every `.tkb` HAL file pulled
into them. Update this section (and HISTORY.md, and issue #140) after each
further step, per this project's established cadence -- do not batch
documentation to the end.

The hardening pass found six bounds checks, all in
`dwc2_find_bulk_endpoints()`'s walk over the fixed 64-byte
`ctrl_data_buf`. The code checked offsets only against the USB device's
runtime `wTotalLength`; that is not proof of the real destination
capacity and a malformed descriptor could therefore drive an OOB read.
The parser now separately requires the mutable cursor to be within the
literal buffer capacity and snapshots it as `min(offset, 62)`, carrying
the proven range through each `off + N` endpoint-field access. No raw
pointer or `unsafe` bypass was introduced. A forced rebuild of every
RPi3 kernel succeeds under `--forbid-trap`; the full six-example network
hardware suite also passes unchanged.

## USB Mass Storage (issue #145)

The deliberate follow-on the "USB host stack" section above always
pointed at: USB Mass Storage Bulk-Only Transport (BOT) + the minimal
SCSI-10 command set + a 512-byte block-device adapter, so `fatfs`-family
examples can use a real USB flash drive as their block storage on this
board (the SD card slot stays reserved for boot, see "Out of scope:
SD-card-storage examples" above). New files: `examples/common_rpi3/
usb_msc.tkb` (the driver) and `examples/usb_msc_probe/usb_msc_probe.tkb`
(RPi3-only diagnostic, no QEMU/STM32 equivalent, same reasoning as
`usb_probe`). No QEMU/simulation model exists for this either -- verified
directly on real hardware, same as every other USB milestone in this
directory.

**Enumeration reuses the Ethernet milestone's root-hub-port-walk
unmodified** (`usb_dwc2.tkb`/`usb_hub.tkb`, no changes needed beyond one
addition below) -- the only difference is WHICH device `usb_msc.tkb`
looks for: any connected port whose device is NOT the LAN9514's own
fixed `0424:ec00` internal Ethernet function, rather than that function
specifically. This finds a plain USB flash drive on any of the board's
four external USB-A jacks regardless of its vendor/product ID, without
needing to parse interface class/subclass/protocol -- YAGNI, since this
project's real hardware setup only ever has the one drive attached
alongside the hub's own permanent Ethernet function. `usb_dwc2.tkb`
gained one small addition to its existing `dwc2_find_bulk_endpoints()`
descriptor walk: capturing the first INTERFACE descriptor's
`bInterfaceNumber` (`dwc2_config_interface_number()`), needed because
Mass Storage's class requests (Get Max LUN, Bulk-Only Mass Storage
Reset) are addressed to an interface, not the device -- reusing the same
already-proven, capacity-clamped walk loop rather than adding a second
one, so no new `--forbid-trap` exposure was introduced in that
already-hardened shared file.

**Bulk-Only Transport + SCSI.** `usb_msc.tkb` builds the 31-byte CBW /
reads the 13-byte CSW by hand (byte-level, matching this project's
existing register-poking style elsewhere) and implements just the
commands this project needs: TEST UNIT READY (with a bounded ready-retry
loop, real devices commonly report not-ready for a moment right after
being configured), INQUIRY (36 bytes, vendor/product ASCII), READ
CAPACITY(10), and READ(10)/WRITE(10) at a fixed 1-block transfer length
(this driver's own single-512-byte-block-per-call contract, matching
`examples/common_stm32/sdmmc.tkb`'s `disk_read`/`disk_write` exactly).
Get Max LUN and Bulk-Only Mass Storage Reset are both best-effort --
many single-LUN devices STALL Get Max LUN entirely rather than
answering 0, matching how U-Boot/Linux both just fall back to LUN 0 on
that STALL; this driver always addresses LUN 0 regardless (YAGNI, a
single external flash drive never exposes more than one). Reuses the
SAME bulk-transfer machinery (`dwc2_bulk_in`/`dwc2_bulk_out`, the
module-global toggle/endpoint/device-address state in `usb_dwc2.tkb`)
`eth.tkb`'s Ethernet path already uses -- safe because no example in
this project needs Ethernet and USB mass storage active at the same
time.

Exposes the same `disk_initialize`/`disk_status`/`disk_read`/
`disk_write` Media Access Interface `examples/common_stm32/sdmmc.tkb`
already exposes, with one deliberate signature difference: `disk_write`'s
`buf` is `*align(32) u8`, not plain `*u8` -- unlike STM32's DMA-based
`disk_write` (a clean/writeback, tolerant of any alignment), this
driver's `disk_write` goes through `dwc2_bulk_out`, which itself
requires `align(32)` (issue #146's `dma_prepare_tx`/`dma_finish_rx`
builtins). `examples/sdcard/sdcard.tkb`'s own write buffer was widened
to `align(32)` to satisfy this when it was later wired up for this
board too (harmless for STM32, a stricter-aligned pointer trivially
satisfies a plain `*u8` parameter).

**Real-hardware bring-up found one genuine, previously-unexercised bug**:
`usb_hub.tkb`'s `hub_power_on_all_ports()` used a 100ms settle delay
after `SET_PORT_FEATURE(PORT_POWER)`, correct for the LAN9514's own
internal Ethernet function (part of the same chip, always instantly
"connected") but not enough for a real external device's own VBUS
inrush/decoupling-capacitor settle time -- confirmed by polling every
500ms up to 5s on real hardware: 100ms consistently left
`wPortStatus.CONNECTION` clear, 500ms consistently had it set already at
the very first check. This path was never exercised by any earlier
milestone (the external ports were "assumed empty" through the
Ethernet-only milestones -- see that section above), so the original
100ms constant was never actually validated against a real downstream
device. Fixed by raising the delay to 500ms, generous headroom above the
observed threshold, matching this file's own `hub_port_reset` settle
time and `dwc2_host_port_reset`'s own extra recovery delay elsewhere in
this directory. This also updated `examples/usb_probe/usb_probe.expected`
-- with a real device now permanently attached for this milestone's own
testing, `usb_probe`'s own hub-port-walk legitimately reports a second
enumerated device (`hub port 5: connected`, `0781:5597`, a SanDisk USB
drive) alongside the LAN9514's Ethernet function it always reported.

`examples/usb_msc_probe/usb_msc_probe.tkb` writes a fixed, deterministic
byte pattern into four sectors and reads it back (same "byte round trip
through the real hardware, checked independently" principle as
`examples/sdcard/sdcard.tkb`'s own STM32 test, `scripts/usb_msc_test.py`
mirroring `scripts/sdcard_test.py`), plus prints Get Max LUN/INQUIRY/READ
CAPACITY diagnostics and a `disk_initialize()` failure-stage checkpoint
(`msc_debug_last_stage()`) for real-hardware debugging -- the whole
enumeration+BOT+SCSI stack was unproven-on-hardware code as of this
milestone, unlike the Ethernet path's own consolidation into `eth.tkb`
which could lean on `usb_probe.tkb`'s already-separately-proven earlier
milestones. Real-hardware result against a real SanDisk USB drive:
INQUIRY reports `USB`/`SanDisk 3.2Gen1`, READ CAPACITY reports a
512-byte block size, and all four test sectors round-trip correctly.
Destroys whatever was previously on the attached drive every run
(confirmed acceptable for this project's own dedicated test drive, same
acceptance already recorded for `examples/sdcard/sdcard.tkb`'s STM32 SD
card). Wired into `make hwcheck-rpi3` via
`run_hw_test_rpi3_usb_msc` (`scripts/run_hwtest_rpi3.sh`), the JTAG-load
counterpart of `scripts/run_hwtest_ram.sh`'s `run_hw_test_ram_sdcard`.
59/59 (now 60/60 with `usb_msc_probe` itself) `make hwcheck-rpi3`, `make
hwcheck-rpi3-net` unaffected, `make check` (134/134) unaffected.

New `.tkb` work process (root `AGENTS.md`): `usb_msc.tkb` and
`usb_msc_probe.tkb` were written and verified first WITHOUT
`--forbid-trap` (their own `Makefile` group, `RPI3_MSC_TAKIBI_FLAGS`,
deliberately not using the shared `RPI3_TAKIBI_FLAGS`) -- hardening is a
later, separate pass across this whole milestone (this driver plus
whichever `fatfs`-family examples end up wired to it) once that is
proven working end to end, same process the Ethernet milestone's own
history followed.

**`fatfs_sdcard` ported (first of the `fatfs`-family examples).** New
`examples/common_rpi3/fat12_usbmsc.tkb`: the thin `mem_block_read`/
`mem_block_write` adapter over `usb_msc.tkb`'s `disk_read`/`disk_write`,
mirroring `examples/common_stm32/fat12_sdmmc.tkb` exactly (both
directions are `*align(32) u8` here, since this board's own
`disk_write` needs it too, unlike STM32's -- see `usb_msc.tkb`'s header
comment). `examples/fatfs_sdcard/fatfs_sdcard.tkb` itself is now
genuinely shared between STM32 and this board: its old hardcoded
`use "examples/common_stm32/fat12_sdmmc.tkb";` line is gone, and each
target's `Makefile` rule puts its own adapter
(`fat12_sdmmc.tkb`/`fat12_usbmsc.tkb`) on the compile command line
instead -- the same command-line-composition pattern
`examples/net_echo.tkb` and siblings already use for their own
target-specific HAL, chosen over duplicating this file per target.
Real-hardware result: format, create `HELLO.TXT`, read it back, 20
overwrite rounds, read back the latest content -- all pass, and the
captured UART output is byte-identical to STM32's own existing
`fatfs_sdcard.expected` fixture, reused unchanged (same "every fixture
here is reused byte-for-byte across targets" convention every other
shared RPi3 example already follows). Wired into `make hwcheck-rpi3`
via the plain `run_hw_test_rpi3` (a static fixture diff is enough here,
unlike `usb_msc_probe`'s dynamic hex dump). 61/61 `make hwcheck-rpi3`,
`make check` (134/134) unaffected. A handful of unrelated tests
(`echo`/`irq`, and separately a wider batch earlier in this same
session) flaked with truncated/garbled output at various points during
this session's heavy back-to-back real-hardware iteration, every time
resolved cleanly by `scripts/rpi3_jtag_reset.sh` -- consistent with this
file's own documented "stale inherited state across repeated ad-hoc
JTAG re-injection" failure mode (see the MMU/caches section), not a
regression in this milestone's code; a full clean `make hwcheck-rpi3`
run immediately after a reset has passed 100% each time this was
retried.

**`rtos_fatfs_sdcard` ported -- and it found a real driver bug.** The
shared `rtos_fatfs_sdcard.tkb` source got the same de-STM32-ing
treatment as `fatfs_sdcard.tkb` (target adapter moved to the compile
command line), plus its own Makefile group combining the scheduler HAL
(`timer.tkb`) with the USB HAL on one command line for the first time --
which surfaced two latent problems, both fixed:

1. **Duplicate `extern fn read_cntfrq` declarations.** `timer.tkb`,
   `rtc.tkb`, and `usb_dwc2.tkb` each declared it locally (and
   `timer.tkb`'s even had the wrong width, i32 vs the real i64 ABI --
   harmless in isolation, cntfrq values fit in 32 bits); takibi rejects
   a second `extern fn` of the same name even with a matching signature.
   Factored into `examples/common_rpi3/timer_asm_extern.tkb`, `use`d by
   all three -- same fix shape as `gic_regs.tkb`'s own split (issue #79
   follow-up).
2. **`dwc2_bulk_in` was missing `dma_prepare_rx` BEFORE the transfer**
   (it only invalidated after, via `dma_finish_rx`). Dirty CPU cache
   lines covering the destination buffer -- guaranteed when the buffer
   is `fat12.tkb`'s stack-allocated `sector_buf`, freshly written by an
   earlier call at the same stack address -- get evicted during/after
   the DMA write and clobber the DMA'd bytes in RAM. The failure
   signature was distinctive: correct byte COUNT, corrupted CONTENT
   (leading bytes replaced by recognizable stale stack data -- pointer
   values into this payload's own address range). Only ever manifested
   under the RTOS: the flat `fatfs_sdcard` busy-waits through the whole
   transfer touching almost no memory (dirty lines never evicted), while
   the scheduler tick's IRQ entry + task switching run DURING the
   busy-wait and generate exactly the cache pressure that evicts them --
   also why the Ethernet path never hit this (`eth_rx_buf` is a
   dedicated global the CPU never writes, so it never has dirty lines).
   Ruled out along the way: task stack size, `disable_irq` around
   individual FAT calls, settle delays. Fixed by adding
   `dma_prepare_rx` before the transfer in `dwc2_bulk_in` and the
   control-transfer IN data stage -- the exact prepare+finish pair
   `examples/common_stm32/sdmmc.tkb`'s `disk_read` has always used, with
   this same reasoning in its comments. Verified: 5/5 consecutive
   real-hardware runs clean (previously failed most runs), 62/62
   `make hwcheck-rpi3`, and the full 6/6 `make hwcheck-rpi3-net` suite
   re-run to confirm the shared bulk-IN change did not regress Ethernet.

`rtos_fatfs_sdcard (rpi3)` is wired into `make hwcheck-rpi3` reusing
STM32's own `.expected` fixture unchanged (byte-identical output), and
serves as the standing regression test for the `dma_prepare_rx` fix.

**Multi-device USB: Ethernet + mass storage concurrently (done).** The
remaining `fatfs`-family examples (HTTP/KVS + SD-card) all need the
LAN9514 Ethernet function AND the USB flash drive active in the same
program -- previously impossible twice over: `usb_dwc2.tkb`'s bulk
endpoint/toggle state was a single-device singleton, and `eth.tkb`'s
`net_init()`/`usb_msc.tkb`'s `disk_initialize()` each ran the whole
bring-up themselves (the second caller's `dwc2_soft_reset()` would
unbind the first's device). Two changes, both shaped to keep every
existing call site untouched:

- `usb_dwc2.tkb`: bulk state generalized to two per-device slots, each
  with its own dedicated channel pair (slot 0 = OUT ch 1 / IN ch 2,
  exactly what the single-device driver always used; slot 1 = OUT ch 3 /
  IN ch 4), bound by `dwc2_bulk_reset_toggles(dev_addr, ...)` and looked
  up by device address inside `dwc2_bulk_in`/`dwc2_bulk_out` -- whose
  signatures are unchanged. Slot indices are if-narrowed
  `{0..<2 as usize}` so the net-examples build (which compiles this file
  under `--forbid-trap`) still proves every access. Two slots, not a
  general table -- YAGNI: one permanently-attached Ethernet function,
  one test drive.
- `examples/common_rpi3/usb_host.tkb` (new): the shared bring-up +
  per-port enumeration walk (the exact code both callers had inline,
  proven via usb_probe one milestone at a time) behind an idempotent
  `usb_host_init()` recording every enumerated device (addr, VID:PID,
  ep0 max packet) in a small table. `net_init()` finds `0424:ec00` in
  the table; `disk_initialize()` finds the first entry that is NOT it.
  First caller does the real work; the second gets the table for free.

Verified on real hardware: a dedicated dual-device diagnostic
(net_init -> disk_initialize -> storage write -> net RX poll -> storage
read-back verify -> net RX poll, all passing in one program), plus the
full regression: 62/62 `make hwcheck-rpi3`, 6/6 `make hwcheck-rpi3-net`,
134/134 `make check`.

**`http_server_sdcard` ported.** `http_server_sdcard.tkb`/
`http_server_sdcard_install.tkb` got the same de-STM32-ing treatment as
`fatfs_sdcard.tkb` (adapter moved to the compile command line;
`http_server_sdcard_install.tkb`'s `sector_buf` widened to `align(32)`
for the same reason `examples/sdcard/sdcard.tkb`'s write buffer was).
Provisioning the drive (writing a real mtools-built FAT12 image with no
human touching it) needed a genuinely new script,
`scripts/rpi3_provision_http_server_sdcard.sh`, since this board has no
`reset halt` (see "Why JTAG injection" above) and the STM32 script's own
two-hardware-breakpoint OpenOCD sequence had never been attempted here --
confirmed on real hardware that it works UNCHANGED in shape (halt, load
the installer, breakpoint at `app_main`, resume, wait, `load_image` the
seed FAT12 image directly into the halted core's `staging` buffer,
breakpoint at `install_done`, resume, wait, read `install_result`), with
one real difference this board's OpenOCD/target config exposed: `mrw`
(which STM32's script uses to read a value inline for `echo`) is not a
valid command here ("invalid command name") even though the identical
read works fine via `mdw` -- the script parses `mdw`'s printed
`0xADDR: VALUE` line instead.
`scripts/eth_http_server_sdcard_test.py` (shared with STM32) gained an
`ETH_TEST_SUBNET` override, the same pattern its sibling
`eth_http_server_test.py` already had, so it can address either board's
`OUR_IP` instead of only STM32's hardcoded `192.168.10.2`.
Real-hardware result: `GET /`, `/ABOUT.HTM`, `/ICON.PNG` all return the
USB drive's real provisioned content over actual HTTP, wired into `make
hwcheck-rpi3-net` (7/7) alongside 62/62 `make hwcheck-rpi3` and 134/134
`make check`, all re-verified clean.

**`http_server_sdcard_rtos`/`kvs_server_sdcard_rtos` ported -- the full
fatfs-family milestone is now complete on this board.** Both got the
same treatment as their non-RTOS siblings (adapter moved to the compile
command line); their RPi3 Makefile group is the union of everything
proven separately so far -- the scheduler HAL (needed by
`rtos_fatfs_sdcard`) combined with concurrent Ethernet + USB storage
(needed by `http_server_sdcard`), all on one command line, all in one
program.

Real-hardware iteration on this pair found the network test suite
itself needed a reliability fix, unrelated to the firmware: running
`kvs_server_sdcard_rtos` immediately after `http_server_sdcard_rtos`
with no reset in between (the test suite's pattern at the time)
reproducibly left the
network stack unreachable ("No route to host" on every request), even
past a generous settle wait; the identical firmware booted from a
genuine `scripts/rpi3_jtag_reset.sh` reset answered correctly every
time. Root cause not isolated (this board's own `net_init()` already
does a full DWC2 soft reset, which is expected to bring the USB core to
a clean state regardless of what the previous payload left behind) --
fixed pragmatically by resetting before this one test's first boot,
kept because it demonstrably and repeatably works, same "batch fix,
root cause not fully isolated" precedent as the DWC2 XACT_ERROR
investigation during the Ethernet milestone. Documentation correction
that came out of chasing this: `scripts/rpi3_jtag_reset.sh`'s (and this
file's own) description of the reset as "equivalent to a physical power
cycle" was an overclaim -- it is a warm SoC reboot; board-level 5V never
drops, so USB peripherals are NOT reset by it, confirmed directly by the
USB Mass Storage drive's own file content surviving the reset untouched
(the mechanism `kvs_server_sdcard_rtos`'s own persistence-survives-a-
reset check below depends on). Both files' wording is now corrected.

The follow-up generalized that real-hardware finding instead of keeping
it as a one-test exception: both `make hwcheck-rpi3` and
`make hwcheck-rpi3-net` now run `scripts/rpi3_jtag_reset.sh` before
every example load. This includes a second reset between
`http_server_sdcard`'s provisioning firmware and its actual server
firmware; the reset preserves the newly written USB-drive contents but
clears the installer's SoC-side state. Reset failure is treated as JTAG
infrastructure failure, with the reconnect log printed, rather than
allowing a misleading UART or network mismatch.

Real-hardware result, from a clean reset: `GET /`, `/ABOUT.HTM`,
`/ICON.PNG` all pass against `http_server_sdcard_rtos`;
`kvs_server_sdcard_rtos` passes its full PUT/GET/DELETE/LIST sequence
AND the two-boot persistence-survives-a-real-reset check (one extra key
written on boot 1, confirmed still readable after `rpi3_jtag_reset.sh`
+ boot 2) -- the same proof `scripts/run_hwtest_net_ram.sh` already
does for STM32, now also proven on this board. `make hwcheck-rpi3-net`
9/9, `make hwcheck-rpi3` 62/62, `make check` 134/134, all from a clean
reset.

This completes GitHub issue #145's own remaining scope (issue #61's
`fatfs` in-memory core, issue #62-equivalent real block storage, and
every fatfs-family application example STM32 has) for Raspberry Pi 3B.
**Remaining work before this whole milestone's `--forbid-trap`
hardening pass**: none functionally -- every fatfs-family example that
exists on STM32 now also runs on this board. The hardening pass itself
(turning `RPI3_MSC_TAKIBI_FLAGS` into `RPI3_TAKIBI_FLAGS` for every
group this section touched, fixing whatever it flags) is the one
deliberately deferred step, per the project's established
baseline-then-hardened-pass process.

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
arm64 lite) with `enable_jtag_gpio=1`/`dtoverlay=disable-bt` appended to
`config.txt` -- Linux boots normally, JTAG is just also wired up.
Injecting a bare-metal payload's PC/SP directly into a *live* Linux core
via JTAG halt+resume is not safe: confirmed live (read-only
`halt`/`reg`/`resume`) that the running core sits at EL1H with the MMU
and both caches on, executing a kernel virtual address -- resuming into
it with a raw physical PC would fault or corrupt kernel state, not run
cleanly.

STM32's equivalent hardware harness (`scripts/run_hwtest_ram.sh`) avoids
this with `reset halt`: a real hardware reset lands the CPU at a known,
clean vector table before any Flash code has run. That option does not
exist here over JTAG's `reset` command -- the standard 6-pin Raspberry
Pi JTAG GPIO header carries no system reset line, so OpenOCD's `reset`
cannot restart the GPU firmware's boot sequence (confirmed:
`target/bcm2837.cfg` defines no `reset_config`/SRST handling of its
own). `scripts/rpi3_jtag_reset.sh` gets the same end result a different
way -- see "Resetting the board over JTAG" below.

The workaround: `jtag_stub.S`, a standalone 8-byte `wfe`-loop image, is
flashed as the SD card's `kernel8.img` in place of Raspbian. On power-up
(or a JTAG-triggered watchdog reset, see below) the GPU firmware still
does its own job (DRAM/clock init) exactly as it would for a real OS,
then jumps to this stub instead of Linux -- core 0 parks in an infinite
`wfe` with the MMU off and no OS state to protect. From there,
`scripts/rpi3_jtag_load.sh` can safely `halt` and verify (by checking
the halted core's exception level, see "Load and run" below) that it
caught a bare-metal image and not still-running Raspbian, before
injecting a real payload.

## Resetting the board over JTAG (no physical access needed)

`scripts/rpi3_jtag_reset.sh` triggers a full BCM2837 chip reset purely
over JTAG, with no human needed at the board. This is a warm SoC
reboot, NOT equivalent to a physical power cycle (GitHub issue #145's
own investigation corrected an earlier version of this section that
claimed otherwise): the GPU firmware does rerun from scratch
(re-reading `config.txt` and `kernel8.img` off the SD card) and every
ARM core/peripheral register on the SoC returns to its power-on-reset
state, but board-level 5V stays up throughout, so anything only reset
by actually removing power is NOT reset by this -- confirmed
empirically, a USB Mass Storage drive's own file content survives this
reset untouched (see "USB Mass Storage" below -- provisioning the drive
once and reading it back after a deliberate reset is how
`kvs_server_sdcard_rtos`'s persistence-survives-a-reset check works).
Mechanism: BCM2837's PM block has a watchdog-based software reset
(`PM_RSTC` at `0x3F10001C`, `PM_WDOG` at `0x3F100024`, gated by the
`0x5A000000` password magic in the top byte of any write -- the same
mechanism Linux's own `bcm2835_wdt` driver and U-Boot's `bcm2835` reset
driver use for `reboot`), poked directly via OpenOCD `mww` memory
writes. The watchdog
fires fast enough that the triggering OpenOCD session almost always
ends with "Invalid ACK"/"JTAG-DP STICKY ERROR" (the DAP losing a stable
connection to a chip that is actively resetting underneath it) --
that's expected and means the reset worked, not that it failed; the
script ignores that exit status and separately polls (reconnect +
`halt` + `reg pc`, up to ~15s) until the chip responds again, confirming
success by checking it lands back at `jtag_stub.S`'s spin loop (EL2H,
PC=0x80004) before reporting success.

Use this instead of asking for a physical power cycle whenever the
board ends up in a state `scripts/rpi3_jtag_load.sh`'s EL2H check
refuses (see "Load and run" below) or otherwise needs a clean restart --
e.g. after directly poking system/MMU state by hand while debugging.
`scripts/rpi3_jtag_load.sh`'s own refusal message suggests this script
first, a physical power cycle only as the fallback (needed only if
`kernel8.img` on the SD card isn't `jtag_stub.img` in the first place).

Does NOT check what's currently running before resetting (unlike
`rpi3_jtag_load.sh`'s injection path) -- it is explicitly a "start over"
operation; don't run it against a board with a live Raspbian session you
want to keep.

## Build

```
make examples/common_rpi3/jtag_stub.img   # SD card kernel8.img (one-time flash)
make examples/start/kernel_rpi3.elf       # an injected payload (any RPI3_EXAMPLES name)
```

`RPI3_TARGET := aarch64-none-elf`, `RPI3_CPU := cortex-a53`,
`RPI3_EXAMPLES`/`RPI3_CHECKSUM_EXAMPLES`/`RPI3_IRQ_EXAMPLES`/
`RPI3_RTC_EXAMPLES`/`RPI3_SCHED_EXAMPLES`/`RPI3_SCHED_SEM_EXAMPLES`
(Makefile) together list the 43 examples currently ported, each group
its own pattern rule (mirroring `STM32_OBJS`/`STM32_EXAMPLES`'s own
per-group split). Add more names to the relevant group (plus a matching
`run_hw_test_rpi3` line in `scripts/run_hwtest_rpi3.sh`) one at a time
as each is ported and verified.

`jtag_stub.img` is a raw binary (`llvm-objcopy-19 -O binary`), not an
ELF -- the GPU firmware's loader expects a flat binary at a fixed
address (0x80000, `jtag_stub.ld`), not an ELF container.

Every `kernel_rpi3.elf` loads at 0x200000 (`link.ld`), deliberately
different from the stub's 0x80000, so a JTAG session's `load_image`
target is never the same address the stub itself occupied.

## MMU and caches: why both are on, and how JTAG re-injection stays safe

`examples/common_rpi3/mmu.S`'s `mmu_init` (called from `startup.S`,
after BSS clear -- see that call site's own comment for why that
ordering specifically matters) sets up a minimal 2-level AArch64 EL2
identity map (VA == PA, 4KB granule, T0SZ=25: 1GB per L1 entry / 2MB per
L2 block) and enables the MMU (`SCTLR_EL2.M`) before anything else runs.
Only L1 entry 0 is populated, covering 0x00000000-0x3FFFFFFF: L2
entries 0-503 (0x00000000-0x3EFFFFFF) are Normal Write-Back Cacheable
(RAM), entries 504-511 (0x3F000000-0x3FFFFFFF) are Device-nGnRnE
(peripherals) -- 0x3F000000 is exactly 2MB-aligned, so this split falls
on a clean block boundary.

**Why the MMU is needed at all**: AArch64 architecturally treats ALL
data accesses as Device-nGnRnE memory whenever the stage 1 MMU is
disabled, and Device memory enforces natural alignment unconditionally
(independent of `SCTLR_ELx.A`). Confirmed the hard way:
`examples/packed` and `examples/inet_checksum` both faulted
(`ESR_EL2 0x96000061` -- EC 0x25 "Data Abort, same EL", DFSC "Alignment
fault") on a WIDE STORE THE COMPILER SYNTHESIZED from several adjacent
1-byte source-level writes (`hdr[0]=0x45 as u8; hdr[1]=0x00 as u8; ...`
-> a single `stur x8, [sp, #0xc]`, unaligned relative to 8 bytes) --
`examples/packed`'s own field access is intentionally unaligned by
design, but `inet_checksum.tkb`/`examples/common/netutil.tkb`'s
`read_u16be`/`checksum_add` are deliberately byte-safe already (for
endianness reasons, not alignment ones) and still hit this, because it
is LLVM's own backend store-merging optimization creating the unaligned
instruction, invisible at the `.tkb` source level. This is a general
LLVM-backend phenomenon (any language using LLVM -- C/Clang, Rust, Zig
-- is equally exposed under the same "MMU off" condition), not specific
to takibi, and is why essentially every real-world bare-metal AArch64
project enables the MMU during early boot.

**`SCTLR_EL2.C`/`.I` (D-cache/I-cache) history**: for most of this
board's bring-up, both were explicitly forced OFF, not just left unset.
This project's specific JTAG re-injection workflow
(`scripts/rpi3_jtag_load.sh`) writes each new payload directly into
physical RAM over the debug port (`load_image`), bypassing the CPU's
caches entirely -- like a DMA write. With caching enabled and no other
precaution, this produced silent data corruption, confirmed twice over:
- First: a batch run where only the very FIRST example passed and every
  following one produced UART output that looked like raw
  instruction/data bytes leaking out (not a clean hang, not a fault --
  `ESR_EL2` on inspection turned out to be STALE, left over from an
  earlier, unrelated fault, not a fresh one; the affected examples had
  actually run to completion, just computed/transmitted wrong data).
  Root cause: `SCTLR_EL2` is inherited state like everything else this
  file discusses (see `startup.S`'s own comment), so `mmu_init`'s
  original `orr x0, x0, #1 | (1<<2) | (1<<12)`-style write only ADDED
  the M bit on top of whatever C/I state a PREVIOUS payload's own
  `mmu_init` had left set, never clearing it -- fixed at the time by
  using `bic` to explicitly force C/I off on every run.
- Second: even after that fix, a run mixing in leftover state from an
  UNRELATED prior manual test (built before the `bic` fix existed, with
  caching left genuinely enabled and never cleaned before halting)
  still showed the same corruption pattern -- consistent with dirty
  (written-back-pending) D-cache lines from that earlier occupant
  getting evicted and overwriting freshly JTAG-loaded memory at some
  later point, not just serving stale reads. Confirmed resolved,
  definitively, by resetting the board (`scripts/rpi3_jtag_reset.sh`)
  to a genuinely clean state and re-running the full `make
  hwcheck-rpi3` suite from there: 33/33 passed.

**Both caches are enabled again as of the scheduler-group port
(2026-07-19)** -- see `HISTORY.md`'s corresponding entry for the full
story. Leaving caches off sidestepped the corruption above, but at a
real cost once `ldaxr`/`stlxr`-based synchronization
(`examples/semaphore` and everything built on
`examples/common/sync.tkb`) entered scope: cache-off-forever has only
accidental single-core correctness, and real cache-coherent visibility
of a `sem_post` on one core to a `sem_wait` spinning on another
fundamentally needs the coherency fabric caching provides -- worth
having correctly in place now even though only core 0 runs today (see
the "Only core 0 runs" gate in `startup.S`), rather than revisiting this
file again once a future example brings up cores 1-3. The stale-cache
hazard that originally justified leaving caches off is instead handled
the way every real ARMv8 reset handler (ARM Trusted Firmware, U-Boot,
Linux) already handles it: `startup.S`'s `_start` calls
`dcache_invalidate_all` (a CLIDR_EL1/CSSELR_EL1/CCSIDR_EL1 set/way
sweep, INVALIDATE not clean-and-invalidate -- a write-back here would
overwrite the fresh JTAG-loaded content with stale cached garbage) plus
`ic ialluis`, unconditionally, as the FIRST thing that runs, before BSS
clear or `mmu_init` -- with SCTLR_EL2.C/I forced off one more time
immediately before that (in case inherited state already had them on),
so the invalidation itself starts from a known state. `mmu_init` then
`orr`s C/I on (unconditionally, same "explicit override of inherited
state" reasoning that already applied to the M bit and, before this
change, to forcing them off) as its final step. The MMU's page-table
memory attributes are still what fixes the alignment-fault problem
above -- that part of the design is unchanged.

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
scripts/rpi3_jtag_load.sh examples/start/kernel_rpi3.elf
```

Two-pass, both over the same `interface/ftdi/olimex-arm-usb-tiny-h.cfg`
+ `target/bcm2837.cfg`:
1. **Read-only safety check**: `halt`, read `pc` + current exception
   level, `resume` immediately. If the halted core is not at EL2H, the
   script refuses to go further -- it has almost certainly caught
   still-running Raspbian (Linux always runs the kernel at EL1, so a
   live boot always halts at EL1H), and the board is left running
   exactly as found (this pass never writes anything). This is
   deliberately NOT an MMU-state check (an earlier version used
   "MMU off" as the signal, back when nothing here ever enabled the
   MMU -- see "MMU" above for why every payload now enables it, which
   made that old signal self-contradictory: our own payloads leave the
   core with the MMU ON now too, same as Raspbian) and NOT a narrow
   PC-range check against `jtag_stub.S`'s address alone: a *previous*
   injected payload's own halt loop is just as safe to catch and
   overwrite as the stub itself (both run at EL2H), so one reset
   (physical power cycle, or `scripts/rpi3_jtag_reset.sh`) covers any
   number of subsequent injections -- this is what makes
   `scripts/run_hwtest_rpi3.sh` (`make hwcheck-rpi3`) practical to run
   more than once without resetting between examples.
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
against each example's existing `.expected` fixture -- every fixture is
reused byte-for-byte from the QEMU/STM32 suites, since `uart_puts`/
`uart_print_*` write identical bytes on every HAL. NOT part of `make
check`/`make allcheck` -- like `make hwcheck-stm32`, it needs physical
hardware, and unlike it, the very first run in a session additionally
needs the board already reset into `jtag_stub.S` (physical power cycle,
or `scripts/rpi3_jtag_reset.sh` -- see "Why JTAG injection, not an SD
card kernel" and "Resetting the board over JTAG" above);
`scripts/run_hwtest_rpi3.sh` distinguishes that failure mode (JTAG
injection itself failing, almost always the EL2H check refusing a
still-Raspbian board) from an actual test failure (injection succeeded,
UART output didn't match), so the fix (reset vs. a real bug) is never
ambiguous from the output.

The loader-status capture must remain inside an `if` condition. A former
`loader; echo $? > status` command string ran under the harness's global
`set -e`; any nonzero loader result exited the entire harness before the
status file or saved OpenOCD log could be reported, leaving `make` to show
only an unexplained `Error 1`. Both ordinary and stdin-driven tests now
capture the status through `if loader; then ...; else ...; fi`. A JTAG
infrastructure failure prints the complete loader log and stops after the
first example (the same adapter failure cannot usefully be retried for all
remaining examples); UART mismatches still accumulate normally.

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

## RTC (`rtc.tkb`) -- no real RTC peripheral on this board

`examples/rtc/rtc.tkb` and `examples/timer/timer.tkb` are ported onto
the ARM Generic Timer's free-running physical counter
(`CNTPCT_EL0`/`CNTFRQ_EL0`, read via `examples/common_rpi3/
timer_asm.S`'s `read_cntpct()`/`read_cntfrq()` stubs -- `mrs` cannot be
called directly from takibi) rather than a real RTC. Raspberry Pi 3B has
no battery-backed real-time clock at all; `rtc_read_seconds()` here
means "seconds since this core started counting" (effectively "seconds
since boot"), not wall-clock time. Agreed tradeoff (issue #140): both
examples only ever check that time *advances*, never an absolute value,
so this substitution satisfies their actual behavior even though the
semantics genuinely differ from QEMU's PL031/STM32's real RTC
peripheral. `rtc_init()` is a no-op -- the counter needs no enable step
of its own, already running by the time any code gets control.

`scripts/run_hwtest_rpi3.sh`'s `run_hw_test_rpi3` needed the same fix
`examples/common_stm32/AGENTS.md` documents for its own harness: these
two examples pause for a real 1-second tick *between* two print
statements, and the default ~0.3s idle-quiet capture threshold mistook
that in-test pause for the test finishing, truncating the capture
before the second line ever arrived. Fixed with optional
`MAX_SECS`/`STABLE_POLLS` overrides on `run_hw_test_rpi3` (5s / 30
polls = 1.5s quiet threshold for these two call sites only, comfortably
longer than the 1s pause without materially slowing every other test).

## Interrupts (`intc.tkb`, `startup.S`'s `rpi3_irq_entry`)

BCM2837's interrupt fabric is a 2-level cascade unlike either existing
target: the per-core "ARM Local"/QA7 block at 0x40000000 (ARM Generic
Timer IRQs per core, plus one pass-through "GPU IRQ" line carrying
every peripheral interrupt as a single bit), cascading from the legacy
72-source VC ("armctrl") controller at 0x3F00B200 (bank offsets
confirmed against Linux's `drivers/irqchip/irq-bcm2835.c`; UART0 =
global IRQ 57 = bit 25 of pending_2/Enable_IRQs_2). `intc.tkb` provides
the uniformly-named `irq_uart_rx_setup()`/`irq_uart_rx_unmask()` (same
contract as `gic.tkb`/`nvic.tkb`) and `rpi3_irq_dispatch()`, called
from `startup.S`'s `rpi3_irq_entry` -- deliberately NOT named
`irq_dispatch`, because `examples/echo/echo.tkb`/`examples/irq/irq.tkb`
define that name themselves (their GICv2-shaped version, dead code here
exactly as on STM32; this target vectors UART RX straight to
`uart.tkb`'s `uart_irq_handler`, the STM32 `USART1_IRQHandler` pattern,
so those shared files needed zero changes).

Three hard-won findings, all rooted in the same "JTAG re-injection
inherits state a real reset would clear" theme:
- **`HCR_EL2.IMO` must be set** (`startup.S`): with IMO=0 the
  architecture routes physical IRQs to EL1, and an IRQ targeting a
  lower EL than the executing one is implicitly masked regardless of
  PSTATE.I -- every observable layer (UART0_MIS, VC pending_2, GPU
  routing) said "pending" while the core never vectored. Firmware
  leaves IMO=0 because Linux takes interrupts at EL1.
- **Inherited peripheral-interrupt state must be quiesced before
  DAIFClr** (`startup.S`): a previous run's still-enabled,
  still-asserted level interrupt otherwise fires the moment PSTATE.I
  clears -- and in an example whose dispatch never acknowledges it,
  re-fires forever (an interrupt storm indistinguishable from a silent
  hang; took out the ENTIRE suite, including the 33 non-interrupt
  examples, the first run after IMO was fixed). `uart_init()` also
  drains stale RX bytes and clears PL011 ICR for the same reason.
- **A 2MB block descriptor's output address is absolute** (`mmu.S`): see
  the `l2_table_local` comment for the silent-wrong-mapping bug this
  caused (QA7 reads landing in the GPU firmware's armstub8 code at
  physical 0 -- diagnosed by recognizing the read-back "register value"
  0xd51e4020 as an `msr elr_el3, x0` instruction).

Not rooted in inherited state, and not caught until the scheduler group
(2026-07-19) -- see `HISTORY.md`'s corresponding entry for the full
diagnosis:
- **`rpi3_irq_entry` never actually switched tasks, on any RPi3 example,
  ever, until this was found and fixed.** Its own header comment already
  claimed the QEMU-matching convention ("`frame_sp` passed in x0, the
  RETURNED frame_sp becomes the new SP"), but the actual instructions
  never did it: `bl rpi3_irq_dispatch` was missing the `mov x0, sp`
  immediately before it (so the dispatcher was called with whatever `x0`
  happened to hold, not the frame pointer) and the `mov sp, x0`
  immediately after it (so the returned next-task frame was simply
  discarded) -- every interrupt always resumed the exact context it
  interrupted. `examples/preempt` and `examples/watchdog` had both
  already been passing `make hwcheck-rpi3` despite this, because both
  examples' `.expected` fixtures are derived entirely from tick-counting
  bookkeeping the dispatcher performs regardless of whether the
  interrupted task's own code ever runs again; `examples/semaphore` was
  the first example whose correctness depends on a task's own code
  actually executing (`shared.count`, incremented by `task_a`/`task_b`
  themselves), and is what surfaced this. Fixed by adding the exact same
  two lines `examples/common_qemu/startup.S`'s `irq_entry` already has.

## UART0 (PL011) driver notes (`uart.tkb`)

- GPIO14/15 must be switched to ALT0 and have their pull-up/down
  explicitly disabled (old-style `GPPUD`/`GPPUDCLK0` handshake -- this
  SoC predates BCM2711's per-pin `GPIO_PUP_PDN_CNTRL_REGn` registers)
  before UART0's own registers do anything useful.
- Baud divisor assumes a 48MHz UART clock (the documented default core
  clock the GPU firmware leaves UART0 running from). If a future example
  changes `core_freq`/PLL settings, this divisor calculation in
  `uart_init()` needs revisiting.
- RX interrupt support follows `examples/common_stm32/uart.tkb`'s
  stored-handler pattern (`uart_set_rx_handler` + `uart_irq_handler`),
  not QEMU's dispatch-by-GIC-ID -- see "Interrupts" above.

## Exception vector table (`startup.S`)

The EL2H IRQ entry (0x280) vectors to `rpi3_irq_entry` (full x0-x30 +
ELR/SPSR save, `mov x0, sp` / `bl rpi3_irq_dispatch` / `mov sp, x0` /
restore / `eret` -- same 272-byte frame AND task-switching calling
convention as `examples/common_qemu/startup.S`'s `irq_entry`, resuming
whatever frame `rpi3_irq_dispatch` returns, not necessarily the one
that was interrupted -- see "Interrupts" above for a bug that, until
2026-07-19, made this description true in comment only). Every
other entry just spins (`b .`) as a safety net for controlled,
debuggable behavior on any fault. Found necessary the hard way: before
this table existed, `examples/packed` hanging left the halted PC
holding raw garbage data, not a code address -- with `VBAR_EL2` never
set, an unrelated fault's exception entry itself faulted (ARM Trusted
Firmware's own vector table is not guaranteed to still be valid/mapped
once our own code has been running, and is not ours to depend on
regardless), corrupting CPU state badly enough that even OpenOCD's
halted-PC readout stopped being a real code address.
