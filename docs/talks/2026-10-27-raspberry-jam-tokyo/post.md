# No more pulling the SD card

I gave a talk at Raspberry JAM Tokyo 2026.10 on 2026-10-27 about loading and
debugging a hobby OS on a Raspberry Pi 5 over SWD, using the official Debug
Probe. The slides are below.

The OS is Takibi, a research prototype in which I am building a language and a
kernel together. This talk left the language out entirely. It is about what it
took to load and debug a self-made OS on real hardware every day.

I chose the RPi5 because it is easy to buy and cheap -- the Debug Probe costs
a few thousand yen -- while still having four Cortex-A76 cores and plenty of
documentation. The 3-pin debug connector carries SWD or UART but not both, so
the UART comes out on GPIO14/15.

## Only a stub on the SD card

The SD card holds a stub of about 100 lines, written once. It saves the DTB
the firmware hands over and waits in `wfe`. Every new kernel goes in by
halting the CPU with OpenOCD, loading the image straight into RAM over SWD,
and resuming.

OpenOCD 0.12.0 ships no `bcm2712.cfg` for the RPi5, so I vendored the one
published in [an article on raspi.jp](https://www.raspi.jp/2024/03/raspberry-pi-5-hardware-debbuging/).
The Japanese community saved me a lot of work here. The config defaults to
1 MHz, but on my setup 30 MHz works fine.

## Where I got stuck

- **No reset line**: the Debug Probe's SWD wiring has no nSRST, so
  `reset halt` stops with "how to reset?". Instead I write a two-instruction
  trampoline that calls PSCI SYSTEM_RESET and let the CPU run it -- the same
  path Linux's `reboot` takes.
- **EL2 does not mean it is my OS**: Cortex-A76 has VHE, so Linux runs its
  whole kernel at EL2 too. I now decide by whether the halted PC is below
  32 MB, not by the exception level.
- **The memory you see may not be real**: SWD reads DRAM, not the cache. CPU
  state is read from registers, and the kernel cleans the cache before it
  parks.
- **A failed write still exits 0**: halted in EL0, OpenOCD cannot write
  kernel memory, and it still exits with status 0. I stop in EL1 with a
  hardware breakpoint in the IRQ handler, then read the value back to
  confirm the write.

Every script is in the repository. I hope it helps anyone writing their own
OS on an RPi5.

## Resources

- Slides: (SlideShare link)
- Source of the OpenOCD config: [raspi.jp (2024/03)](https://www.raspi.jp/2024/03/raspberry-pi-5-hardware-debbuging/)
- RPi5 JTAG setup: [kernel/README.md](https://github.com/takibi-lang/takibi/blob/ab3e773af9703ce2024080e95bd12213d9c41c87/kernel/README.md#L640)
- Repository: [github.com/takibi-lang/takibi](https://github.com/takibi-lang/takibi)
