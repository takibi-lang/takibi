# takibi - Takibi Language

**takibi** is a from-scratch programming language and compiler, implemented in
OCaml, that generates native machine code through an LLVM backend.

The language is designed for **bare-metal embedded programming**, where a
runtime panic or trap is not an acceptable failure mode. The long-term goal of
this project is to implement a TCP/IP stack and run an HTTP server on
bare-metal targets -- and that goal is already reached today on both QEMU
(AArch64) and real
[STM32F746G-DISCOVERY](https://www.st.com/en/evaluation-tools/32f746gdiscovery.html)
(Cortex-M7) hardware.

For the current language syntax and grammar (types, statements,
expressions), see [`SPEC.md`](SPEC.md).

## Design Principle: Detect Errors at Compile Time

In embedded products, zero runtime exceptions and panics is a hard
requirement. If a runtime trap occurs in a bare-metal environment running
timers, UART, and a TCP/IP stack, the system will silently break with nothing
communicated to the user. takibi's type system is built around pushing as
many of those failures as possible into compile-time errors instead:

- The compiler currently emits an `icmp uge` + `llvm.trap` bounds check on
  array indexing when the index range cannot be proven safe. On AArch64 this
  lowers to a `brk #0` (a real hardware trap) -- acceptable for development,
  but a bug in shipped firmware.
- The refinement type `{lo..<hi as base}` is how the type system removes the
  trap entirely: if `hi <= N` and `lo >= 0` can be proven at compile time for
  an array of size `N`, no bounds-check code is generated at all. The base is
  explicit; refinements are not implicitly represented as `i32`.
- Array/slice indices are `usize`; raw-pointer offsets are `isize`. Choosing
  an unrefined integer (unknown range: MMIO, external input, ...) versus a
  refined integer is a deliberate part of the API. An unproven `usize` array
  index receives a checked access; an integer of the wrong base is rejected.

"Code with remaining bounds checks = code whose type annotations are still
insufficient." The finished form of a piece of code is one where every index
range is pinned at the type level using `for i: usize in 0..<n` or
`{lo..<hi as usize}`
annotations.

## Development Workflow: Gradual Elimination of Runtime Traps

takibi's central bet is a workflow, not just a type system. Languages like
SPARK or Dafny demand full rigor from the first line; takibi instead
supports **raising rigor as the development phase advances**, at the
language level:

1. **Prototype freely.** By default, unproven array accesses and range
   casts compile fine and get a runtime check (`llvm.trap` on violation).
   A trap firing during driver bring-up is not treated as a shameful bug --
   it is a *signal that type information is missing*, pointing at exactly
   the access whose range the programmer has not yet expressed.
2. **Strengthen incrementally.** Replace raw indices with `for i in 0..<n`
   loops, `{lo..<hi as base}` refined types, slice types (`[u8; 54..]`) and
   `if (v >= 0 && v < N)` / `if (s.len >= N)` narrowing. Each addition of
   type information makes checks (and their traps) *provably unnecessary*,
   and the compiler deletes them.
3. **Ship with `--forbid-trap`.** The compiler then rejects the program if
   ANY runtime trap check remains, listing every unproven site with its
   source location. A binary that builds under this flag contains zero
   trap instructions -- the "no runtime panics" requirement is a build
   result, not a code-review hope.

Two design invariants keep this path monotonic: proofs are never lost
silently (an immutable binding keeps what its initializer proved, even
under a weaker type annotation), and unchecked assertions are never
invisible (constructs that ask the compiler to *trust* rather than *check*
-- e.g. building a slice from a raw pointer at a driver boundary -- must
be wrapped in `unsafe { ... }`, so they are seen when written and when
read).

`--forbid-trap` is expected to grow into a family: per-category strictness
options (array-bounds trap freedom, checked-cast freedom, safe-pointer
enforcement outside `unsafe`, ...) with one umbrella flag enabling them
all. Today's single flag is the first member. **The entire example suite
-- including the full TCP/IP stack, HTTP server, and the FAT12-on-real-SD-
card milestone (`examples/fatfs`, `examples/common/fat12.tkb`,
`examples/common_stm32/sdmmc.tkb`, `examples/sdcard`,
`examples/fatfs_sdcard` -- issues #61/#62/#98) now compiles trap-free
under it,** with no remaining exceptions. `examples/common_stm32/
sdmmc.tkb`'s SDMMC1 driver (issue #62) is deliberately asymmetric:
`disk_write` is DMA + interrupt driven, matching `eth.tkb`'s own
DMA+interrupt shape, but `disk_read` is plain polling -- a DMA
`disk_read` was built and tested but reliably corrupted memory once
issued after ~129 prior writes, an issue that survived three fixes
cross-checked against ChibiOS's proven STM32 SDMMCv1 driver and remains
genuinely unresolved (root cause not identified; possibly this driver,
possibly an STM32F7 quirk, possibly specific to the individual board or
SD card used). Separately, `fatfs_sdcard`'s real-hardware test used to
occasionally show a single dropped UART byte (GitHub issue #101) --
confirmed unrelated to `--forbid-trap` itself (reproduced identically on
the pre-`--forbid-trap` version too). Root-caused to a UART TX
architecture mismatch, not a single race condition: `uart.tkb`'s TX used
to be per-byte-interrupt driven while `sdmmc.tkb`'s `disk_write` is
DMA+interrupt driven, an asymmetric combination that let heavy SDMMC1 DMA
activity intermittently starve/corrupt the UART's own interrupt-driven
drain. Fixed by switching UART TX to DMA+interrupt too (DMA2 Stream7/
Channel4), matching `sdmmc.tkb`/`eth.tkb`'s own shape and ChibiOS/RT's
convention of using DMA+interrupt for both peripherals -- verified with
30 consecutive clean runs of the exact reproduction pattern (previously
~1-in-6-10 failure) plus the full `make hwcheck`/`make hwcheck-net`
suites. See `uart.tkb`'s and `sdmmc.tkb`'s own header comments and
HISTORY.md for the full bring-up stories, including a separate, resolved
TXUNDERR bug in `disk_write`, root-caused by cross-checking the same
ChibiOS driver. A few tools do almost all of the work: refined integer ranges
that propagate through ordinary arithmetic and bitwise masking (so a
value like a wire-derived header length carries a real bound with no
extra code), `min`/`max` builtins that provably clamp a value against a
compile-time buffer capacity regardless of its actual runtime value, and
plain input validation (checking a wire-derived length against a buffer's
real capacity before trusting it -- not a type-system trick, just what a
correct parser needs to do anyway, and it happens to make the surrounding
code provable too). Where a bound genuinely can't be proven this way --
typically because two values are secretly correlated in a way plain
interval reasoning can't see -- the code says so explicitly with
`unsafe { ... }`, rather than silently falling back to an unexplained
runtime check. As of this writing, exactly **one** `unsafe` use remains
across the entire example suite -- everywhere else it was tried, removing
it turned out to be possible (and worth doing: two of the removals closed
real gaps, an unvalidated device-reported ring index and a lossy
intermediate slice reconstruction, not just cosmetic --forbid-trap
fixes). See CLAUDE.md's P4c section for the full accounting, including
two honest negative results (reformulations that don't close without a
genuine relational domain) and the case that looked like it needed one
but didn't: the fix turned out to be a missing validation check, not a
type-system gap.

## Design Principle: YAGNI (You Aren't Gonna Need It)

We do not design or build functionality before it is actually needed -- not just at the
implementation level, but at the design/planning level too. This is a durable stance for this
project's current prototype phase, not a one-off preference: "needed" means a real, present
requirement (an actual example that needs it, a real bug it fixes), not a plausible future one.
When a larger architectural goal would automatically subsume a smaller interim workaround, the
interim workaround is skipped rather than built and later discarded -- see `CLAUDE.md`'s own
"Design Principle: YAGNI" section for a concrete worked example. This does not excuse skipping
foundational work current features actually depend on (the compile-time-error-detection goal
above is this project's stated core purpose, not speculative scope) -- it applies to optional,
deferrable convenience and architecture work.

## Current Status

- A full pipeline exists: lexer -> Menhir parser -> Hindley-Milner type
  inference -> LLVM 19 IR generation -> native object code.
- The example suite compiles and runs today (see `examples/`),
  covering arithmetic, control flow, structs (packed / aligned), enums with
  exhaustiveness checking, function pointers, MMIO/volatile access,
  compile-time-checked array bounds via refinement types, semaphores,
  mutexes, condition variables, a preemptive round-robin scheduler, a
  hand-written TCP/IP stack, and a FAT12 filesystem driver (`examples/fatfs`,
  verified against real `mtools`-created images on both QEMU and real
  STM32 hardware; real SD/eMMC card integration is still pending).
- DMA/device ordering is expressed through compiler builtins rather than
  handwritten assembly. The STM32 port also performs cache maintenance,
  places DMA memory in an MPU non-cacheable window, and uses affine opaque
  receive handles to reject double release and use-after-release.
- Ethernet and STM32 UART I/O are interrupt-driven. ARM/AArch64 retained
  events (`wfe`/`sev`) avoid both idle busy-spins and check-then-sleep lost
  wakeups.
- **The TCP/IP stack goal has been reached**: `examples/http_server` serves a
  live HTML page with a request counter over a real TCP connection, reachable
  from an actual web browser, both under QEMU (via a virtio-net driver) and on
  real STM32F746G-DISCOVERY hardware (via a from-scratch Ethernet MAC/PHY/DMA
  driver in `examples/common_stm32/eth.tkb`).
- Every ported example is a **single `.tkb` application source file** that
  compiles unchanged for QEMU/AArch64 and STM32/Cortex-M7. Platform-specific
  behavior is supplied by same-signature HAL files selected by the Makefile.
- Applications expose `app_main()`. A shared high-level runtime `main()` calls
  `platform_init()`, `app_main()`, and `platform_shutdown()`; startup assembly
  remains independent of individual device drivers.
- DWARF debug-info emission (`-g`) and a small gdbstub-based sampling
  profiler are implemented, along with an analysis of what this profiling
  technique is (and is not) useful for on interrupt-driven I/O code.

See [`SPEC.md`](SPEC.md) for the current language syntax and grammar, and
`CLAUDE.md` for the full, continuously-updated engineering log of design
decisions, hardware bring-up bugs, and the reasoning behind them.

## Demo: Serving a Real Web Page from an STM32F746G-DISCOVERY Board

This walks through reproducing the project's headline result yourself: a
takibi-compiled HTTP server, running with no operating system on a real
STM32F746G-DISCOVERY board, answering requests from an ordinary web browser
over a real Ethernet link.

### What you need

- An STM32F746G-DISCOVERY board (its on-board ST-LINK/V2-1 debug probe is
  used for both flashing and the serial console -- no separate probe needed).
- A micro-USB cable (ST-LINK: power, flashing, and the UART log all go over
  this one cable).
- An Ethernet cable, and a spare Ethernet NIC on your Linux host that you can
  dedicate to a direct link to the board (no router or switch required --
  a plain point-to-point cable is enough, since the demo uses a fixed IP
  address with no DHCP).
- A Linux host with the toolchain in "Dependencies" below installed --
  `openocd`, `stlink-tools`, and the rest of the standard build. The
  `.devcontainer/` in this repo already has everything installed; opening
  the repo in that devcontainer (VS Code's "Dev Containers" extension, or
  any OCI-compatible tool that reads `devcontainer.json`) is the easiest way
  to get a working environment.

### 1. Connect the board

Plug the micro-USB cable into the board's ST-LINK USB port and into your
host. Connect an Ethernet cable between the board's Ethernet jack and the
NIC you're dedicating to this demo.

### 2. Give your host NIC a matching address

The board always serves on a fixed address, `192.168.10.2/24`
(you can configure `examples/common_stm32/netconfig.tkb`).
Put your host's NIC on the same `/24` so it can reach the board directly,
with no routing needed:

```bash
sudo ip addr add 192.168.10.1/24 dev <your-interface>
sudo ip link set <your-interface> up
```

Replace `<your-interface>` with whatever `ip link` shows for the NIC wired
to the board (e.g. `enp4s0`).

### 3. Confirm the board is visible to the toolchain

```bash
st-info --probe
```

This should report the on-board ST-LINK. If it fails, check USB
permissions (the devcontainer already adds its user to the `plugdev` and
`dialout` groups for this).

### 4. Build, flash, and run

```bash
make stm32-http-server
```

This compiles `examples/http_server` for the STM32/Cortex-M7 target (if not
already built), flashes it to the board via `st-flash`, and streams the
board's UART log to your terminal. It prints the URL to open, e.g.:

```
Open http://192.168.10.2/ in your browser (Ctrl-C to quit)
```

### 5. Open it in a browser

Visit the printed URL. You should see a small HTML page served directly by
the board, with a live request counter that increments every time you
reload.

### 6. Stop

Ctrl-C in the terminal running `make stm32-http-server` stops streaming the
log. The board itself keeps serving until it's powered off or reflashed.

### Troubleshooting

- `error: ... not found -- is the STM32F746G-DISCOVERY board connected?` --
  the board's USB serial device wasn't found at the expected path. Check
  `dmesg` for where it enumerated and override with, e.g.,
  `STM32_SERIAL_DEV=/dev/ttyACM1 make stm32-http-server`.
- `st-info --probe` fails -- a USB permissions issue; see step 3 above.
- Browser can't reach `192.168.10.2` -- confirm the NIC's address with
  `ip addr show <your-interface>` and that the Ethernet cable is actually
  linked up (`ip link show <your-interface>` should say `state UP`).

## Building and Testing

```bash
make build          # build the compiler (takibi) only
make test           # run unit tests
make qemutest        # build every example and verify it under QEMU (AArch64)
make stm32build      # cross-compile every ported example for STM32 (no hardware needed)
make check           # langcheck + test + stm32build + qemutest
make hwcheck          # like stm32build, but also flashes + verifies against real STM32 hardware
make hwcheck-net      # real-Ethernet hardware tests (needs the board wired to this host's NIC)
```

Builds run in parallel across all cores by default.

### Dependencies

```
ocaml 5.4.0, dune, menhir
llvm-19 OCaml bindings (llvm, llvm.analysis, llvm.target, llvm.all_backends,
                        llvm.passbuilder, llvm.debuginfo)
ppx_deriving.show
llvm-mc-19, ld.lld-19     (bare-metal assembling/linking)
qemu-system-aarch64       (QEMU execution)
mtools                    (FAT12 image creation/verification for examples/fatfs)
gdb-multiarch             (AArch64-capable gdb, for profiling/hardware debugging)
openocd, stlink-tools     (STM32F746G-DISCOVERY flashing/debugging)
```

A ready-to-use devcontainer configuration is provided in `.devcontainer/`.

## Directory Layout

```
lib/       -- lexer, parser, type inference, LLVM code generation
bin/       -- the takibi CLI
examples/  -- example programs, each demonstrating one feature or
              building toward the TCP/IP stack goal
scripts/   -- QEMU/hardware integration test runners and profiling tools
test/      -- unit tests (parser, type inference, LLVM code generation/layout)
```

Each directory under `examples/` documents itself in its `.tkb` file's
header comment. `examples/common/` holds platform-agnostic logic shared by
both targets; `examples/common_qemu/` and `examples/common_stm32/` hold the
QEMU and STM32 hardware-abstraction layers (UART, timers, interrupt
controllers, Ethernet), sharing function names/signatures so application
code is written once.

## Targets

- QEMU `virt` machine, `cortex-a53` CPU (AArch64 bare-metal).
- STM32F746G-DISCOVERY (Cortex-M7 bare-metal), flashed and verified
  against real hardware.

## Acknowledgements

The most implementation were written with assistance from Claude Code.

## License

GPLv3 -- see `LICENSE`.
