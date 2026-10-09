# Churn diagnostic milestone space review (2026-10-09)

The QEMU churn GDB reader, forward-only ASID injection and shortened finder
are host tools. Their compiler-generated layout sidecar is not linked into
either production kernel. No production Takibi source, kernel allocation
phase, pool capacity or storage lifetime changes.

Fresh builds from `python3 scripts/space_delta.py d1c075ca` compare the
production kernels before and after this milestone:

base d1c075ca -> working tree
| | qemu base | qemu change | rpi5 base | rpi5 change |
| text | 726236 | 726236 | 736604 | 736604 |
| data | 5078 | 5078 | 2888784 | 2888784 |
| bss | 1658608 | 1658608 | 1697600 | 1697600 |
| usable_ram_start | 0x40248000 | 0x40248000 | 0x718000 | 0x718000 |
no data/BSS symbol changed size

All linked text, data and BSS sizes, every data/BSS symbol size and both
usable_ram_start boundaries are unchanged. Adopt the diagnostic tools at
zero kernel image growth. This image comparison is distinct from live pool
occupancy: the unchanged bounded-boot workload retains the prior allocation
and pool evidence at its original strength. No new workload justifies an OS
comparison here.

The real four-core shortened workload reaches rollover with an injected
unassigned counter and does not retain more pages in its second phase. The
seeded four-core diagnostic lane establishes decoding, write refusal and
transport cleanup, not natural wrap timing or physical cache coherence.

Production source fingerprint: `2b3076522f3b66a9e02f1548d83dcab8f43e02c86504cc8c22d113bbb0ca69c7`.
Measure again when production diagnostics gain storage, an allocation
workload or resource lifetime changes, or the next kernel stage completes.

Acceptance observations: the production shortened finder passed with
rollovers 1 -> 2 and phase-two pages-live unchanged at 2724. Reverting only
the QEMU INTID extraction passed one sample and stalled in two additional
samples. The watchdog captured owner_cpu 3 and 2 respectively in
world_stop_begin_claimed, all four acknowledgements zero, next=65536 and
idle peers with CPSR 0x80000345 (IRQs open). Four subsequent DDB attempts
reported world-stop busy. This is an observed 2/3 negative-sample failure
rate, not a proven rate or deterministic protocol lane.

## Review after upstream integration

The feature was rebased onto 3f43fa26, including checked-place reference
typing. Fresh production links from `scripts/space_delta.py origin/main`
compare against that exact upstream:

base origin/main -> working tree
| | qemu base | qemu change | rpi5 base | rpi5 change |
| text | 726276 | 726276 | 736644 | 736644 |
| data | 5078 | 5078 | 2888784 | 2888784 |
| bss | 1658608 | 1658608 | 1697600 | 1697600 |
| usable_ram_start | 0x40248000 | 0x40248000 | 0x718000 | 0x718000 |
no data/BSS symbol changed size

The upstream's 40-byte text increase is included on both sides of this
comparison; this host diagnostic feature still adds zero kernel bytes.
Current production source fingerprint: `2c881e00bf8b43464dc141db138a53b3d38f4fb03b8f5ee08cef3abd31183abf`.
