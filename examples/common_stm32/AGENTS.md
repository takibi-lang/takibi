This file holds STM32F746G-DISCOVERY (Cortex-M7) bare-metal reference
material for the `examples/common_stm32/` HAL. It was split out of the project
root's `AGENTS.md` to keep the root guidance focused (the same reasoning already
applied to `HISTORY.md`; see root `AGENTS.md`'s "Important Design Notes"). Read
root `AGENTS.md` first for the project's overall goals, build commands, and
process rules that apply everywhere.


- **STM32 Ethernet examples include the shared QEMU/STM32 network demos plus STM32-only
  SD-card HTTP variants.** `net_echo`, `arp_reply`, `icmp_echo`, `tcp_echo`, and
  `http_server` run on real hardware with real MAC/PHY/DMA and are the *same source
  file* as their QEMU/virtio-net counterparts. `http_server_sdcard` and
  `http_server_sdcard_rtos` also use the STM32 Ethernet HAL, but are STM32-only
  because they need the real SD card.

  `examples/common_stm32/eth.tkb` is a from-scratch MAC/DMA-descriptor-ring driver
  plus MDIO-based LAN8742A PHY init over RMII. RMII pins, PHY bring-up, and the DMA
  descriptor ring design are documented in that file's header comment.

  **Unified driver API**: `eth.tkb` and `examples/common_qemu/virtio_mmio.tkb` both expose the identical
  `net_init() -> NetInitResult` / `net_rx_wait()` /
  `net_rx_acquire(sink NetRxCanAcquire) -> NetRxAcquire` /
  `net_rx_len(borrow NetRxCpuOwned[desc]) -> i32` /
  `net_rx_frame(borrow NetRxCpuOwned[desc]) -> [u8; 1514..] @ desc` /
  `net_transmit(sink NetRxCpuOwned[desc], len) -> NetTxInFlight[desc]` /
  `net_tx_complete(sink NetTxInFlight[desc]) -> NetRxCanAcquire` /
  `net_rx_release(sink NetRxCpuOwned[desc]) -> NetRxCanAcquire` /
  `net_read_mac(mac_out)` functions -- mirroring how `uart.tkb`/`print.tkb` already
  share identical signatures across `examples/common/` and `examples/common_stm32/`. This means
  `examples/net_echo/net_echo.tkb` (and the other four) are a *single* file compiled against either
  backend depending on target, not a QEMU version plus a hand-maintained `_stm32.tkb` copy -- see that
  file's header comment. Descriptor rings, RX/TX buffers, and virtio's 10-byte `virtio_net_hdr` framing
  are all hidden inside each backend; application code never sees them. Both backends are interrupt-driven:
  STM32 vectors IRQ61 directly to `ETH_IRQHandler`, while virtio discovers its SPI from the MMIO slot and
  dispatches through GICv2. ISRs acknowledge, set `io` flags, and issue `interrupt_notify()`; normal
  context uses `interrupt_wait()` instead of spinning while idle. Used-ring/descriptor inspection,
  cache maintenance, indexed-owner creation, and packet processing remain in normal context. The erased
  affine `NetRxCanAcquire` permission enforces the current one-frame-in-flight policy; the acquired
  descriptor owner is linear and must be returned on every path. TX start consumes that owner and
  returns a linear in-flight owner after copying to a dedicated TX buffer and re-posting the RX
  descriptor; completion consumes the in-flight owner only after DMA releases the exact TX slot and
  restores the acquisition permission.

  **RX burst capacity and suspended-DMA recovery (issue #135 follow-up)**: the RX ring has 56
  descriptors, allocated statically at link time. Twenty-four concurrent TCP clients can produce a
  48-frame ACK-plus-request burst before ARP and retransmissions; 48 descriptors still measured five
  missed frames, while 56 measured zero. The KVS SD worker is asynchronous, so network normal context
  no longer stalls behind write-through. This count
  is sized for the MCU/server contract, not for the host's CPU count. When all descriptors were temporarily CPU-owned,
  the STM32 DMA could set RBUS and remain
  suspended even after descriptors had been reposted. `eth_rx_resume` now clears RBUS and issues RX
  poll demand after publishing a descriptor; the empty-acquire path also performs this recovery so
  an interrupt/poll race cannot leave receive asleep. Read `ETH_DMAMFBOCR` only once when diagnosing
  loss because its missed-frame counters are read-to-clear.

  STM32 TX no longer transmits directly from the currently CPU-owned RX buffer. Four dedicated
  1536-byte TX buffers mirror the TX descriptor ring; `net_transmit` copies only the proven-safe
  frame length, reposts the RX descriptor immediately, and then publishes the TX descriptor. The
  linear `NetTxInFlight[desc]` owner and `NetRxCanAcquire` permit still prevent normal context from
  processing another frame before TX completion, so the cross-platform driver API is unchanged,
  while RX DMA can fill the returned descriptor during that interval. The extra BSS cost is about
  6.2 KiB. With twenty-four TCP slots and the 56-entry RX ring, concurrency 24 completed both
  fixed-key and 16-key-distributed 30-second KVS+SD+RTOS runs with zero transport failures and
  zero DMA missed frames. The final KVS image is about 140.5 KiB.

  **Network config**: `examples/common_stm32/netconfig.tkb` holds the board's MAC/IP as plain global
  constants (`OUR_MAC`/`OUR_IP`/`HTTP_SERVER_IP`, array-literal `{...}` initializers). MAC is a fixed
  `00:80:E1:00:00:00`, matching ST's own STM32CubeF7 LwIP example convention (hardcoded, not derived from
  the chip's unique ID -- see that file's comment for the tradeoff). IP is `192.168.10.2`, the same /24 as
  this devcontainer's point-to-point NIC (`enp4s0`, `192.168.10.1/24`), chosen so the board is reachable
  with zero host-side routing changes. `examples/common_qemu/netconfig.tkb` holds the QEMU-side counterpart:
  `OUR_IP` = `192.0.2.1` (RFC 5737 TEST-NET-1) for `arp_reply`/`icmp_echo`/`tcp_echo` (MAC is deliberately
  NOT in this file -- `net_read_mac()`'s virtio-net backend reads it from the device at runtime, nothing to
  share). `http_server.tkb` reads a third constant, `HTTP_SERVER_IP`, instead of `OUR_IP`: on the QEMU side
  this is `10.0.2.15` (SLIRP's fixed `-netdev user` guest address, needed for `hostfwd` to route a real
  browser's connection to the guest at all -- see that file's header comment), while on the STM32 side it's
  simply the same value as `OUR_IP` (no SLIRP-style constraint on real hardware). Both `netconfig.tkb` files
  define the same two variable names (`OUR_IP`, `HTTP_SERVER_IP`) for consistency, even though the STM32
  side's `HTTP_SERVER_IP` is a duplicate of its own `OUR_IP`. This lets every example's `app_main()` do a single
  unconditional `bytes_copy` from the constant it needs, with no runtime branch at all (see the STM32
  section below for `irq.tkb`'s GIC-vs-NVIC enable sequence, which eliminated its own runtime branch the
  same way -- a per-target pair of definitions behind one uniform name).

  Ethernet examples are verified against a real point-to-point link via `scripts/eth_*_test.py` + `make hwcheck-stm32-net`
  (not part of `make check`/`make hwcheck-stm32` since it needs a real board wired directly to the test machine's
  NIC, plus `CAP_NET_RAW`). `make hwcheck-stm32-net` aggregates all such Ethernet hardware tests via
  `scripts/run_hwtest_net_ram.sh`, same PASS/FAIL-summary style as `scripts/run_hwtest_ram.sh` -- add new
  Ethernet examples there as they're ported (one `run_net_hw_test NAME ELF TEST_SCRIPT` line), rather than
  each getting its own separate `make` target.

  **Real-hardware-only test wrinkle (first hit porting `tcp_echo`, applies to any future short-segment
  test)**: TCP control segments with no payload (bare SYN/SYN-ACK/FIN-ACK, 54 bytes total) are below
  Ethernet's 60-byte minimum frame size. The STM32 MAC's automatic pad handling (MACCR.APCS) pads
  *outgoing* short frames up to 60 bytes regardless of EtherType -- this is a transmit-side behavior,
  distinct from the *receive*-side stripping ambiguity already documented in
  `scripts/eth_net_echo_test.py`'s module comment (which only applies to frames the board receives). A
  test script slicing "everything remaining in the reply" (safe over virtio-net, which never pads) would
  fold those trailing pad bytes into a TCP checksum verification and fail it for the wrong reason.
  `scripts/eth_tcp_echo_test.py` slices every reply to its exact expected length instead of an open-ended
  slice, for exactly this reason.

  `http_server.tkb` combines `arp_reply`'s ARP response with `tcp_echo`'s state machine in one kernel
  (dispatching on EtherType), plus initiating its own FIN right after the response
  (`build_http_response_fin`) -- needed because a real client always ARPs before sending IP packets,
  unlike the hand-crafted-packet test scripts the other four examples are verified with (both on QEMU,
  via SLIRP, and identically on the real STM32 board, via the devcontainer host's TCP/IP stack). Confirmed
  reachable from the devcontainer host's real TCP/IP stack (`curl http://192.168.10.2/` after flushing the
  ARP neighbor cache, forcing a genuine cold-start ARP resolution + full TCP handshake/request/close --
  request counter incremented `#1` -> `#2` across two requests as expected) and from a real Firefox on the
  same machine. `scripts/eth_http_server_test.py` (wired into `make hwcheck-stm32-net` like the other four) is
  deliberately NOT another hand-crafted raw-socket script -- it uses Python's `http.client` over ordinary
  OS sockets (the real TCP/IP stack, same path a browser takes). No `sudo`-only privilege is actually
  needed for the HTTP requests themselves (plain sockets, unlike the other four's raw `AF_PACKET`) -- only
  the `ip neigh flush` step needs root, which `make hwcheck-stm32-net`'s existing blanket `sudo` already covers.

  STM32 startup leaves AXI SRAM under ARMv7-M's default Normal, cacheable mapping before enabling the
  Cortex-M7 caches. Ethernet images are linked at `0x20010000`; `link_eth.ld` asserts that data plus
  stack remain inside the full 240 KiB AXI SRAM region. Descriptors remain padded/aligned to one
  32-byte cache line, and RX/TX ownership transitions perform explicit cache maintenance and barriers.

  **Hardware bring-up bug worth knowing about**: the very first working version had every DMA descriptor field
  byte-for-byte correct (verified live via openocd/gdb-multiarch register+memory dumps) yet the TX descriptor's
  OWN bit would never clear -- the DMA engine simply never acted on it. Root cause: writing the descriptor
  fields (AXI SRAM) and then immediately poking the "poll demand" register (a different peripheral) has no
  ordering guarantee on Cortex-M7 -- `*io` writes in takibi are volatile (the compiler won't reorder/drop them)
  but that says nothing about the CPU's write buffer having actually retired the SRAM write before the very next
  store lands, so the DMA engine could race ahead and read a stale (OWN=0) descriptor. Confirmed by re-issuing
  the poll-demand write by hand through the debugger after enough time had passed for the earlier write to
  settle -- the descriptor completed instantly. Fixed originally with a handwritten `dsb`, now replaced by the
  compiler builtin `dma_publish()` between descriptor writes and poll-demand kicks. Completion paths use
  `dma_consume()` before CPU access to device-written descriptors/buffers. These calls stay inside driver APIs;
  volatile alone is not enough for DMA ownership transfer.

  TX interrupt-driven completion also requires `TDES0.IC` (bit 30) on every submitted descriptor. Enabling
  `DMAIER.TIE` alone is insufficient: without IC the DMA clears OWN after transmitting but emits no normal TX
  completion interrupt, leaving a flag-based waiter blocked forever. The waiter treats the interrupt as a wakeup
  and still verifies that OWN has cleared after acquiring the descriptor; the notification itself is not used as
  proof of ownership.

## STM32F746G-DISCOVERY Bare-Metal (Cortex-M7)

Real-hardware port, running alongside (not replacing) the QEMU/AArch64 build. Nearly every
example is now ported (55 as of this writing, per `Makefile`'s `STM32_RAM_ELFS` -- check
that variable directly rather than trusting this number, since it drifts as examples are
added; this project has a history of this exact count going stale), including
`net_echo`/`arp_reply`/`icmp_echo`/`tcp_echo`/
`http_server` (real Ethernet MAC+PHY driver, `examples/common_stm32/eth.tkb` -- see the
"STM32 Ethernet" entry above in this file for the
full story) and `irq`/`preempt`/`semaphore`/`condvar`/`watchdog`/`msgqueue` (NVIC +
SysTick/PendSV scheduler -- `examples/common_stm32/scheduler.tkb`/`nvic.tkb`). **Every
example is now a single shared `.tkb` file that compiles for both targets** -- no
`_stm32.tkb` variant exists anywhere in this repo anymore; see below for how the last 6
(genuinely the hardest case, since GICv2's and NVIC's dispatch models differ, not just
addresses) got there too.

**Devcontainer/USB setup** (`.devcontainer/devcontainer.json`): `runArgs` passes through
`/dev/bus/usb` (ST-LINK debug/flash interface, VID:PID `0483:374b`) with a
`--device-cgroup-rule` so hot-replug doesn't require editing the device path.
`postCreateCommand` installs `openocd` `stlink-tools` and adds the `vscode` user to the
`plugdev`/`dialout` groups (host GIDs 46/20) so neither needs `sudo`/`sg` after a fresh
rebuild.

**ST-LINK VCP serial (`/dev/ttyACM0`) is deliberately NOT bind-mounted directly** (no
`--device=/dev/ttyACM0`, unlike an earlier version of this file): that form requires the
device to already exist on the host at container create time, so building/starting the
devcontainer would fail outright whenever the ST-LINK wasn't plugged in yet -- a real
problem, since `/dev/bus/usb`'s own hot-replug tolerance (mounting the always-present
parent directory, so individual bus-numbered device files can come and go freely) doesn't
apply to `/dev/ttyACM0` (a flat file directly under `/dev`, with no similarly-stable parent
to mount instead). Fixed by bind-mounting the host's entire `/dev` tree read-only at
`/dev-host` (`-v /dev:/dev-host:ro`) plus `--device-cgroup-rule=c 166:* rmw` (166 = ttyACM's
major number) instead: the devcontainer builds/starts fine with no board attached, and a
board plugged in afterward shows up live at `/dev-host/ttyACM0` with no rebuild/restart.
The container's own `/dev` (and its `/dev/shm`/`/dev/pts` isolation) is left untouched --
only a read-only side path is added, not a replacement of `/dev` itself. The `ro` flag only
blocks directory-level operations (create/delete/rename) on the mirrored tree; it does not
block read/write I/O to a character device reached through it, so `/dev-host/ttyACM0` is
fully usable for serial communication. Path visibility through `/dev-host` is also not the
same as access: the container's cgroup device policy still only allows major 166 (ttyACM)
and 189 (USB) -- e.g. `/dev-host/sda` is visible by name but not actually readable, since
block-device majors were never added to the allowlist. `scripts/run_hwtest_ram.sh`'s
`STM32_SERIAL_DEV` env var and the Makefile's `STM32_SERIAL_DEV` variable both default to
`/dev-host/ttyACM0` accordingly (override to plain `/dev/ttyACM0` only if running this
Makefile outside this devcontainer, e.g. directly on a Linux host with the board attached).

**Build model**: `Makefile`'s `STM32_TARGET`/`STM32_CPU` (`thumbv7em-none-eabi` /
`cortex-m7`) and `STM32_EXAMPLES` list mirror `AARCH64_TARGET`/`EXAMPLES`. Most examples
just recompile the *same* `.tkb` file against `examples/common_stm32/` instead of
`examples/common/` (same pattern as the AArch64 side's compilation groups); a handful
that need one extra common file beyond the standard uart+print pair (`rtc`, `timer`,
`echo`, `irq`, `preempt`, `semaphore`, `condvar`, `watchdog`, `msgqueue`) get their own
one-off rule pairs, same reasoning as the existing `-g` debug-build rules. `make
stm32build` links every ported example as a RAM-execution image (no hardware needed,
part of `make check`); `make hwcheck-stm32` additionally loads and verifies each one against
the real board over the debug port (not part of `make check` -- needs physical
hardware). The one exception is `examples/http_server`, which also gets a Flash-resident
build (`examples/http_server/kernel_stm32.elf`/`.bin`) so `make stm32-http-server` can
flash a demo unit that boots the HTTP server standalone from power-on with no debugger
attached -- see "STM32 Hardware Test Harness: RAM Execution" below for why RAM execution
is the default for everything else, and why even this one Flash build's AXI SRAM1 DMA
region is genuinely cacheable now, not the non-cacheable window an earlier version of
this project used.

Issue #93's first batching pilot keeps that shared-source model but changes
the execution granularity: `hello`/`print_int`/`print_hex`/`print_ptr`/
`mem`/`array`/`struct`/`struct_refined` are `use`d by
`examples/basic_suite/basic_suite.tkb` and run from one RAM image. The
firmware emits a stable marker before each case; `scripts/run_hwtest_ram.sh`
splits the single UART capture and still compares each case with its original
fixture. This removes seven ST-LINK loads without merging or duplicating the
actual example sources. `start` stays standalone as the minimal runtime and
platform-hook integration test.

The follow-up added `type_system_suite` (18 cases) and `algorithm_suite` (14
cases) using the same manifest/marker protocol. Across all three suites, 40
logical cases now use three RAM images and three ST-LINK loads rather than 40;
the individual expected-output checks and displayed results remain intact.

**Files that turned out to need zero STM32-specific changes**: `examples/common/
print.tkb`, `examples/common/sync.tkb`, `examples/common/inet_checksum.tkb`,
`examples/common/netutil.tkb` are all pure takibi logic with no MMIO addresses --
reused completely unchanged, just recompiled/relinked against the STM32 HAL.

**`irq`/`preempt`/`semaphore`/`condvar`/`watchdog`/`msgqueue` used to need a genuinely
separate `<name>_stm32.tkb`, and are now unified anyway.** GICv2's shared-IRQ-vector-
plus-software-ID-dispatch model and Cortex-M's NVIC-direct-vectoring-plus-SysTick/PendSV
model aren't the same shape behind different addresses -- unlike the networking examples
(where polling replaced interrupts entirely, making the dispatch mechanism invisible to
the app), here the interrupt *entry-point names themselves* are dictated by each
platform's assembly: QEMU's is always `irq_dispatch(frame_sp) -> frame_sp`
(`examples/common_qemu/startup.S`'s `irq_entry`); STM32's is `USART1_IRQHandler()` (`irq`) or
`SysTick_Handler()` + `pendsv_dispatch(sp) -> sp` (the other five), vectored directly by
`examples/common_stm32/startup.S`'s hardware vector table. The fix: define **both**
platforms' entry points unconditionally in the one shared file (`examples/preempt/
preempt.tkb`'s header comment has the full reasoning) -- whichever one isn't relevant to
the target being built is simply dead code there, same idea as `OUR_MAC` sitting unused
in `net_echo`'s STM32 binary. Three small pieces of shared infrastructure make both
definitions actually *compile* on both targets:
- **`scheduler_init()`/`scheduler_disable()`/`scheduler_rearm_tick()`** (uniform names,
  real implementations in both `examples/common_qemu/timer.tkb` and `examples/common_stm32/
  scheduler.tkb`) hide the one genuine naming/arity mismatch found: STM32's
  `systick_init()` needs an explicit reload value `timer_init()` has no parameter for,
  and the ARM Generic Timer needs re-arming every tick where SysTick auto-reloads and
  doesn't. `app_main()` calls these three uniformly, no per-platform branch needed for any
  of it. (The `249999` reload value used to be duplicated at every STM32 example's call
  site; hoisting it into `scheduler_init()` removed that too.)
- **`examples/common_qemu/stm32_stub.tkb`** (QEMU-only): a no-op stand-in for
  `pendsv_trigger()` -- an STM32-only function that a shared file's dead-under-QEMU
  code (`SysTick_Handler`'s body) still references. Never actually invoked; exists
  solely so compilation succeeds under `aarch64-none-elf` too.
- `watchdog`'s `wdt_check()` needed no hook/override mechanism to call from both
  `irq_dispatch` and `SysTick_Handler` -- both entry points already live in the same
  file, so it's just an ordinary in-file function call on either platform.
- `examples/irq/irq.tkb` additionally needed a tiny `uart_isr_getc() -> u8` added to
  both `uart.tkb` files (PL011 `DR` vs USART1 `RDR` -- the one example here where the
  actual byte-read address, not just the dispatch wrapper, differs by platform), so its
  shared ISR body needs no per-platform branch either. Its interrupt *enable* sequence
  (GICv2 init+SPI-routing vs. NVIC line enable, then a final unmask done after the
  "ready" message so nothing can arrive before the handler is wired up) is handled the
  same way: **`irq_uart_rx_setup()`/`irq_uart_rx_unmask()`** -- uniform names, real
  implementations in `examples/common_qemu/gic.tkb` and `examples/common_stm32/nvic.tkb`
  (not `uart.tkb`, even though they're UART-interrupt related: `uart.tkb` is
  concatenated into *every* example's build, including ones that never touch GIC/NVIC
  at all, so a function defined there calling `gic_init()`/`enable_usart1_irq()` would
  fail to resolve on those other builds; `gic.tkb`/`nvic.tkb` are only ever included
  where those symbols already exist). `app_main()` calls both uniformly with no branch, and
  `register_irq()` itself (writing into a QEMU-only dispatch table) is harmless to call
  unconditionally too, since the STM32 side's `USART1_IRQHandler` never reads that
  table.

**USART1** (VCP, confirmed via ST/Zephyr docs + the board schematic): TX=PA9, RX=PB7,
AF7. STM32F7's USART is the "improved" generation (`CR1/BRR/ISR/ICR/RDR/TDR`), **not**
the classic F1/F4 `SR`/`DR` layout -- copying an F4-style init would silently compile and
produce no output. `uart_init()` uses the default HSI (16MHz) clock, no PLL setup;
`BRR = round(16_000_000 / 115200) = 139` for 115200 baud (OVER8=0, BRR used directly as
the divider in this USART generation, no mantissa/fraction packing).

**RTC**: LSI (~32kHz nominal, imprecise, no external crystal needed), PWR_CR1.DBP unlock
-> RCC_BDCR RTCSEL=LSI+RTCEN -> RTC_WPR 0xCA,0x53 unlock -> RTC_ISR.INIT/INITF -> PRER
left at the LSE-tuned reset default (close enough for "does it visibly tick", not
accurate timekeeping). **RTC_TR is BCD**, not a linear counter like QEMU's PL031 --
`rtc_read_seconds()`/`examples/rtc/rtc.tkb`'s wait loop never subtracts two samples
(`0x09 -> 0x10` is a raw jump of 7, not 1, whenever the BCD units nibble rolls over, not
just at 60 seconds); the loop instead waits for the raw value to change once and, since
that's guaranteed to be exactly one tick by construction, prints a fixed `"1"` rather
than a computed difference. Software must read RTC_DR after RTC_TR (even if unused) to
unfreeze the calendar shadow registers for the next read (RM0385).

**NVIC vs. GICv2**: GICv2 has one shared IRQ vector; the ISR reads `GICC_IAR` to learn
which source fired (software dispatch by ID) and writes `GICC_EOIR` to acknowledge.
NVIC vectors *directly* to a per-source handler address (`examples/common_stm32/
startup.S`'s vector table, covering core exceptions through Ethernet IRQ61) -- no software
dispatch table or EOI register at all; reading/clearing the peripheral's own interrupt
flag (e.g. USART1 RDR read clearing RXNE) *is* the acknowledgment. USART1 = IRQ37
(confirmed via search), vector position 16+37=53, byte offset `0xD4`.

**SysTick+PendSV preemptive scheduler** (`irq_dispatch(frame_sp) -> frame_sp` on the
AArch64 side splits into two on Cortex-M):
- `SysTick_Handler` (plain takibi -- SysTick auto-reloads from `LOAD`, no per-tick rearm
  needed unlike the ARM Generic Timer's `tval`) does per-tick bookkeeping, then requests
  a switch via `pendsv_trigger()` (sets `ICSR.PENDSVSET`).
- `PendSV_Handler` (hand-written asm, `examples/common_stm32/startup.S`, always present
  and lowest priority via `SHPR3=0xFF`) is the only place touching PSP: saves r4-r11
  (hardware already stacked r0-r3/r12/lr/pc/xPSR), calls takibi's
  `pendsv_dispatch(sp) -> sp` (same shape as `irq_dispatch`, round-robin `tcb_sp` swap
  only, no IAR/EOIR), restores r4-r11, `msr psp`, returns via `EXC_RETURN=0xFFFFFFFD`.
- `setup_task_stack` keeps its exact AArch64 name/signature so callers are unchanged;
  only the frame differs -- 64 bytes (8 words hardware-shaped: r0-r3,r12,LR=
  task_exit_stub,PC=f,xPSR=0x01000000; 8 words software-shaped below: r4-r11=0) instead
  of AArch64's 272-byte one. `task_exit_stub` is a plain takibi `while (true) {}` --
  Cortex-M needs no assembly stub for this.
- `sem_wait`/`sem_post` (`examples/common_stm32/sem_asm.S`): ARMv7-M `ldrex`/`strex`
  with explicit `dmb` (no acquire/release-encoded instructions like AArch64's
  `ldaxr`/`stlxr`), `dmb` placed after the successful acquire and before the release
  store (standard ARM Cortex-M synchronization-primitives placement).

**Critical bug found and fixed: MSP/PSP must not overlap.** `Reset_Handler` switches
Thread mode to PSP (`CONTROL.SPSEL=1`) before calling `main`, since a preemptive-
scheduler example treats `main()` as "task 0", switched via the exact same PendSV
mechanism as its explicitly-created tasks -- `main()` must already be on PSP by the
time SysTick/PendSV can first fire (PendSV_Handler unconditionally reads/writes PSP,
but Cortex-M defaults to MSP for everything after reset). The first version of this
switch did `mrs r0,msp; msr psp,r0` -- a plain copy, giving MSP and PSP the *same*
starting address, so the two stacks fully overlapped rather than occupying separate
memory. Every `preempt`/`semaphore`/`condvar`/`msgqueue` test happened to pass anyway
(their task functions and SysTick_Handlers are shallow enough that the corruption never
touched anything load-bearing) until `watchdog` -- whose `SysTick_Handler` calls the
real function `wdt_check()`, using more MSP stack depth -- hit a HardFault. Confirmed via
`openocd`/`gdb-multiarch` register inspection: `CFSR` (`0xE000ED28`) bit 18 = INVPC,
`HFSR` (`0xE000ED2C`) bit 30 = FORCED, `LR = 0xFFFFFFFD` (the fault was inside PendSV's
own exception-return path). Fixed by reserving the top `0x800` (2KB) of the boot stack
region exclusively for MSP and starting PSP that much lower
(`mrs r0,msp; sub r0,r0,#0x800; msr psp,r0`), giving each stack a genuinely separate
region. **Any future change to this switch must keep the two stacks non-overlapping.**

**Hardware test harness: Flash execution** (historical -- both hardware test targets have
since moved to RAM execution, see below; this describes the now-deleted `scripts/
run_hwtest.sh` and `scripts/run_hwtest_net.sh`, formerly `make hwcheck-stm32`'s and
`make hwcheck-stm32-net`'s implementations): flashed via `st-flash write` and captured UART output, diffing
against the *same* `.expected` files `run_qemutest.sh` already uses (`uart_puts`/
`uart_print_*` write identical bytes on either HAL). Two things had to be solved that
QEMU's semihosting-exit model doesn't need to deal with:
- `st-flash write` itself resets and runs the newly-flashed program as a side effect,
  before the harness ever opens the serial port -- and that unread run's output doesn't
  vanish cleanly (a short tail fragment survives in a small kernel/USB-CDC buffer and
  would otherwise contaminate the *next* capture). Fixed with a drain step (open the
  port, discard whatever's already sitting there) before the real, explicitly-triggered
  `st-flash reset` that the harness actually measures.
- A fixed-duration `timeout N cat` capture (this project's first approach) was
  needlessly slow multiplied across ~40 examples per run, *and* wrong for examples with
  a real mid-test pause (`rtc`/`timer` wait up to an LSI-clocked "second" between two
  print statements; a naive short idle-quiet threshold mistook that pause for
  completion and truncated the capture). Replaced with `read_until_quiet`: polls file
  size until no growth for N consecutive polls, with a `WAIT_FOR_DATA` gate (don't
  declare quiet before anything has arrived at all -- needed since the reader starts
  before the `st-flash reset` that actually triggers output) and per-call overrides for
  tests needing a longer pause tolerance (`rtc`/`timer` use a much longer idle threshold
  than the ~200ms default). Cut the full suite from ~125s to ~30-45s.
- `echo`/`irq` (the two examples needing input) use `run_hw_test_stdin`: waits for the
  first output byte (confirming the firmware's read loop has actually started, since
  USART's RDR is only 1 byte deep -- writing input any earlier risks an overrun) before
  writing the `.stdin` file to the serial port.

**Hardware test harness: RAM execution** (`scripts/run_hwtest_ram.sh` + `scripts/
run_hwtest_net_ram.sh`, `make hwcheck-stm32` + `make hwcheck-stm32-net`, current implementation for
both): every one of hwcheck-stm32's ~41 example binaries is well under Flash
Sector0's 32KB, so flashing all of them on every run used to erase/write that one physical
sector 41 times per run -- against a guaranteed minimum endurance of roughly 10,000 erase
cycles, only ~200 `make hwcheck-stm32` runs before Sector0's guaranteed lifetime is exhausted, a
real concern once hwcheck-stm32 starts running frequently in CI (not yet, but planned). Migrated
to loading the linked ELF directly into AXI SRAM1 (0x20010000, 240K, NOT DTCM -- see below)
over the debug port via OpenOCD instead: `reset halt` (never `reset init`, which would
reprogram the clock tree away from the 16MHz HSI every `uart_init()` assumes), `load_image`
the ELF, then read the initial SP/PC out of word 0/word 1 of the image's own vector table
and poke them into the SP/PC debug registers by hand before resuming -- manually doing, once
per test, exactly what silicon does automatically when booting from Flash. No Flash write
happens anywhere in this path. See `examples/common_stm32/startup_ram.S`'s header comment
for the full mechanism (including why VTOR must be set in code, not by the harness) and
HISTORY.md's RAM-execution entry for the full design discussion (why AXI SRAM1 over DTCM,
why no explicit MPU region is needed, and the flash-endurance arithmetic).

**`hwcheck-stm32-net`'s real-Ethernet examples migrated too, with one deliberate difference
from every other example: their DMA descriptor rings and packet buffers are genuinely
cacheable.** `link_ram.ld` gives them the same uniform AXI SRAM1 as everything else -- no
MPU non-cacheable window. This makes `examples/common_stm32/eth.tkb`'s existing
`dma_prepare_tx`/`dma_prepare_rx`/`dma_finish_rx` calls load-bearing for the first time --
previously the non-cacheable window meant those calls' cache clean/invalidate instructions
were architectural no-ops. Validated against real hardware over the wired point-to-point
link (`make hwcheck-stm32-net`, including varying frame payload sizes 46-1486
bytes and a full TCP handshake/data-echo/close/reconnect cycle) before generalizing, not
just reasoned about from reading the driver -- see HISTORY.md's RAM-execution entries for
the full code-reading pass that preceded this and why it was judged safe in advance.

**Follow-up: `stm32build` itself (not just the hardware test targets) consolidated onto
RAM execution too, with one deliberate exception.** Every STM32 example except
`examples/http_server` dropped its Flash build entirely -- `stm32build` now IS what used
to be a separate `stm32build-ram` target, and there is no more `link.ld` (deleted) or
per-example Flash `kernel_stm32.elf`/`.bin` for anything but http_server. http_server kept
its own explicit Flash build rule (`examples/http_server/kernel_stm32.elf`/`.bin` -- NOT a
`stm32build` prerequisite; built on demand by `make stm32-http-server` and, since the
follow-up below, by `make hwcheck-stm32-net` too) specifically so a demo unit can boot the HTTP
server standalone from power-on with no debugger attached -- RAM execution cannot do this
at all, since AXI SRAM1 loses its contents the moment power is removed.
`examples/common_stm32/startup.S`'s AXI SRAM1 MPU window was changed the same way as the
RAM-execution path (non-cacheable window removed, relying on the same ARMv7-M default map)
so this one remaining Flash build uses the identical cache policy as everything else --
verified with a genuine `st-flash write` + `st-flash reset` (not the debugger
halt-and-poke `--connect-under-reset` sequence hwcheck-stm32-net's own validation used) followed
by the real HTTP test script, confirming the standalone, non-debugger-mediated boot path
specifically, not just the debugger-mediated one. See HISTORY.md's RAM-execution entries
for the full reasoning behind keeping exactly this one exception and nothing more.

**Follow-up: that Flash-boot verification turned into a permanent, automated test, not a
one-off manual check.** Once every other example moved off Flash entirely, http_server's
Flash build became the ONLY Flash-execution boot path anywhere in this repository -- and
a real hardware boot-vector fetch from address 0x0 (silicon reading SP/PC from Flash
directly) is a genuinely different code path from every hardware test elsewhere in this
project, all of which use OpenOCD's `reset halt` + debugger register poke instead. With
every other example's Flash build gone, nothing would have caught a regression specific
to that boot path (or to this Flash build's now-cacheable AXI SRAM1 MPU change) until
someone happened to run `make stm32-http-server` by hand. `scripts/run_hwtest_net_ram.sh`
now runs http_server TWICE: `http_server (stm32/ram)` (unchanged) and a new
`http_server (stm32/flash)`, which does a genuine `st-flash write` + `st-flash reset` of
`examples/http_server/kernel_stm32.bin` (the exact sequence `make stm32-http-server`
itself performs, `--connect-under-reset` included) before running the same
`eth_http_server_test.py`. `hwcheck-stm32-net`'s own prerequisites gained
`examples/http_server/kernel_stm32.bin` accordingly. Confirmed on real hardware: all
`hwcheck-stm32-net` tests pass at the time (6 then; more have been added since, e.g.
`http_server_sdcard`'s own RAM+Flash pair -- see HISTORY.md), adding only ~2s to the
suite's total runtime.
