# Console diagnostic tooling space review, 2026-10-09

The console GDB reader, compiler-owned layout sidecars, failure collector and
load reproduction loop run on the host. They add no linked kernel code,
globals, allocator payload, metadata or resource lifetime. The diagnostic
fixture starts QEMU before boot and seeds existing storage; those writes are
restricted to the fixture and are not production logging.

Measured with `python3 scripts/space_delta.py origin/main` after rebasing onto
the syscall copy-span migration. The candidate production source fingerprint
was `93f1b344bfa80140998416a7ee443679745af65166bc621f390545272403cb38`;
host-only fixes and the later roadmap rebase retained that fingerprint. Both production
kernels were freshly linked at the same source boundary; the baseline was
built in an isolated temporary worktree. `origin/main` resolved to
`e3e8639f` throughout this measurement.

| Boundary | QEMU baseline | QEMU candidate | RPi5 baseline | RPi5 candidate |
| --- | ---: | ---: | ---: | ---: |
| Text bytes | 726236 | 726236 | 736604 | 736604 |
| Data bytes | 5078 | 5078 | 2888784 | 2888784 |
| BSS bytes | 1658608 | 1658608 | 1697600 | 1697600 |
| Usable RAM start | 0x40248000 | 0x40248000 | 0x718000 | 0x718000 |

No data/BSS symbol changed size. The workload and image reservations are
unchanged; no new kernel allocation phase exists to measure. Keep the prior
bounded-boot pool evidence at its existing strength. These linked-image
observations do not establish physical cache behavior or reproduce a natural
console stall. The actual-QEMU diagnostic lane separately verifies queue
contents, unfinished RX lines, XOFF, TX IRQ enable, invalid bounds and stub
cleanup; forced states prove decoding, not the cause of a real stall.

Adopt the host tooling with zero production image growth. Measure again when
production diagnostics add storage, a new resource/lifetime or allocation
workload is introduced, or the next kernel feature/stage completes.
