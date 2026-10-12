# #720 protocol declarations: space measurement (2026-10-12)

Slices 1-3 of GitHub issue #720 (protocol declarations, generated sealed
owners, state access) against cf0bc567, the commit before them, measured with
scripts/space_delta.py (both trees built with their own dune root). No
maintained kernel declares a protocol yet, so the linked images are
expected to be identical; this records that they are.

```
base cf0bc567 -> working tree
| | qemu base | qemu change | rpi5 base | rpi5 change |
| text | 693768 | 693768 | 706728 | 706728 |
| data | 5408 | 5408 | 2889272 | 2889272 |
| bss | 1658480 | 1658480 | 1697360 | 1697360 |
| usable_ram_start | 0x40240000 | 0x40240000 | 0x710000 | 0x710000 |
no data/BSS symbol changed size
```

The only consumer is linux_user/protocol_ring, a native test outside the
kernel accounting boundary. Each generated state owner is one region
(identity, offset and count at run time, as any retained region); witness
views and state indices erase.
