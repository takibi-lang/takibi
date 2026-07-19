# Raspberry Pi 3B (BCM2837) Bare-Metal Bring-Up

GitHub issue #140. Status: 62 examples ported and passing `make
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
foundation is now complete; USB mass storage is the deliberate next
storage milestone -- see "USB host stack (Ethernet milestone)" below.

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
common_stm32/eth.tkb`'s existing mechanism) lower to a bare `dsb sy` on
AArch64 targets, with no real cache clean/invalidate -- harmless on
QEMU (no cache model) but a genuine gap now that this board's D-cache
is on (see "MMU and caches" above). Rather than extend the compiler or
add a dedicated non-cacheable MMU region, `examples/common_rpi3/
cache_asm.S` (new) adds small, explicit per-range stubs --
`dcache_clean_range`/`dcache_invalidate_range`, VA-based `dc cvac`/`dc
ivac` loops sized via `CTR_EL0.DminLine` -- the address-range-bounded
counterpart of `startup.S`'s existing `dcache_invalidate_all` set/way
sweep. Every DMA hand-off in this section (mailbox buffer, later USB
descriptor rings) calls these explicitly.

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

New `make hwcheck-rpi3-net` (`scripts/run_hwtest_rpi3_net.sh`) -- the
network-functional counterpart to `hwcheck-rpi3`'s UART-only net_echo
check (which only proves `net_init()` succeeds, not that frames
round-trip), split out exactly the way `hwcheck-stm32`/
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
QEMU/STM32 rules; a future RPi3-driver hardening milestone must turn the
flag on for the RPi3 HAL as a separate, explicit baseline-to-hardened
pass. Update this section (and HISTORY.md, and issue #140) after each
further step, per this project's established cadence -- do not batch
documentation to the end.

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
over JTAG -- equivalent to a physical power cycle (the GPU firmware
reruns from scratch, re-reading `config.txt` and `kernel8.img` off the
SD card), with no human needed at the board. Mechanism: BCM2837's PM
block has a watchdog-based software reset (`PM_RSTC` at `0x3F10001C`,
`PM_WDOG` at `0x3F100024`, gated by the `0x5A000000` password magic in
the top byte of any write -- the same mechanism Linux's own
`bcm2835_wdt` driver and U-Boot's `bcm2835` reset driver use for
`reboot`), poked directly via OpenOCD `mww` memory writes. The watchdog
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
make examples/hello/kernel_rpi3.elf       # an injected payload (any RPI3_EXAMPLES name)
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
scripts/rpi3_jtag_load.sh examples/hello/kernel_rpi3.elf
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
