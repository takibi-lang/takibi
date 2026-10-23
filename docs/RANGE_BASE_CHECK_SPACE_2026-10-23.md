# Range base check space evidence (2026-10-23, #935)

Change: the compiler drops a propagated refined range that its base cannot
hold (refined `+`, `-`, `* k`, `/` folding, `%`, `&`, and casts; an unsigned
base needs a non-negative lower bound), and kernel/net/tcp.tkb computes
`data_len` as a plain u16 subtraction instead of the no-op
`max(tcp_len - tcp_hdr_len, 0)`.

Measured with `python3 scripts/space_delta.py origin/main` (base 91ddd4bb):

| | qemu base | qemu change | rpi5 base | rpi5 change |
|---|---|---|---|---|
| text | 737920 | 737920 | 792064 | 792064 |
| data | 4792 | 4792 | 2889640 | 2889640 |
| bss | 1481840 | 1481840 | 1690736 | 1690736 |
| usable_ram_start | 0x40220000 | 0x40220000 | 0x720000 | 0x720000 |

No data/BSS symbol changed size. No maintained kernel site lost an elided
check: no proof in the kernel depended on a range the fix drops.
