# Space review: kernel log ring, #613 slice 5 (2026-10-18)

Workload: every CPU writes the option-B ring directly
(docs/LOG_RING_DESIGN.md, "As built, slice 5"); the per-core peer slot
rings, core 0's drain and its deferred attribution are deleted, the line
stage becomes one static 640-byte stage per CPU, kernel lines reach the UART
whole after their commit, and the boot runs the all-CPU log storm. Measured
with `python3 scripts/space_delta.py origin/main` (origin/main = 05a3ea7c,
slice 4 landed), both production kernels:

| | qemu base | qemu change | rpi5 base | rpi5 change |
| --- | --- | --- | --- | --- |
| text | 713764 | 716028 | 766488 | 768728 |
| data | 4824 | 4704 | 2889656 | 2889536 |
| bss | 1485104 | 1479232 | 1692736 | 1684624 |
| usable_ram_start | 0x40220000 | 0x40220000 | 0x720000 | 0x720000 |

Data/BSS symbols: removed the peer rings (`kernel_log_peer_text` 6144 B,
`_lengths`, `_published`, `_ticks` 256 B each, `_truncated`, `_latest`,
`_consumed` 32 B each), the drain statistics (five words and an 8-byte
array), core 0's global stage (`kernel_log_line` 640 B and five stage
fields) and the deferred cpu/tick/flag; `kernel_log_core_state` grows
896 -> 2656 B (four 664-byte entries, each holding its CPU's 640-byte stage,
instead of four 224-byte entries holding a 192-byte peer line). Added:
`kernel_log_last_discarded` (8 B) and the storm's words (7 x 8 B, two
32-byte arrays). Net BSS -5872 B qemu, -8112 B rpi5. The image span and the
page reservations did not move.

Text +2264 B qemu / +2240 B rpi5. Of that, the all-CPU log storm (writer,
verifier and rendezvous) is 2552 B on qemu; without it the slice is -288 B:
deleting the peer publish, drain and record emitter roughly pays for the
whole-line UART emitter, the per-CPU indexing, the staged-line view in DDB
and the loss-by-sequence reporting.

Against slice 4's expectation: slice 4 called its +5.6 KiB text
transitional and expected slice 5 to make the net a decrease. That is true
for BSS only. The storage deleted here was BSS (the 6 KiB peer text was
data, not code), and the code of the peer path was about the size of what
replaces it. The +5.6 KiB is the ring protocol itself -- reservation, claim
and commit through CASAL, the multi-slot reader with its re-checks, the DDB
renderers and the boot probe -- and is not transitional. Net since before
slice 4: text +7.8 KiB (2.5 KiB of it the storm), BSS -7.3 KiB qemu /
-8.1 KiB rpi5.
