# Raspberry Pi 5 (BCM2712) Bare-Metal Bring-Up

## Status update (2026-07-26, latest): USB bring-up Step 6 in progress --
## real HCRST added, but Enable Slot now triggers USBSTS.HSE/HCE (a real
## bus fault) instead of silently doing nothing; root cause NOT yet found

User asked to proceed autonomously through USB bring-up toward
`make hwcheck-rpi5` parity with `make hwcheck-rpi3` (i.e. as far as
`el0_shell`), calling only for genuine design/implementation judgment
calls. This status update documents real progress AND a real,
not-yet-resolved hardware blocker -- matching this project's own
established practice (see this file's own PCIe outbound-window bring-up
history) of committing solid partial progress with the exact blocker
characterized, rather than leaving debugging work undocumented mid-flight.

**New shared infrastructure landed (both reusable well beyond USB)**:
- `examples/common_rpi5/dma_asm.S` (`rpi5_dcache_clean_range`/
  `rpi5_dcache_invalidate_range`): every RP1 peripheral touched before
  this one was pure CPU-initiated MMIO (no caching involved). XHCI's own
  Command Ring/Event Ring/DCBAA are ordinary cacheable RAM, read/written
  by usbhost0/usbhost1 as a REAL DMA-capable PCIe bus master -- these
  two helpers (`dc cvac`/`dc civac` loops + `dsb sy`, cache line
  hardcoded to 64 bytes matching Cortex-A76/examples/common_rpi3/
  tlb_asm.S's own precedent) make CPU writes visible to DMA and DMA
  writes visible to the CPU. Needed by ANY future RP1 DMA peripheral,
  not just USB.
- `examples/common_rpi5/pcie.tkb`'s new `pcie2_dma_inbound_setup()`:
  the "add a general DMA window" future-work note
  `pcie2_mip0_inbound_setup`'s own comment had flagged. Uses RC_BAR2 (a
  SEPARATE Broadcom "brcmstb" inbound BAR slot from RC_BAR1, which stays
  MIP0/MSI-only per issue #164) to map PCI address `[0, 64MB)` directly
  onto CPU/system address `[0, 64MB)` -- confirmed structurally correct
  against Linux's own `pcie-brcmstb.c` (`set_inbound_win_registers()`/
  `brcm_bar_reg_offset()`/`brcm_ubus_reg_offset()`/
  `brcm_pcie_encode_ibar_size()`, fetched and cross-checked directly,
  including the BCM7712-specific UBUS remap branch that specifically
  applies to BCM2712). Register writes confirmed to stick via readback
  (`RC_BAR2_LO`/`UBUS_BAR2_LO` both read back exactly as written).

**Steps 1-5 (register reachability, USBSTS/PORTSC, extended
capabilities, USBLEGSUP, clean halt) remain fully verified and
unchanged** -- see the earlier status entries below for their own
details; Step 6 builds on top of them.

**Step 6 investigation so far** (`examples/rp1_usb_smoke/
rp1_usb_smoke.tkb`): programs DCBAA (with a real Scratchpad Buffer Array
-- HCSPARAMS2 reports Max Scratchpad Buffers=2, spec-required, not
optional), Command Ring (Enable Slot TRB + Link TRB), Event Ring (ERST +
interrupter registers), CONFIG.MaxSlotsEn, restarts the controller, and
rings the Command doorbell for Enable Slot. Findings, in the order
found:
1. **First attempt** (ERSTSZ -> ERDP -> ERSTBA order, no HCRST): no
   hang, but no Command Completion Event ever appeared. `ERDP`'s own EHB
   bit read back SET after the attempt, which first looked like proof an
   event WAS posted somewhere the dump missed -- but explicitly clearing
   EHB before ringing the doorbell and re-checking afterward showed it
   reads back UNSET, i.e. EHB going 0->1 earlier was most likely STALE
   state inherited from firmware's own prior use of this controller
   (this controller was found already running with a real device fully
   enumerated on port 3 by firmware -- see Step 2's own PORTSC3 finding
   below), not evidence of anything this example's own Enable Slot
   command triggered.
2. **Reordered to ERSTSZ -> ERSTBA -> ERDP** (matching Linux's own
   `xhci_add_interrupter()` in `drivers/usb/host/xhci-mem.c`, fetched
   and confirmed byte-for-byte) -- no change, same silent no-op.
3. **Added a real `USBCMD.HCRST`** (Host Controller Reset, not just an
   RS=0/RS=1 soft cycle) before reprogramming DCBAAP/CRCR/CONFIG:
   reasoning being that firmware left this controller not merely
   running but with a REAL device already fully addressed and
   configured on port 3 (a working internal device-context/event-ring
   state actively in use), which a soft RS-cycle does not guarantee
   gets discarded. HCRST self-clears and CNR clears normally (confirmed
   after only 2 polls). **This changed the symptom**: `USBSTS` after the
   subsequent failed Enable Slot attempt now reads `0x00001015` --
   `HCH=1` (halted), **`HSE=1` (Host System Error)**, **`HCE=1` (Host
   Controller Error)**, `PCD=1` (stale). `CRCR` reads back `0x00000000`
   (`CRR=0` -- the controller stopped itself, consistent with a fatal
   error auto-halting it).

**Where this stands**: HCRST turned a SILENT no-op into an EXPLICIT
hardware fault signal -- real progress (a controller with fully-cleared
internal state now properly detects and reports something going wrong,
where the dirty/inherited-state controller apparently didn't), but the
EXACT root cause of the fault is not yet identified. Leading candidates,
not yet individually tested in isolation:
- The new `pcie2_dma_inbound_setup()` inbound window, despite matching
  the reference driver structurally, could still have a wrong parameter
  (size encoding, alignment, or a BCM2712-specific quirk beyond what the
  fetched driver excerpt covered).
- The Scratchpad Buffer Array (Max Scratchpad Buffers=2, `SPR` bit also
  set in HCSPARAMS2 -- meaning unclear, not yet researched) could have
  a construction bug distinct from the main Command/Event Ring setup.
- Something about the Command Ring TRB or Link TRB construction itself,
  independent of the DMA-reachability question entirely.

**Next step**: isolate which of the above is actually at fault --
e.g. temporarily testing with Scratchpad Buffers omitted (spec
violation, but diagnostically informative) to see whether HSE/HCE
persists, or re-verifying the inbound window with a deliberately much
larger or PCI-address-shifted test to rule out an alignment/off-by-one
in `pcie2_dma_inbound_setup()`.

Direct follow-on to Step 4. This is the first genuinely state-changing
action in the whole USB bring-up effort so far (Steps 1-4 were all
read-only) -- per the XHCI spec, `DCBAAP`/`CRCR` (needed later for a
real `Enable Slot` command) may only be written while the controller is
halted, but Step 2 found it already running (firmware/TF-A left
`USBCMD.RS` set at handoff, per Step 4's own `USBLEGSUP` finding that no
ownership handoff was ever negotiated). So this step does ONLY a clean
halt, nothing further yet.

Sequence: read `USBCMD` (Operational base + 0x00) = `0x0000000d` (`RS`
bit0=1 running, `INTE` bit2=1, `HSEE` bit3=1). Read-modify-write to
clear only bit0 (`RS`) -> wrote `0x0000000c`, confirmed by reading
`USBCMD` back afterward -- exactly the expected value, `INTE`/`HSEE`
correctly preserved. Poll `USBSTS.HCH` (bit0) in a bounded loop (100
iterations x 1ms `delay_us`, a real timed wait matching issue #169's own
"iteration counts aren't real time" lesson, not a busy-spin count):
**halted after only 2 polls** (~1-2ms, well within the xHCI spec's own
expected halt latency). `USBSTS` read back afterward as `0x00000019` --
`HCH` bit0=1 confirms the halt, `EINT`/`PCD` (bits3/4) still set from
the earlier port-change event, harmless and expected (interrupt-status
bits, not blocking).

Confirmed reproducible across two consecutive real-hardware runs --
byte-for-byte identical `USBCMD`/`USBSTS` values and poll count both
times. **No hang, no bug, no surprise** -- a genuinely clean result for
the first write against brand-new hardware.

**Next step (not started)**: with the controller now confirmed halted,
set up `DCBAAP` (Device Context Base Address Array Pointer,
Operational+0x30, 64-bit -- needs a real, aligned physical buffer, not
yet allocated anywhere in this example) and `CRCR` (Command Ring
Control Register, Operational+0x18, 64-bit -- needs a real Command Ring
buffer too, plus its own Cycle Bit convention). `CONFIG` (Operational
register, `MaxSlotsEn` field) should also be set before re-enabling
`USBCMD.RS`. Only once the controller is running again with a real
Command Ring can an `Enable Slot` command actually be issued for the
USB flash drive already sitting on port 3 -- and reading its own
Command Completion Event back requires the Event Ring (ERST/interrupter
registers at `RTSOFF`) to be set up too, which hasn't been touched at
all yet. This is a bigger step than any so far (needs real memory
buffers, not just register pokes) -- plan for its own dedicated,
carefully-staged pass.

User confirmed the device found live on `usbhost0` port 3 (Step 2) is a
real USB flash drive plugged into the board's own USB-A port -- exactly
the target device class needed for `el0_shell`'s eventual Mass Storage +
FAT12 work, not a red herring.

**Step 4** (still read-only): decoded `USBLEGSUP` (USB Legacy Support
Capability, Capability ID 1 -- already read in Step 3 as
`raw=0x00000401` at ext cap offset `0x900`, just not decoded yet):
`bios_owned=0`, `os_owned=0`. Neither ownership semaphore is set --
unlike a PC platform, where BIOS hands the controller to an OS driver
through this exact mechanism, RP1/TF-A appears to just leave the
controller running without ever engaging it, consistent with Step 2's
own finding that `USBCMD.RS` was already set at handoff with no
apparent ownership negotiation. Also read `DBOFF` (Doorbell array
offset, Capability+0x14) = `0x500` and `RTSOFF` (Runtime register space
offset, Capability+0x18) = `0x460` -- both standard XHCI Capability
registers, needed later to ring the Command doorbell and configure the
Event Ring's interrupter registers. Confirmed reproducible across two
consecutive real-hardware runs, no hang.

**Next step (not started, first real WRITE)**: per the XHCI spec,
`DCBAAP`/`CRCR` may only be written while the controller is halted
(`USBCMD.RS=0`), but Step 2 found it already running
(`USBSTS.HCH=0`) -- so the next real increment is a clean halt
(`USBCMD.RS=0`, then poll `USBSTS.HCH` until it reads 1) BEFORE any
register programming, not skipping straight to `DCBAAP`/`CRCR`/`CONFIG`
as if the controller were already idle. This is the first genuinely
state-changing action against this hardware in the whole USB bring-up
effort so far -- deserves its own careful, individually-verified,
checkpoint-instrumented pass, not folded into a read-heavy step like the
four before it.

## Status update (2026-07-26, earlier): USB bring-up, Steps 2-3 --
## `rp1_usb_smoke` reads USBSTS/PORTSC and walks the xHCI Extended
## Capabilities list; found a REAL device already connected on
## `usbhost0` port 3

Direct follow-on to Step 1 (Capability register reachability, below).
Both steps read-only, no controller reset or state change yet, same
checkpoint-instrumented safety discipline.

**Step 2**: standard XHCI Operational registers (Capability base +
CAPLENGTH), no `usbhost*_cfg` dependency needed -- that block's own
register layout is NOT documented in the datasheet's USB chapter at
all (unlike its GPIO/PWM chapters' own detailed "List of registers"
subsections), so this step deliberately routes around that gap via
registers the public XHCI spec itself defines, rather than guessing at
RP1-specific "cfg" semantics. Real results (reproducible across two
runs): `usbhost0` `USBSTS=0x18` -- `CNR=0` (controller ready) and
`HCH=0` (**NOT halted** -- firmware/TF-A already left `USBCMD.RS` set
before handoff; this bare-metal payload never started it itself).
`PORTSC1`/`PORTSC2` both read `0x2a0` (`PP=1` powered, `PLS=5`
RxDetect, `Speed=0` -- ordinary idle/nothing-connected). `PORTSC3`
reads `0x21203`: `CCS=1` **connected**, `PED=1` **enabled**, `PLS=0`
**U0 (fully operational link)**, `Speed=4` -- something is live and
already enumerated by firmware on `usbhost0` port 3. `usbhost1` shows
all three ports idle and `USBSTS=0`.

**Step 3**: walked the xHCI Extended Capabilities list (pointed to by
`HCCPARAMS1`'s `xECP` field) looking for Capability ID 2 ("Supported
Protocol Capability", public xHCI spec) to resolve an open question
Step 2 raised -- the datasheet says each controller has only 2 PHYs (one
USB2, one USB3), so why does `HCSPARAMS1` report `MaxPorts=3`? Answer,
read directly off real hardware rather than guessed: `usbhost0`'s
extended capability list is `[ID=1 (Legacy Support), ID=2 major_rev=2
port_offset=1 port_count=2, ID=2 major_rev=3 port_offset=3
port_count=1]` -- ports 1-2 are the USB2 logical ports, port 3 is the
USB3 logical port. This is standard XHCI modeling (a physical connector
with combined USB2+USB3 signaling shows up as two SEPARATE logical
port numbers, one per protocol), not an RP1 quirk. So the "device
already connected" found in Step 2 is specifically a **SuperSpeed (USB
3.0) device** on `usbhost0`'s USB3 logical port. Confirmed reproducible
across two consecutive real-hardware runs, no hang either time.

**Open question for the user**: is there a real USB device physically
plugged into one of the Raspberry Pi 5 board's own USB-A ports right
now (not the Debug Probe, which connects to the HOST machine over a
separate cable, not RPi5's own ports)? If so, this is a strong, useful
signal for the next real milestone (actual device enumeration) -- worth
confirming before investing in reset/enumeration work against a port
whose "device" might otherwise be a red herring.

**Next step (not started)**: a real, careful `USBCMD.HCRST` (Host
Controller Reset) is the natural next increment ONLY if reusing
firmware's already-running state turns out to be undesirable; more
likely, the next real step is setting up `DCBAAP` (Device Context Base
Address Array Pointer) and the Command Ring (`CRCR`) so an `Enable
Slot` command can be issued for the already-connected device on port 3
-- real device enumeration is still several careful, individually-
verified steps away.

## Status update (2026-07-26, earlier): USB bring-up STARTED --
## `rp1_usb_smoke` proves real-hardware reachability of RP1's XHCI
## controllers (GitHub issue #67 follow-up, `el0_shell`'s own USB
## blocker)

User asked to start USB support (RPi3 has it; RPi5 does not), to
eventually unblock `el0_shell` (needs USB Mass Storage + FAT12 to fetch
a real busybox-static binary) and, after that, Ethernet -- explicitly
requested as small, incremental, real-hardware-verified steps, not a
single large jump.

**First finding, before writing any code**: fetched the official
Raspberry Pi RP1 Peripherals datasheet
(`https://datasheets.raspberrypi.com/rp1/rp1-peripherals.pdf`, saved and
read locally via `pdftotext`, since `WebFetch`'s own PDF summarizer
failed to extract readable text from it) rather than guessing register
layouts. Chapter 5 (USB): "The USB Host subsystem is based on Synopsys
IP dwc_usb3, v3.30b. There are two identical USB3.0 xHCI Host
Controllers conforming to the Extensible Host Controller Interface
Specification v1.2." This is a REAL XHCI controller -- materially
bigger driver scope than the DWC2 OTG controller this file's own earlier
"do not port RPi3's USB host stack" note had implicitly assumed a future
RP1 USB port might need; TRB rings, event rings, command rings, device
context arrays, and port/slot state machines are all real XHCI-spec
requirements, not simplifications available here. User was informed of
this scope jump explicitly and chose to proceed incrementally anyway.

**Register addresses (datasheet Table 85, section 5.1)**: `usbhost0`
(main XHCI MMIO, AXI3 bus, Atomic Access: N -- plain reads, no special
aliasing) at RP1-internal `0x40200000`; `usbhost1` at `0x40300000`.
Derived the RP1-internal-to-CPU-physical mapping empirically from a
value already proven working: `uart0` is RP1-internal `0x40030000`
(datasheet Table 22) and `examples/common_rpi5/uart.tkb` already uses
CPU physical `0x1F00030000` for it, so `CPU_PHYS = RP1_INTERNAL +
0x1EC0000000` -- giving `usbhost0` = CPU physical `0x1F00200000`,
`usbhost1` = `0x1F00300000`. Both addresses already fall inside
`examples/common_rpi5/mmu.S`'s existing L1[124..127] 4GB RP1 outbound
window (no new MMU/PCIe work needed at all), and RP1 BAR/PCIe bring-up
already runs unconditionally via `platform_init` for every RPi5 kernel
-- the same reason `rp1_uart0` already works everywhere without an
explicit init call.

**`examples/rp1_usb_smoke`** (new, standalone diagnostic, NOT added to
`make hwcheck-rpi5`'s automated suite -- same precedent as
`rp1_pcie_smoke`, a bring-up tool, not a regression test): reads the
standard XHCI Capability register block (CAPLENGTH/HCIVERSION/
HCSPARAMS1-3/HCCPARAMS1) from both controllers, read-only, no resets or
state changes, same checkpoint-instrumentation safety technique
`rp1_pcie_smoke` established (a global written before each step, so a
hang's last-reached step is SWD-readable). **Passed on the first
real-hardware attempt, no hang, no bug**: `HCIVERSION=0x0110`,
`usbhost0` `HCSPARAMS1=0x03000440` -- MaxSlots (bits 7:0) = `0x40` = 64,
MaxIntrs (bits 18:8) = 4 -- both EXACTLY matching the datasheet's own
claims ("support 64 device slots", "Four interrupt vectors are provided
per controller"), strong confirmation this is reading real, correct
silicon, not a bus-timeout poison pattern. `usbhost1` reports
byte-identical CAPLENGTH/HCIVERSION/HCSPARAMS1, matching "two identical"
controllers. Confirmed reproducible across two consecutive real-hardware
runs (byte-identical output both times).

**Next step (not yet started)**: read `usbhost0_cfg`/`usbhost1_cfg`
(datasheet Table 85, APB bus, Atomic Access: Y -- addresses not yet
looked up) to understand what clock/power/reset control they offer
before attempting any real XHCI controller reset (`USBCMD.HCRST`) or
port status register access -- the Capability registers answering
correctly does not by itself prove the controller is fully clocked/
out-of-reset for operational-register-level activity, only that ITS OWN
register block is reachable. A real device enumeration (Enable Slot ->
Address Device -> Get Descriptors) and a Mass Storage Bulk-Only
Transport driver are both still far ahead of this first step.

Direct follow-on to the minimal port below. User asked to pick whichever
of "full `el0_elf_load`" or "`el0_shell`" was easier to start next;
`el0_shell` was ruled out immediately -- it `use`s `fat12_usbmsc.tkb`
(real USB Mass Storage + FAT12, needed to fetch the real busybox-static
binary via GitHub issue #157's VFS bridge), and this repo's own
`common_rpi5/AGENTS.md` already declares USB explicitly out of scope
(RPi3's own USB host stack was deliberately not ported). So the full
`el0_elf_load` port -- which `el0_shell` itself builds on top of, one
layer up -- was the genuinely available next step.

Ported `ProcessAddressSpace`/`process_address_space_map`/
`process_address_space_unmap` into `vm_page_map_core_rpi5.tkb` (a
coarse-grained, runtime-sized multi-page owner, GitHub issue #156) --
NOT `process_address_space_cow_fork`/`unmap_shared` (issue #158's real
fork()-specific COW sharing, still out of scope) and, matching RPi5's
existing single-slot design, `process_phys_indices` is one flat array,
not RPi3's slot-0/slot-1 pair. `el0_elf_load_rpi5.tkb` itself was
rewritten IN PLACE (not kept as two separate files) to the full scope:
real multi-page ELF loading via `process_address_space_map`, `hvc`-based
`exit()` teardown (`hvc_dispatch`/`process_vm_put`/`process_vm_take`,
`examples/common_rpi5/hvc_asm.S` now linked into this kernel), and the
same ~20-syscall table RPi3's own current file has (`read`/`write`/
`writev`/`ppoll`/`newfstatat`/`set_tid_address`/`gettid`/`getpid`/
`getppid`/`getuid`/`geteuid`/`getgid`/`getegid`/`set_robust_list`/
`rt_sigaction`/`rt_sigprocmask`/`prctl`/`rseq`/`chdir`/`ioctl`/
`getrandom`/`brk`/`mmap`/`mprotect`/`getcwd`/`uname`/`exit`) --
reproduced verbatim from RPi3's own issue #156 research (empirical,
strace-driven; not re-derived independently here), with every
`rpi3_*`/`.slot` reference adapted to RPi5's own `rpi5_*` externs and
slot-less `AddressSpaceOwner`.

`examples/common_rpi5/el0_test_prog.S` had its earlier single-page
trimming REVERTED: the same 6000-byte dead-padding RPi3's own copy uses
(to genuinely force the ELF past one page and exercise the multi-page
path) was added back -- this test binary now supersedes the earlier
single-page one in place too, the same "evolve, don't fork" choice as
`el0_elf_load_rpi5.tkb` itself.

Output is now byte-for-byte identical to RPi3's own `el0_elf_load`
fixture (including the `"hvc: process VM reclaimed"` line), so the
RPi5-specific `.expected` file created for the minimal port was deleted
and RPi3's own `el0_elf_load.expected`/`el0_elf_load.stdin` are reused
directly, matching the `el1_smoke`/`hvc_smoke` fixture-reuse precedent.

**Passed on the FIRST real-hardware attempt, no new bug.** `make
hwcheck-rpi5` passes 55/55, confirmed across two consecutive
real-hardware runs.

## Status update (2026-07-26, earlier -- SUPERSEDED by the full port
## above): `el0_elf_load` ported (real ELF+cpio loader, GitHub issue #67
## Stage 2 follow-up), deliberately scoped to RPi3's own original
## single-page issue #153 milestone, no new bug, `make hwcheck-rpi5`
## 55/55 at that point

Direct follow-on to `el0_smoke`. RPi3's own current `examples/
el0_elf_load/el0_elf_load.tkb` has grown, via GitHub issue #156, from its
original single-page Stage 1 scope (ELF+cpio parsing, read/write/exit)
into a ~1100-line loader with multi-page `ProcessAddressSpace` mapping,
`hvc`-triggered teardown, and a ~20-syscall busybox-shell-ready surface
(`writev`/`ppoll`/`newfstatat`/`brk`/`mmap`/`mprotect`/`uname`/...). User
consulted explicitly on scope (this jump in size, unlike every prior
RPi5 step, was NOT comparable to el1_smoke/hvc_smoke/vm_page_map/
el0_smoke) and chose the minimal, original-Stage-1-equivalent scope:
real cpio+ELF parsing into the SAME single `DYN_VA_BASE..DYN_VA_LIMIT`
page `examples/el0_smoke_rpi5` already proved (`map_page_el0_exec`,
`vm_page_map_core_rpi5.tkb` needed zero changes), read/write/exit only,
no `ProcessAddressSpace`/multi-page generalization, no `hvc` teardown
(mapping/space/active tokens abandoned on exit, same idiom
`el0_smoke_rpi5.tkb` already uses).

`examples/common_rpi5/el0_test_prog.S`/`.ld` are a trimmed copy of
RPi3's own hand-written test ELF (argv/auxv/PIE-auxv validation, `write`/
`read`-loop/`exit`), with RPi3's own deliberate 6000-byte dead-padding
(added there specifically to force a multi-page load, proving issue
#156's own generalization) removed -- confirmed via a real build +
`readelf -l` that the trimmed binary still gets 6 program headers (three
`PT_LOAD` plus `PT_DYNAMIC`/`PT_GNU_RELRO`/`PT_GNU_STACK`, since `-pie`
always emits those three regardless of `.text` size), so
`el0_test_prog.S`'s own `AT_PHNUM` self-check needed no change from
RPi3's value even after trimming -- only the padding differs.
`el0_test_image.S`/`_extern.tkb` and the `cpio`-archive Makefile rule are
straight, target-independent ports of RPi3's own build shape.
`examples/el0_elf_load/el0_elf_load_rpi5.tkb` keeps the PIE load-bias
computation (still needed, the test binary IS PIE) but caps everything
at one page (`max_extent > PAGE_SIZE - ARGV_LAYOUT_SIZE` fails loudly
instead of falling back to multi-page). Own `.expected` fixture (not
byte-identical to RPi3's -- no `"hvc: process VM reclaimed"` line, since
this port has no `hvc` teardown), but the SAME shared, target-independent
`el0_elf_load.stdin` fixture (`"AB\n"`).

Two Takibi type-system findings while porting (both mechanical, not
design bugs): (1) `let page_va: {DYN_VA_BASE..<DYN_VA_LIMIT as usize} =
DYN_VA_BASE;` did not type-check ("unproven usize") even though the
SAME range as a function parameter type already worked fine -- the
checker only recognizes a literal on the right-hand side as proof of
membership in a refined range on the left, not a named `const` reference
to the identical value; fixed by using the literal `0x40000000` directly,
matching `el0_smoke_rpi5.tkb`'s own established convention. (2) indexing
`mapping_bytes`'s own array-typed return (`[u8; PAGE_SIZE..] @ p`) with
an `as isize`-cast index failed ("array/slice index must be usize") --
RPi3's own loader indexes a raw `*u8` pointer there instead (needs
`isize`), but this port's single-page design uses `mapping_bytes`
directly (matching `el0_smoke_rpi5.tkb`), so the index needed to stay
plain `usize`.

**Passed on the FIRST real-hardware attempt, no new bug** (once past an
unrelated USB/CMSIS-DAP transient: the Debug Probe -- itself an
RP2040/Pico running CMSIS-DAP firmware -- dropped off the host's USB bus
entirely between the first and second confirmation runs; `authorized`
toggling was blocked by this container's read-only `/sys` mount, and a
`USBDEVFS_RESET` ioctl via the raw `/dev/bus/usb/003/030` node --
reachable without `sudo` via the `plugdev` group -- found the device
already gone, "No such device"; a physical cable reconnect from the user
was what actually brought it back). `make hwcheck-rpi5` passes 55/55,
confirmed across two consecutive real-hardware runs (with that one
non-hardware, non-test-related USB interruption in between).

## Status update (2026-07-26, earlier): `el0_smoke` ported (EL1->EL0 drop +
## real SVC trap boundary, GitHub issue #67 Stage 2 follow-up), a real
## EL1/EL2 cache-coherency bug found and fixed, `make hwcheck-rpi5` 54/54

Direct follow-on to `el1_smoke`/`vm_page_map`: `examples/common_rpi5/
el0_asm.S` ports `examples/common_rpi3/el0_asm.S`'s proven EL1->EL0 drop
and real SVC trap mechanism (a tiny hand-written, independently-assembled
EL0 payload issues `write`/`exit` via `svc #0`), minus GitHub issue
#158's later fork()-specific additions (`rpi3_el0_resume_frame`, the
`frame_sp`/`far` extra `el0_svc_dispatch` parameters, `SP_EL0` preserved
in the saved frame) -- not needed for this milestone, same "port only
what this needs" reasoning as `tlb_asm.S`. `examples/common_rpi5/
el1_asm.S`'s vector table gained a real wire-up: the Lower-EL-AArch64-
Synchronous slot now branches to a weak `el0_sync_entry` default (spin),
strongly overridden by `el0_asm.S`, matching `startup.S`'s own
`rpi5_irq_dispatch` weak/strong pattern. `examples/vm_page_map/
vm_page_map_core_rpi5.tkb` gained `map_page_el0_exec` (same PTE write as
`map_page`, `PTE_FLAGS_EL0_RW`/`0x747` instead of `PTE_FLAGS_EL2_RW` --
AP[1] grants EL0 access; no separate "exec" bit exists, pages are
executable by default unless UXN/PXN is set). `examples/el0_smoke/
el0_smoke_rpi5.tkb` is a separate small source, same "not a portable
literal" reasoning as `vm_page_map_rpi5.tkb`; output byte-identical,
RPi3's `.expected` fixture reused unchanged.

**A real bug found and fixed, a genuinely new hazard shape (not a
copy-paste variant of the TCR_EL1.IPS bug)**: the first real-hardware
attempt printed only `el0_smoke\n`, then hung -- `hi from el0\n` never
arrived. SWD found the core parked inside `el0_sync_entry`'s own
unhandled-park loop (PC `0x202150`) with `ESR_EL1=0x02000000` (EC=0,
"Unknown reason") and `ELR_EL1=0x1018` -- EL0 had trapped from a bogus,
uninitialized-looking PC, not from the real payload at `0x40000000`.
Adding a temporary debug `uart_print` to `el1_main` confirmed the root
cause directly: `app_main` (at EL2) printed the freshly assigned
`el0_entry_va=1073741824` (`0x40000000`) right after `map_page_el0_exec`,
but `el1_main` (at EL1, reached via `rpi5_el1_enter`'s EL2->EL1 drop)
read the SAME global back as `0`. Root cause: `el1_asm.S`'s `SCTLR_EL1`
setup left D-cache/I-cache OFF, with a comment claiming this "matched
`mmu.S`'s own current EL2 steady state" -- true when issue #163 first
wrote this file, false by the time it shipped (issue #169 had already
turned EL2's caches ON) and nobody re-checked the claim afterward. With
EL2's D-cache on and EL1's off, EL2's store to `el0_entry_va` could sit
dirty in cache, invisible to EL1's own uncached read of the same
physical location -- `el0_smoke` is the first RPi5 example whose EL1
code reads data an EL2 phase wrote moments earlier, so `el1_smoke`/
`hvc_smoke` never exercised this path. Fixed: `SCTLR_EL1` now also
enables C/I, matching EL2's real current state and restoring ordinary
same-core cache coherency across the transition. **Lesson**: a code
comment asserting two files are "in sync" is only as reliable as the
last time someone actually re-checked it after either side changed --
`mmu.S`'s cache policy changed (issue #169) without anyone revisiting
`el1_asm.S`'s copy of the same claim.

`make hwcheck-rpi5` passes 54/54, confirmed across two consecutive
real-hardware runs. This was the last item RPi3's own staged bring-up
order needed before EL0 process work could begin on RPi5.

## Status update (2026-07-26, earlier): `vm_page_map` ported (dynamic
## single-page mapping, GitHub issue #67 Stage 2), no new bug, `make
## hwcheck-rpi5` 53/53

Prerequisite for a future `el0_smoke` port (EL1->EL0 drop + real SVC trap
boundary needs a real, non-identity VA-to-PA translation to demonstrate
against). `examples/vm_page_map/vm_page_map_core.tkb` has grown well
beyond Stage 2's own original scope on RPi3 (process address spaces,
copy-on-write, fork/exec, task migration -- issues #153/#156/#158/#159),
so rather than port that whole file, this milestone writes a much smaller,
purpose-built `examples/vm_page_map/vm_page_map_core_rpi5.tkb` containing
only what `vm_page_map_rpi5.tkb` itself calls: the page-pool allocator and
a single-slot `AddressSpaceOwner` state machine
(`address_space_new`/`activate`/`deactivate`/`free`,
`map_page`/`tlb_invalidate`/`mapping_bytes`/`unmap_page`). RPi3's version
tracks two hardware address-space slots (`l1_table`/`l1_table_as1`, issue
#67 Stage 4); RPi5's `mmu.S` has only one translation root, so the ported
`AddressSpaceOwner` drops the `slot` field entirely and
`address_space_activate`/`deactivate` become pure type-state bookkeeping
with no `TTBR0_EL2` write and no TLB flush -- there is nothing to
reprogram when the only root is already the one in use. The
Inactive/Empty/Occupied state machine itself is unchanged: it still makes
mapping a second page before unmapping the first a compile error.

`examples/common_rpi5/mmu.S` gained a new L1[1] table-descriptor chain
(0x40000000-0x7FFFFFFF, only L2[0]/2MB populated, same 2MB-window shape as
RPi3's own L1 entry 2 at 0x80000000 -- index differs only because RPi5's
L1 already claims 0, 64, 65, and 124-127) plus the `l3_dynamic_write`
accessor, both direct ports of RPi3's own `l2_dynamic_table`/
`l3_dynamic_table`/`l3_dynamic_write`. `examples/common_rpi5/tlb_asm.S` is
new, but intentionally minimal: only `tlb_invalidate_va` is ported.
RPi3's copy also carries `tlb_invalidate_asid_va`, `tlb_invalidate_all_el2`,
and a conditional second `tlbi vaae1is` gated on an EL1&0-regime-active
flag (issue #158's fork/exec work) -- none of that applies yet, since
`vm_page_map_rpi5.tkb` is EL2-only and there is no second slot to flush,
mirroring RPi3's OWN history where that machinery was added later, not
present in the original Stage 2 work. `examples/vm_page_map/
vm_page_map_rpi5.tkb` is a separate small source from RPi3's
`vm_page_map.tkb` (same "not a portable literal" reasoning as
`el1_smoke_rpi5.tkb`: the RPi3 file hardcodes `0x80000000`/`0x80200000`
literals inline, not just a `use` of a differently-shaped core), but the
printed output does not depend on the VA window's address, so RPi3's own
`vm_page_map.expected` is reused unchanged.

**Passed on the FIRST real-hardware attempt, no new bug.** `make
hwcheck-rpi5` passes 53/53, confirmed across two consecutive real-hardware
runs.

## Status update (2026-07-26, earlier): `hvc_smoke` ported (EL1->EL2 hvc
## call), no new bug -- `el1_smoke`'s own TCR_EL1.IPS fix already covered
## it, `make hwcheck-rpi5` 52/52

Direct follow-on to `el1_smoke`: `examples/common_rpi5/hvc_asm.S` ports
`examples/common_rpi3/hvc_asm.S`'s proven EL1->EL2 privileged
call-and-return (`rpi5_hvc_call` issues `hvc #0` from EL1;
`el1_hvc_entry`, reached via `startup.S`'s own "Lower EL AArch64
Synchronous" vector slot at EL2, saves a full frame, calls the
Takibi-compiled `hvc_dispatch` override, restores, and `eret`s back to
EL1). `startup.S`'s exception vector table now wires that slot to
`el1_hvc_entry`, with a weak spin-only default (matching
`rpi5_irq_dispatch`'s own weak/strong pattern) so every OTHER RPi5
kernel that never links `hvc_asm.o` still resolves the branch target at
link time -- truly dead code for them, since nothing else issues `hvc`.
`examples/hvc_smoke/hvc_smoke_rpi5.tkb` is a separate small source, same
"not a portable public HAL name" reasoning as `el1_smoke_rpi5.tkb`;
output byte-identical, RPi3's `.expected` fixture reused unchanged.

**Passed on the FIRST real-hardware attempt, no new bug** -- unlike
`el1_smoke`, which needed `TCR_EL1.IPS` fixed before `uart_putc`'s own
MMIO write would work at EL1 at all. `hvc_smoke`'s `el1_main` prints
both BEFORE and AFTER the `hvc` call at EL1 (`hvc_dispatch` itself
prints at EL2, already correctly configured since `mmu.S`'s own issue
#165 work); both EL1-side prints reuse the exact same `rpi5_el1_enter`
translation-regime setup `el1_smoke` already exercises, so the earlier
fix already covered this milestone's own needs -- nothing new to find.
`make hwcheck-rpi5` passes 52/52, confirmed across two consecutive
real-hardware runs.

## Status update (2026-07-26, earlier): `el1_smoke` ported (EL2->EL1
## drop), a second real bug found, `make hwcheck-rpi5` 51/51 at that
## point

Natural follow-on to issue #163: `examples/common_rpi5/el1_asm.S` ports
`examples/common_rpi3/el1_asm.S`'s proven EL2->EL1 drop mechanism
(reuse `TTBR0_EL2` as EL1&0's own `TTBR0_EL1`, configure `TCR_EL1`/
`MAIR_EL1`/`VBAR_EL1`, `eret` into ordinary Takibi code at EL1). A
separate small source file, `examples/el1_smoke/el1_smoke_rpi5.tkb`,
not a reuse of `examples/el1_smoke/el1_smoke.tkb` -- that file hardcodes
`use "examples/common_rpi3/el1_asm_extern.tkb"` and calls RPi3's own
`rpi3_el1_enter`, a symbol five different RPi3 files depend on, not a
portable public HAL name; output is byte-for-byte identical, so
`el1_smoke.expected` is reused unchanged.

**A second real hardware bug found and fixed, same shape as issue
#163's**: the first real-hardware attempt printed `el1_smoke\n` (from
EL2, before the drop) then hung -- `hello from EL1\n` never arrived.
Halting over SWD found the core genuinely AT `EL1H` with its MMU
enabled (the drop itself worked!), parked at
`rpi5_el1_vectors+0x200` (the "Synchronous (EL1h)" vector's own
unconditional spin). `ESR_EL1`/`ELR_EL1` (both directly readable by
name via `reg`, unlike `ESR_EL2`/`HCR_EL2` which needed the register-
probe workaround documented elsewhere in this file) showed
`ESR_EL1=0x96000001` (EC=0x25, same-EL Data Abort; DFSC=`0b000001`,
"Address size fault, level 1") with `ELR_EL1` pointing inside
`uart_putc`. Root cause: `TCR_EL1` never set `IPS` (bits[34:32],
Intermediate Physical Address Size) -- left at its default (0, 32-bit).
RPi3's own `el1_asm.S` never needs this either, because BCM2837 only
ever needs 32-bit PA (`TCR_EL2.PS=000` there too), but BCM2712's own
`l1_table` (reused as-is via `TTBR0_EL1 := TTBR0_EL2`) has real L1
block descriptors with output addresses at `0x10_xxxxxxxx` and
`0x1F_xxxxxxxx` -- both well beyond a 32-bit/4GB boundary. Leaving
`TCR_EL1.IPS` at 32-bit while reusing a table built for `TCR_EL2.PS=010`
(40-bit) made EL1's own translation regime reject those same block
descriptors as exceeding ITS configured PA size the moment
`uart_putc`'s first RP1-UART MMIO write walked through `L1[124]`.
Fixed: `TCR_EL1` now also sets `IPS=0b010` (a second `movk` into the
`[47:32]` lane), matching `TCR_EL2`'s own `PS` field.

`make hwcheck-rpi5` passes 51/51, confirmed across two consecutive
real-hardware runs.

## Status update (2026-07-26, earlier): MPIDR_EL1 core numbering --
## GitHub issue #163, a real bug found and fixed, `make hwcheck-rpi5`
## 50/50 at that point

`examples/common_rpi5/startup.S`'s core-selection gate assumed, by
analogy with RPi3, that MPIDR_EL1's Aff0 field (bits[7:0]) is BCM2712's
plain 0-3 core number. **That assumption was wrong**, confirmed by
directly reading MPIDR_EL1 on all four `bcm2712.cpuN` OpenOCD targets:

```
cpu0: 0x81000000   cpu1: 0x81000100   cpu2: 0x81000200   cpu3: 0x81000300
```

Aff0 (bits[7:0]) is `0x00` on every core. The field that actually varies
1:1 with the core number is Aff1 (bits[15:8]). Bit 24 (MT -- "Aff0
describes a thread within a core, not the core itself") is set on every
read, which is exactly why: BCM2712 numbers its 4 physical cores in
Aff1, using the MT-style affinity encoding, unlike BCM2837's flat Aff0
numbering RPi3's own `startup.S` correctly relies on. The old `and x0,
x0, #3` therefore computed **0 on every core, not just core 0** -- never
observable before now because TF-A hands off only core 0 to takibi code
(cores 1-3 sit parked in TF-A's own EL3 idle loop at a low PC,
confirmed directly, never reaching `_start` at all) -- but it would
have been a real bug (every core believing itself to be core 0,
concurrently running `main()`) the instant any future milestone used
PSCI `CPU_ON` to actually release a secondary core here. Fixed: shift
right 8 before masking, extracting Aff1 instead of Aff0.

**Verification method, real hardware, zero risk to TF-A's own live
state**: `scripts/rpi5_check_core_topology.sh` (new, reusable, opt-in --
not part of `make hwcheck-rpi5`) redirects each HALTED core's own PC to
a tiny scratch-RAM probe (`examples/common_rpi5/smp_probe.S`: `mrs x0,
mpidr_el1` then `wfe`/spin), single-steps through it, reads `x0` back,
then restores the core's ORIGINAL PC and resumes it -- never touching
TF-A's own code, memory, or PSCI state, only reading a side-effect-free
ID register. Confirmed by re-running immediately after: a completely
normal `make hwcheck-rpi5`-style injection onto cpu0 still worked. Two
PSCI calls were tried FIRST and found unreliable for this purpose before
settling on the read-only redirect-and-step approach: `CPU_ON`
(0xC4000003) returned `ALREADY_ON` (-4) for every `target_cpu` value
tried, including obviously out-of-range ones (100), and
`AFFINITY_INFO` (0xC4000004) returned `ON` (0) for every value too --
this TF-A/BL31 build's minimal PSCI implementation does not appear to
validate or usefully distinguish `target_affinity` inputs, so it could
not be used as a topology oracle.

**`make hwcheck-rpi5` still passes 50/50** after the fix, unchanged
from before -- cpu0's own selection outcome is identical either way
(Aff1=0 selects `.Lcore0` exactly as Aff0=0 used to), so this is a pure
correctness fix for not-yet-exercised secondary-core behavior, not an
observable behavior change for any existing test. Issue #163's
acceptance criteria are met: MPIDR_EL1 recorded for all four cores, the
`startup.S` mask corrected, and a repeatable, documented,
non-destructive OpenOCD procedure verifies one running core and three
parked ones.

## Status update (2026-07-26, latest): RP1 UART0 RX interrupt -- GitHub
## issue #164, `make hwcheck-rpi5` 50/50

The first RPi5 interrupt path is now implemented and hardware-proven,
deliberately narrowed to the concrete source used by `examples/echo` and
`examples/irq`:

```
RP1 UART0 local IRQ 25 -> RP1 MSI-X vector 25 -> PCIe2 RC_BAR1
  -> BCM2712 MIP0 input 25 -> GIC SPI 153 / architectural INTID 185
  -> CPU0 EL2 Current-EL-SPx IRQ
```

`intc.tkb` configures that one MSI-X/MIP0/GIC route and performs RP1's
level-source IACK after `uart_irq_handler`; `pcie.tkb` adds only MIP0's
4KB MSI inbound mapping, not a general DMA/MSI subsystem. `startup.S`
sets `HCR_EL2.IMO` and gives only the Current-EL-SPx IRQ vector a full
x0-x30/ELR/SPSR frame. HVC, lower-EL, FIQ, and unrelated interrupt-source
support remain deliberately out of scope.

Both kernels compile under `--forbid-trap`. **`make hwcheck-rpi5` passes
50/50 on the real board**, including exact-output GPIO14/15 UART input
tests for both `echo` and `irq`, with all 48 prior tests still green. The
applications wait with `interrupt_wait()` and only the ISR reads PL011
`DR`, so these tests exercise the real asynchronous IRQ path rather than
a polling receive fallback.

## Status update (2026-07-26, later): `rtc`/`timer` ported -- GitHub
## issue #170, `make hwcheck-rpi5` 48/48

`examples/common_rpi5/rtc.tkb` is a straight port of
`examples/common_rpi3/rtc.tkb`'s HAL (`rtc_init`/`rtc_is_running`/
`rtc_read_seconds` over `CNTPCT_EL0`/`CNTFRQ_EL0`) -- no new hardware
bring-up at all, since `examples/common_rpi5/timer_asm.S`'s
`read_cntfrq`/`read_cntpct` already existed and were already
hardware-proven (issue #169, for `pcie.tkb`'s own real-time delays).
The only real work was avoiding a duplicate-`extern`-declaration
conflict: `pcie.tkb` used to declare `read_cntfrq`/`read_cntpct` itself,
and takibi rejects a second `extern fn` of the same name even with an
identical signature, so both externs moved into a new shared
`examples/common_rpi5/timer_asm_extern.tkb` (mirroring
`examples/common_rpi3/timer_asm_extern.tkb`'s own split, done there for
the identical reason) that both `pcie.tkb` and `rtc.tkb` `use`.
`examples/rtc`/`examples/timer` needed no interrupt/GIC work
whatsoever -- pure polling, same as every other target's own RTC HAL.

**`make hwcheck-rpi5` passes 48/48, confirmed across three consecutive
real-hardware runs**, including `rtc`/`timer`'s real 1-second
wall-clock wait (`scripts/run_hwtest_rpi5.sh`'s `MAX_SECS=5`/
`STABLE_POLLS=30` override, same values `run_hwtest_rpi3.sh` already
uses for these two, needed since the default ~0.3s idle-quiet threshold
would truncate the capture mid-wait).

## Status update (2026-07-26): D-cache AND I-cache both enabled -- GitHub
## issue #169, `make hwcheck-rpi5` 46/46 with full caches on

Issue #165 (below) landed the MMU with D-cache/I-cache deliberately left
OFF, because enabling them broke `examples/common_rpi5/pcie.tkb`'s own
link-training/reset delays -- plain empty-loop iteration counts
calibrated for cache-off execution speed, not a real timer read. Issue
#169 fixed the actual root cause: `examples/common_rpi5/timer_asm.S`
ports RPi3's `read_cntfrq`/`read_cntpct` ARM-Generic-Timer stubs
(architecture-generic, not BCM2837-specific -- a straight copy), and
`pcie.tkb` gained `delay_us()`/`timed_out()` helpers built on them.
Every one of the eight iteration-count loops in `pcie.tkb` (one
calibration-poll, five fixed ~100-200us settles, one ~5ms-per-retry
poll, one ~100ms pre-poll wait) was replaced with a real-time
equivalent, reusing each loop's OWN already-documented approximate
duration as the real microsecond target -- a mechanical conversion of
already-hardware-proven timing, not a redesign of the timing itself.

With that done, `examples/common_rpi5/mmu.S`'s `SCTLR_EL2.C`/`I` are now
BOTH enabled (unlike issue #165's original M-only state). **`make
hwcheck-rpi5` passes 46/46 with full caches on, confirmed across four
consecutive real-hardware runs**, and the issue #165 exception
checkpoint (`ESR_EL2`/`FAR_EL2`/`ELR_EL2` in `x1`/`x2`/`x3` after a
deliberately forced fault) was re-verified end-to-end with caches
enabled too -- identical, correct result. `COMMON_RPI5_TIMER_ASM_O` is
now linked into every `RPI5_KERNELS` entry AND `examples/rp1_pcie_smoke`
(both need it unconditionally, since `pcie.tkb` -- used by every RPi5
kernel via `COMMON_RPI5_PCIE` -- now calls `delay_us`/`read_cntfrq`/
`read_cntpct`; this also fixed a pre-existing build break in
`rp1_pcie_smoke`'s own link rule, which had never been updated to link
`COMMON_RPI5_MMU_O` after issue #165 added an unconditional `bl
mmu_init` to `startup.S`).

Real, cache-coherent multi-core memory access (the reason this was
prioritized -- upcoming RPi5 SMP work) has NOT been separately exercised
yet: only core 0 runs today, same as every RPi5 example before this.
Issue #163 (MPIDR_EL1 core numbering) is the next real test of that.

## Status (2026-07-25): RP1 PCIe enumeration and simultaneous SWD +
## GPIO14/15 UART output proven on real hardware (issue #161)

`examples/start`'s payload has been successfully injected and run to
completion on real hardware multiple times (confirmed via post-run memory
reads landing exactly on `.Lhalt`, matching `startup.S`'s own compiled
tail sequence byte-for-byte) -- the SWD catch/inject/safety-check mechanism
itself (`scripts/rpi5_jtag_load.sh`, `scripts/rpi5_prepare_sdcard.sh`) is
proven and working. RP1's PCIe link, Type-1 root-bridge forwarding,
endpoint BAR assignment, and `rp1_uart0` are now also proven: the smoke
test read FR=`0x197` and emitted a clean `rp1 uart0 alive!` at 115200 baud
while SWD remained active. This
directory is a from-scratch port effort, not a copy of a proven mechanism
the way most of this repo's other RPi3 examples are additions to an
already-working target -- follow this repo's usual incremental-verification
process (see the root `AGENTS.md`). `make hwcheck-rpi5` now builds and
injects `examples/start`, then byte-compares its complete GPIO14/15 UART
output; it remains opt-in because it requires an attached board, SWD probe,
and separately-wired GPIO14/15 UART path.

## Status update (2026-07-25, same day, later): first example-port batch
## CONFIRMED on real hardware -- `make hwcheck-rpi5` 13/13, twice in a row

Real hardware (RPi5 + Debug Probe) was attached later the same session.
`make hwcheck-rpi5` initially included `type_system_suite` and
`algorithm_suite` (10 examples total) and found two real bugs, not test-
harness artifacts:

- **A one-off garbled first run** (`start` itself, plus every other test,
  came back with dropped/reordered bytes) that did NOT reproduce on a
  second run or under isolated manual reproduction (reset, then a single
  persistent UART reader, then inject) -- left unexplained; if it recurs,
  suspect the RP1 PCIe link state after a PSCI reset rather than the test
  harness's drain/capture windowing, which was independently verified
  correct via manual replication.
- **A real, reproducible hang**, confirmed via the same "read PC/ESR
  over SWD after a hang" technique issue #161's own bring-up used:
  `type_system_suite` stopped after its `packed` case, `algorithm_suite`
  stopped after `inet_checksum`. In both cases the halted core sat at
  `0x200a00` -- exactly `exception_vectors` + `0x200`, the "Current EL
  SPx, Synchronous" slot, which Stage A's `startup.S` still just spins on
  (`b .`). `ESR_EL2` read `0x96000061` both times: EC=`0x25` (Data Abort,
  no EL change) with DFSC=`0x21` (Alignment fault). **Root cause: with
  the stage-1 MMU disabled, AArch64 treats all memory as Device
  (nGnRnE), where an unaligned access always faults regardless of
  `SCTLR.A`** -- an architectural rule, not a compiler or harness bug.
  `examples/packed/packed.tkb` (deliberately misaligned struct field
  access) and `examples/common/inet_checksum.tkb` (unaligned 16-bit wire
  reads, pulled in by `algorithm_suite`) both do this on purpose, safely
  on every OTHER target because `--forbid-trap`-adjacent unaligned
  access is only actually safe once a real MMU marks that memory Normal.
  RPi3 never hit this in its own first example group because its generic
  kernel link rule has included `COMMON_RPI3_MMU_O` since RPi3's very
  first example -- RPi5 Stage A has no MMU at all yet (issue #165).
  **Fix**: removed `type_system_suite`/`algorithm_suite` from
  `RPI5_EXAMPLES` (Makefile) and the corresponding calls from
  `scripts/run_hwtest_rpi5.sh` -- re-add both once issue #165 lands.

With those two removed, **`make hwcheck-rpi5` passed 13/13 twice in a
row** (`basic_suite`'s own `cases.txt` expands to `start`, `hello`,
`print_int`, `print_hex`, `print_ptr`, `mem`, `array`, `struct`,
`struct_refined`, plus `bump`/`scheduler`/`klock_guard`/`percpu` as
individual tests) -- this batch is now genuinely hardware-proven, not
just build-verified.

## Status update (2026-07-25, same day, later still): GitHub issue #165
## (MMU + exception handling) landed, ALL 46 RPI5_EXAMPLES tests pass

`examples/common_rpi5/mmu.S` ports RPi3's own identity-map MMU idea
(`examples/common_rpi3/mmu.S`), simplified because BCM2712's physical
map, unlike BCM2837's, puts RAM and every MMIO region this code touches
on separate 1GB-aligned boundaries far apart -- L1 BLOCK descriptors
only, no L2/L3 tables needed at all. T0SZ=27 (37-bit input address,
exactly covers the RP1 outbound window's top byte, `0x1FFFFFFFFF`), PS=
40-bit. **A live-hardware register probe was run FIRST, before writing
any of this**: a tiny standalone ELF read `HCR_EL2`/`ID_AA64MMFR1_EL1`/
`SCTLR_EL2` into a fixed memory word and halted, confirming
`HCR_EL2=0x0000000080000000` -- bit 34 (E2H/VHE) clear -- so TF-A hands
off to a takibi payload WITHOUT VHE active, meaning `TCR_EL2` uses the
same "basic" (non-VHE) field layout RPi3's Cortex-A53 always used. This
let `TCR_EL2`'s value be derived by recomputing RPi3's own known-good
`0x80803519` from the same formula (confirmed to reproduce it exactly)
before changing T0SZ/PS for RPi5's own address range, rather than
guessing at a VHE-shaped alternate layout that turned out not to apply.

**Two real bugs found on real hardware, not by inspection, both fixed**:

1. **Enabling D-cache/I-cache broke `pcie.tkb`'s own PCIe bring-up.**
   With MMU+both caches on, every RPi5 example went completely
   UART-silent: `platform_init()`'s `pcie2_init()` started returning
   `false` (so `uart_init()` never ran), and `uart_putc`'s FR-register
   poll read back `0xDEADDEAD` forever -- the exact PCIe-poison pattern
   from issue #161's own history. Root cause: `pcie.tkb`'s link-
   training/PHY/reset delays are plain empty-loop iteration counts
   calibrated for cache-off speed (its own comments already say "rough",
   "~100-200us", "~5ms"), not a real timer read; I-cache makes the CPU
   retire that fixed count far faster in wall-clock time, so real PCIe
   hardware timing requirements silently stop being honored. Confirmed
   by reading back `uart_putc`'s locally-cached FR value via `reg x9`
   over SWD (`0xDEADDEAD`) and by rebuilding with only the two cache-
   enable `orr` instructions removed, which reproduces the correct
   `foo(5)=1\r\nbar(3,4)=0\r\nbar(1,10)=1\r\n` output every time. Fixed
   by enabling `SCTLR_EL2.M` (MMU) only, leaving `C`/`I` off -- sufficient
   for this issue's actual requirement, since the "unaligned access
   always faults" rule is tied to Device-vs-Normal MEMORY TYPE under
   stage-1 translation, not to whether caching is active; Normal memory
   with caching off already exempts RAM from that rule. Revisiting
   `pcie.tkb`'s delays against a real ARM Generic Timer read (same
   source `examples/common_rpi3/rtc.tkb` already reads) is a separate,
   later change, not this issue's scope.
2. **`scripts/rpi5_jtag_reset.sh` had its own latent cpu0-sticky-abort
   bug**, uncovered by this session's much higher rate of repeated
   reset/inject cycles than typical usage: its trampoline `mww` writes
   went through cpu0's own debug context, the exact "cpu0 sticky debug
   abort after a completed payload" hazard `scripts/rpi5_jtag_load.sh`'s
   own load pass already works around (by writing through cpu3 instead,
   per its own header comment) -- this script just never got the same
   treatment when first written. Symptom: the script kept reporting
   PASS/"reset confirmed" logic aside, actual `reg pc` reads after a
   "successful" reset kept returning the SAME pre-reset PC, meaning the
   SMC never actually ran. Fixed identically: `mww` through
   `bcm2712.cpu3`, only `reg x0`/`reg pc`/`resume` through `bcm2712.cpu0`.
   Confirmed reliable across many consecutive resets afterward.

**Loader safety check redesigned** (this issue's own core requirement --
the previous "EL2H + MMU disabled" discriminator stopped being valid the
moment takibi payloads started enabling the MMU themselves). Consulted
with the user on the design tradeoff (a stronger canary-based check
requiring a `jtag_stub.S` change and a host-side SD-card reflash this
container cannot perform, vs. a simpler check needing no such reflash);
chose the simpler option. New discriminator: `current mode == EL2H AND
halted PC < 0x02000000` (32MB) -- every takibi RPi5 payload runs from a
fixed low physical address (`jtag_stub.S` at `0x80000`, every
`kernel_rpi5.elf` at `0x200000`, see `link.ld`) with over 100x headroom
for growth, while a live, fully-booted Raspberry Pi OS kernel runs from
a canonical HIGH virtual address (confirmed empirically in issue #161's
own history: `0xffffd06fcf296448`) regardless of EL/MMU state. **A real,
dangerous bug was caught and fixed before this ever shipped**: the first
implementation compared PC via bash arithmetic (`$((halted_pc))`), and
bash's `$(())` parses a 64-bit hex literal with the top bit set as a
NEGATIVE signed integer -- confirmed directly that comparing the exact
real canonical Linux VA above against the 32MB threshold this way
evaluates FALSE (wraps negative, reads as "less than", so the check
would have WRONGLY ACCEPTED an injection into a live kernel: precisely
the failure this whole mechanism exists to prevent). Fixed by comparing
as fixed-width (16-hex-digit, zero-padded) STRINGS instead of numbers --
two equal-length hex strings sort in the same order as their numeric
magnitude, sidestepping the overflow entirely. Verified both the accept
and refuse paths, isolated from hardware first (a script-only unit test
against captured log text, covering the real canonical-VA value, the
exact 32MB boundary, and ordinary low addresses), then against real
hardware (forced `reg pc` to an out-of-range value and confirmed the
script refuses; confirmed low addresses inject normally).

**Exception checkpoint proven on real hardware, not just written**: the
"Current EL SPx, Synchronous" vector slot now saves `ESR_EL2`/
`FAR_EL2`/`ELR_EL2` into `x1`/`x2`/`x3` (kept live at the final `wfe`
halt, readable via `reg x1`/`reg x2`/`reg x3` -- NOT via `mdw`, see the
"Remaining Stage A constraints" section below for why) plus a
`sync_exception_evidence` memory copy for whichever debug path can
actually read it. Deliberately triggered a real exception to prove
it end-to-end: forced `reg pc 0x50000000` (an address with no `l1_table`
entry at all) and resumed -- landed exactly at `.Lsync_spx_halt`,
`ESR_EL2=0x86000005` (EC=0x21 "Instruction Abort, no EL change",
IFSC=0b000101 "Translation fault, level 1" -- exactly right, since
`0x50000000`'s L1 index, 1, was never populated), `FAR_EL2`=
`ELR_EL2`=`0x50000000`, both exactly the faulting address. Not a
theoretical claim -- a real fault was caused and correctly diagnosed.

**Result**: `make hwcheck-rpi5` passes **46/46**, confirmed twice in a
row, covering every `RPI5_EXAMPLES` entry including `type_system_suite`/
`algorithm_suite` (re-added to the Makefile and
`scripts/run_hwtest_rpi5.sh` now that they pass) -- `packed` and
`inet_checksum`/`ip_parse`/`tcp_parse` specifically, the exact cases
that originally hung without an MMU. All four of issue #165's acceptance
criteria are met: a concrete example (in fact the whole existing RPi5
example set) runs with the MMU enabled; the loader still refuses a
simulated live-OS PC; the loader accepts real takibi payloads post-MMU;
and a deliberately-caused exception reaches a diagnosable checkpoint,
proven against real hardware, not asserted from code reading alone.

## Status update (2026-07-25, same day, earlier): first example-port
## batch added, build-verified only -- NOT yet run on real hardware this
## session (superseded by the real-hardware update directly above)

With `examples/start` proven above, this directory's scope widened from
"prove the mechanism" to "port the rest of the RPi3 example tree", the
same transition RPi3 itself made after its own first example (issue
#140). Followed RPi3's own staged order exactly: the Makefile's new
`RPI5_EXAMPLES` group (`start basic_suite type_system_suite
algorithm_suite bump scheduler klock_guard percpu`) is a byte-for-byte
copy of `RPI3_EXAMPLES`' own first, pre-interrupt group -- "plain
compute, no interrupt/timer/RTC dependency" (see that variable's own
Makefile comment). All eight build and link cleanly (`make
examples/<name>/kernel_rpi5.elf` for each). `scripts/run_hwtest_rpi5.sh`
was generalized from a single-example script into a full suite runner
(reset-before-each-test via `scripts/rpi5_jtag_reset.sh`'s PSCI trick,
plain-diff and `cases.txt`-manifest suite variants) mirroring
`scripts/run_hwtest_rpi3.sh`'s own structure; `make hwcheck-rpi5` now
depends on the whole `RPI5_EXAMPLES` kernel set instead of just
`examples/start`. Every `.expected`/`cases.txt` fixture is reused as-is
from the existing RPi3/QEMU/STM32 suites (target-independent: `uart_puts`/
`uart_print_*` emit identical bytes on every HAL).

One real gap found while porting, fixed the same way RPi3 originally
added it: `examples/klock_guard/klock_guard.tkb` calls `extern fn
enable_irq()`/`disable_irq()` (its giant-lock placeholder), which
`startup.S` did not yet provide here. Added the same two-instruction
`msr DAIFClr, #0x2` / `msr DAIFSet, #0x2` pair RPi3's own `startup.S`
has -- pure CPU-local DAIF-bit state, no GIC-400 register access
involved, so this does NOT pull interrupt handling into Stage A's scope;
nothing here unmasks IRQ at the vector-table level or configures the GIC
to ever raise one.

**`make rpi5-start` was removed** (the interactive convenience target
used for the very first real-hardware attempt) -- `make hwcheck-rpi5` is
now the real, automatic, byte-compared test and fully supersedes it; see
"Build and try" below for the updated workflow.

**Not yet run on real hardware**: no Raspberry Pi 5 / Debug Probe was
attached to this devcontainer during this session (checked: no
`/dev-host/ttyACM*`, no `/dev-host/serial/by-id` entries at all) --
build-verification only. The next session with hardware attached should
run `make hwcheck-rpi5` and update this file + `HISTORY.md` + the
`rpi5-bringup-status` memory with the real result, the same discipline
`examples/start`'s own port already followed.

**Deliberately not yet attempted at this historical checkpoint**:
`rtc`/`timer`/`irq`/`echo`/USB/networking/EL0/EL1/SMP examples and their
RPi3 equivalents. This paragraph records the earlier staged-port state;
issues #165, #170, and #164 subsequently supplied the MMU, RTC/timer, and
RP1 UART0 IRQ prerequisites respectively. USB, networking, EL0/EL1, and
SMP remain out of scope until a concrete prerequisite task needs them.

**The architectural constraint confirmed 2026-07-25 through extensive
real-hardware debugging (see "A real bug this port found" and "UART
investigation" below) is that this board's single 3-pin debug
connector can carry EITHER UART OR SWD, never both at once** (Raspberry
Pi's own official "3-pin Debug Connector Specification", RP-003139-SP --
this is a hardware-level standard, not something software can route
around). Getting simultaneous SWD debugging and live UART output
therefore uses RP1's own, physically separate GPIO14/15-routed
`rp1_uart0`. `examples/common_rpi5/pcie.tkb` now brings that link up and
enumerates RP1 without an OS. See GitHub issue #161 and the final status
entry below for the evidence trail and resolved root cause.

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
  physical `0x1F00030000`) does. `uart.tkb` now targets `0x1F00030000`;
  after bare-metal PCIe reset its clock is RP1's 50MHz XOSC, so
  IBRD=27/FBRD=8 produces the real-hardware-confirmed 115200-baud output.
  (The earlier ~44MHz `vcgencmd` measurement was Linux's already-
  reprogrammed clock state, not the post-reset bare-metal state.) Whether
  this BCM2712-uart10-vs-RP1-uart0 wiring is
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
  way as the UART above). Issue #164 now uses those exact interfaces for
  MIP0 vector 25's GIC SPI 153 / architectural INTID 185. The
  implementation remains intentionally local to `intc.tkb`; it did not
  generalize QEMU's GIC helper ahead of another real RPi5 consumer.
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

## What's deliberately NOT ported yet (post-issue-#164 scope)

`examples/common_rpi5/mmu.S` (GitHub issue #165) added the stage-1 MMU
(identity map, EL2) and one real synchronous-exception checkpoint. Issue
#164 then added only `HCR_EL2.IMO`, the Current-EL-SPx IRQ vector, and the
RP1 UART0 dispatcher needed by `echo`/`irq`. HVC, lower-EL, FIQ, and all
unrelated interrupt-source handling still spin or remain absent. Add each
remaining piece only once a concrete example actually needs it, the same
order RPi3 itself was built in. Do not port RPi3's USB host stack
(`usb_dwc2.tkb`/`usb_hub.tkb`/
`usb_host.tkb`/`lan9514.tkb`) or its Ethernet driver at all -- RPi5's
Ethernet path is PCIe-attached (via RP1), architecturally unrelated to
RPi3's USB-attached LAN9514, and is its own future subject if pursued,
not a port of the existing driver.

## Remaining Stage A constraints

1. **PSCI reset is not a substitute for a power cycle after changing the
   SD-card payload.** It reliably reruns the same resident image, but a
   changed `kernel_2712.img` may not be reloaded. Power-cycle after replacing
   that file. Tracked by GitHub issue #162.
2. **MPIDR_EL1 core-numbering -- RESOLVED, issue #163.** The BCM2837-by-
   analogy assumption (`mpidr_el1 & 3` = plain 0-3 core number) was
   WRONG: BCM2712 sets the MT bit and numbers cores in Aff1 (bits
   [15:8]), not Aff0 (bits[7:0], `0x00` on every core here). Confirmed
   by directly reading MPIDR_EL1 on all four `bcm2712.cpuN` targets
   (`scripts/rpi5_check_core_topology.sh`): `cpu0=0x81000000`,
   `cpu1=0x81000100`, `cpu2=0x81000200`, `cpu3=0x81000300`. `startup.S`
   now shifts right 8 before masking. See the status update at the top
   of this file for the full trace, including why PSCI `CPU_ON`/
   `AFFINITY_INFO` could not be used as a topology oracle here.
3. **D-cache and I-cache are both ON now (issue #169).** `SCTLR_EL2.C`/
   `I` were originally left off by issue #165 (see git history for the
   original constraint text) because enabling them broke
   `examples/common_rpi5/pcie.tkb`'s iteration-count delay loops --
   fixed by rewriting those delays against a real ARM Generic Timer
   read (`examples/common_rpi5/timer_asm.S`, `delay_us`/`timed_out` in
   `pcie.tkb`), confirmed via `make hwcheck-rpi5` 46/46 across four
   consecutive real-hardware runs with both caches on. Real
   cache-coherent MULTI-core access has not been separately exercised --
   only core 0 ever actually runs takibi code today (issue #163
   confirmed cores 1-3 remain parked in TF-A's own EL3 idle loop,
   never reaching `_start`); treat multi-core cache coherence as still
   open until an actual RPi5 SMP example brings a second core into our
   own code via PSCI `CPU_ON`.
4. **`mdw` (OpenOCD's raw memory-read command) does not work once the
   MMU is on.** Confirmed real and reproducible against this exact
   CMSIS-DAP/BCM2712/OpenOCD-0.12.0 combination: `mdw` against ordinary,
   definitely-mapped low RAM returns `Error: abort occurred` the moment
   `SCTLR_EL2.M=1`, even though `reg`-based reads (general-purpose AND
   system registers, e.g. `reg x9`, `reg esr_el2`) keep working
   correctly. Read state after a hang via `reg`, not `mdw`, from this
   point on -- see `sync_exception_evidence`'s own comment in
   `startup.S` for where this was found and how the exception checkpoint
   was redesigned around it.

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

## Build and try

```
make examples/common_rpi5/jtag_stub.img
# on the host, with the SD card's boot partition mounted:
scripts/rpi5_prepare_sdcard.sh /path/to/mounted/boot/partition
# power-cycle the board, then run the full suite:
make hwcheck-rpi5
```

`scripts/rpi5_prepare_sdcard.sh` -- NOT `rpi3_prepare_sdcard.sh` -- is
required even if this SD card was already run through the RPi3 version;
see "Root cause" above for why overwriting only `kernel8.img` is not
enough on RPi5.

`make hwcheck-rpi5` builds every `RPI5_EXAMPLES` kernel, then, for each
one, resets the board via `scripts/rpi5_jtag_reset.sh` (PSCI
`SYSTEM_RESET`, confirmed working -- see that script's own header
comment), injects the payload via `scripts/rpi5_jtag_load.sh`, and
byte-compares the captured RP1 UART0 output against that example's
`.expected`/`cases.txt` fixture. This supersedes the earlier `make
rpi5-start` convenience target (removed 2026-07-25 once this real,
automatic test existed) -- if the board is not already parked at the
stub (e.g. it just booted Raspberry Pi OS instead), flash the stub and
power-cycle by hand first, or try `scripts/rpi5_jtag_reset.sh` on its
own.

## RP1 PCIe enumeration -- GitHub issue #161

Confirmed via Raspberry Pi's own official "3-pin Debug Connector
Specification" (RP-003139-SP) that this board's single debug connector is
standardized to carry EITHER UART OR SWD, never both -- so simultaneous
SWD debugging and live UART output requires RP1's own, physically
separate `rp1_uart0` (GPIO14/15), which in turn requires bringing up
RP1's PCIe link ourselves. Decided with the user 2026-07-25: pursue this
as its own new milestone, tracked as
https://github.com/takibi-lang/takibi/issues/161.

The following subsections are a chronological investigation log. Statements
such as "remaining gap" describe the state at that checkpoint and are
superseded by the final-status subsection; they are retained because the
failed hypotheses and register evidence explain the fixes now in `pcie.tkb`.

### Status (2026-07-25 real-hardware session): enumeration, mapped access,
### and normal examples/start platform initialization proven

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

### Final status (2026-07-25): root-bridge forwarding was the missing
### layer; FR read and simultaneous SWD + UART output now work

The BAR1-only change above was necessary but still returned
`0xDEADDEAD`. Continuing with exact Linux-driver comparison and targeted
real-hardware reads found three more concrete omissions:

- `brcm_pcie_set_outbound_win()` writes both `WIN0_BASE_HI` (`0x4080`)
  and `WIN0_LIMIT_HI` (`0x4084`). The Takibi port wrote only BASE_HI,
  leaving a 40-bit window whose limit was below its base. LIMIT_HI is now
  set to `0x1f` as well; real-hardware readback confirmed both values.
- RP1 exposes three memory BARs, not two: BAR1 is the 4MB peripheral
  aperture at PCI address `0`, BAR2 is the following 64KB aperture at
  `0x00400000`, and BAR0 is the 16KB MSI-X aperture at `0x00410000`.
  The smoke test now disables endpoint decoding, assigns all three, then
  enables Memory Space + Bus Master exactly once the layout is complete.
- **The final blocker was pcie2's own Type-1 root-port header.** An
  outbound ATU and enabled endpoint BAR do not bypass normal PCI bridge
  forwarding. The root port still had Command=0, all bus numbers=0, and
  Memory Base/Limit=0. `pcie2_root_bridge_setup()` now gives it bridge
  class `0x060400`, Primary/Secondary/Subordinate buses `0/1/1`, a
  non-prefetchable PCI memory window `0x00000000..0x004fffff`, and
  Command Memory Space + Bus Master enable. RP1 consequently moves from
  its temporary pre-numbering bus 0 response to the normal bus 1 used by
  Linux.

Real-hardware proof after rebuilding and injecting the Takibi payload
(not manual register pokes): link result=1, BAR0=`0x00410000`,
BAR1=`0x00000000`, BAR2=`0x00400000`, endpoint Command/Status=
`0x00100006`, BAR0 data=`0x00000000`, BAR2 data=`0x100029d8`, and
`rp1_uart0` FR=`0x00000197`; the checkpoint reached 9 after
`uart_puts()`. The first transmitted string was garbled because the
old divisor came from a live Linux `vcgencmd` clock measurement. After
bare-metal PCIe reset, UART0 uses RP1's 50MHz XOSC; IBRD=27/FBRD=8 then
produced a clean, directly captured `rp1 uart0 alive!` at 115200 baud
while the SWD session remained active. This completes issue #161's
Stage-1 proof of life.
