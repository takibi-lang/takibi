# Space review: kernel log ring, #613 slice 4 (2026-10-18)

Workload: the retained kernel log moves onto the option-B ring
(docs/LOG_RING_DESIGN.md, "As built, slice 4"). Measured with
`python3 scripts/space_delta.py origin/main` (base 46c2a1c0-era origin/main
after #816), both production kernels:

| | qemu base | qemu change | rpi5 base | rpi5 change |
| --- | --- | --- | --- | --- |
| text | 708212 | 713844 | 760848 | 766576 |
| data | 4800 | 4824 | 2889632 | 2889656 |
| bss | 1486512 | 1485104 | 1692736 | 1692736 |
| usable_ram_start | 0x40220000 | 0x40220000 | 0x720000 | 0x720000 |

Data/BSS symbols: removed `kernel_log_stamps`, `kernel_log_lengths`,
`kernel_log_cpu` (2048 B each) and five 8-byte counters; added
`kernel_log_slots`, `kernel_log_meta` (2048 B each), the core-0 line stage
`kernel_log_line` (640 B), four counters/stage fields and the 1-byte
`kernel_ddb_log_test_enabled`. Net BSS -1408 B on QEMU; on RPi5 the BSS
total is unchanged (section alignment absorbs it). The image span and so the
page reservations did not move.

Text +5632 B (qemu) / +5728 B (rpi5): the reservation, claim, commit and
discard paths, the multi-slot reader with its per-slot re-check, the DDB
`log`/`logtest` renderers, and the larger boot probe (refusal, multi-slot and
continuation cases). This is the transitional cost of slice 4: the peer
rings, their drain and the per-core 192-byte line buffers
(~6 KiB text storage plus their code) still exist and are deleted in slice 5,
which the design expects to make the net change a decrease.

Assessment: accepted. No stack buffer was added (the line stage is static,
per the 2026-10-17 conservative-stack decision); the BSS change is a small
decrease; the text growth is explained and bounded.
