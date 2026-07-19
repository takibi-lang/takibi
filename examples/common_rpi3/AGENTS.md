# Raspberry Pi 3B (BCM2837) Bare-Metal Bring-Up

GitHub issue #140. Status: 37 examples ported and passing `make
hwcheck-rpi3` (`start`/`hello`/`print_int`/`print_hex`/`print_ptr`/
`mem`/`array`/`fizzbuzz`/`fibonacci`/`bubblesort`/`ringbuf`/`callstack`/
`crc8`/`djb2`/`bump`/`scheduler`/`struct`/`struct_refined`/`refined`/
`narrow`/`for`/`loop`/`enum`/`nonexhaustive`/`bitops`/`align`/`packed`/
`struct_align`/`const_global`/`sizeof_offsetof`/`inet_checksum`/
`ip_parse`/`tcp_parse`/`rtc`/`timer`/`echo`/`irq` -- `hwcheck-stm32`'s
"plain compute" set plus `rtc`/`timer` (see "RTC" below) plus the two
UART-RX-interrupt examples (see "Interrupts" below)). This is a
JTAG-only bring-up: nothing here writes to the SD card as a real
`kernel8.img`; see "Why JTAG injection, not an SD card kernel" below.
Not yet ported: preempt/semaphore/condvar/msgqueue/watchdog/rtos_demo
(need timer *interrupts* -- distinct from `rtc.tkb`'s polled counter
read below -- plus task-switching support in `rpi3_irq_entry`, a larger
follow-on).

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
out of scope for this target. Do not port these, even once other
examples using real interrupts/timers land.

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
`RPI3_EXAMPLES`/`RPI3_CHECKSUM_EXAMPLES` (Makefile) list the 33 examples
currently ported, generic pattern rules (mirroring `STM32_OBJS`/
`STM32_EXAMPLES`). Add more names there (plus a matching
`run_hw_test_rpi3` line in `scripts/run_hwtest_rpi3.sh`) one at a time
as each is ported and verified -- not the interrupt/timer-dependent
group, see the top of this file.

`jtag_stub.img` is a raw binary (`llvm-objcopy-19 -O binary`), not an
ELF -- the GPU firmware's loader expects a flat binary at a fixed
address (0x80000, `jtag_stub.ld`), not an ELF container.

Every `kernel_rpi3.elf` loads at 0x200000 (`link.ld`), deliberately
different from the stub's 0x80000, so a JTAG session's `load_image`
target is never the same address the stub itself occupied.

## MMU: why it's on, and why its caches deliberately are not

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

**Why `SCTLR_EL2.C`/`.I` (D-cache/I-cache) are explicitly forced OFF**,
not just left unset: this project's specific JTAG re-injection workflow
(`scripts/rpi3_jtag_load.sh`) writes each new payload directly into
physical RAM over the debug port (`load_image`), bypassing the CPU's
caches entirely -- like a DMA write. With caching enabled, this produced
silent data corruption, confirmed twice over:
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
  `mmu_init` had left set, never clearing it -- fixed by using `bic` to
  explicitly force C/I off on every run, not just refrain from setting
  them.
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

With both C and I left off, `load_image`'s direct-to-RAM writes and this
core's own subsequent fetches/loads are trivially coherent (no cache in
the path to ever go stale), matching how a genuine cold boot's
first-ever execution is always coherent by construction. The MMU alone
(page-table memory attributes, not the cache-enable bits) is what
actually fixes the alignment-fault problem above -- there is no known
reason a future example would need the caches on given this project's
specific re-injection-heavy workflow, so this is not treated as a
temporary shortcut to revisit, just the correct tradeoff for this
target's actual usage pattern.

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
ELR/SPSR save, `bl rpi3_irq_dispatch`, restore, `eret` -- same 272-byte
frame as `examples/common_qemu/startup.S`, but always resuming the SAME
context: no task switching until a scheduler example needs it). Every
other entry just spins (`b .`) as a safety net for controlled,
debuggable behavior on any fault. Found necessary the hard way: before
this table existed, `examples/packed` hanging left the halted PC
holding raw garbage data, not a code address -- with `VBAR_EL2` never
set, an unrelated fault's exception entry itself faulted (ARM Trusted
Firmware's own vector table is not guaranteed to still be valid/mapped
once our own code has been running, and is not ours to depend on
regardless), corrupting CPU state badly enough that even OpenOCD's
halted-PC readout stopped being a real code address.
