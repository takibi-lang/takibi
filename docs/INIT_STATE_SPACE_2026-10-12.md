# Definite initialization, stages 1-2: space review (2026-10-12)

GitHub issue #203 stages 1 and 2: field-path init tracking in the checker,
`syscall_scratch` as a scratch global, zero fills before each staged copy,
and `syscall_ext2_reader` moved out of the scratch struct.

Measured with `python3 scripts/space_delta.py main` (main fa63884f), linked
production kernels, llvm-size:

| | qemu base | qemu change | rpi5 base | rpi5 change |
| --- | --- | --- | --- | --- |
| text | 705112 | 705992 (+880) | 717944 | 718800 (+856) |
| data | 5424 | 5432 (+8) | 2889288 | 2889296 (+8) |
| bss | 1660672 | 1660672 | 1697360 | 1697360 |
| usable_ram_start | 0x40248000 | 0x40248000 | 0x710000 | 0x710000 |

Symbols: `syscall_scratch` 11700 -> 11696 B (the bool left the struct),
`syscall_ext2_reader` new, 4 B. BSS and the page reservation are unchanged.

Text grows by the zero-fill loops (one per staging function). Runtime cost,
not measured here: each read/write/sendfile/syslog/getdents syscall clears
the 4 KiB file buffer once per call (not per chunk), path syscalls clear
256 B, uname 512 B, rlimit 16 B, bind 28 B, an ELF exec probe 4 KiB. The
maintainer accepted zero fills until stage 3's byte ranges can prove which
bytes a fill wrote; that is the point at which they can be removed.
