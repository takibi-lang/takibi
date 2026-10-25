# pipe2 space review (2026-10-25, GitHub issue #1042)

Feature: pipe2(2) with one bounded pipe per call (`kernel/kernel/pipe.tkb`),
two new shared-object kinds, a `Pipe` wait reason, and `pipe_wait` in every
process record.

## Linked images

`python3 scripts/space_delta.py origin/main` (base 75b1d57a):

| | qemu base | qemu change | rpi5 base | rpi5 change |
| --- | --- | --- | --- | --- |
| text | 685272 | 698092 | 739152 | 752036 |
| data | 4888 | 4896 | 6297616 | 6297624 |
| bss | 1485376 | 1485440 | 1690736 | 1690752 |
| usable_ram_start | 0x40218000 | 0x40218000 | 0xa58000 | 0xa58000 |

Data/BSS symbols that changed: `pipe_pool` (new, 24 B, the RegionPool body);
`scheduled_process_record_absent` and `signal_probe_record` 2072 -> 2080 B
(one `ProcessRecord` each). Text +12.8 KiB on both: pipe2, the pipe read,
write and ppoll paths, the pool, the wake walk. No page reservation moved.

## Pool payload (static accounting; QEMU lanes could not run in this session)

- `Pipe`: 4128 B (4096-byte ring, PIPE_BUF, plus lock, flags, start and
  length). A three-page chunk holds two pipes ((12288 - 48) / 4136 = 2), so
  a live pipe costs 6 KiB, and an empty chunk goes straight back. Linux's
  default pipe is sixteen pages of buffer plus `pipe_inode_info`.
- `SharedObject`: 80 -> 96 B for the pipe end's (address, generation); slots
  per one-page chunk 46 -> 38. Every open file description pays 16 B.
- `ProcessRecord`: 2072 -> 2080 B for `pipe_wait`.

No pipe exists in the bounded boot, so its pool samples do not move except
for the new `pipe` row (zero chunks). The ash transcript's pipelines and
`/bin/pipe-probe` hold at most two pipes at once (one chunk).

## Assessment

Adopted. The ring is the smallest size that keeps PIPE_BUF writes atomic;
the per-object 16 B follows fd_table.tkb's rule of one field per meaning
rather than reusing the TCP transport pair. A smaller SharedObject (a
union of the per-kind fields) is a separate proposal, not made here.
