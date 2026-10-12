# Checked integer-to-enum match: linked-image space (GitHub issue #608)

Change: the compiler gains `match n as E { ... miss => ... }` and a direct
`Enum as usize` widening; kernel/kernel/process.tkb's
`kernel_activity_name_for_code` is rewritten from a nine-step comparison
chain into one such match.

Workload and boundary: both production linked kernels, built by
`python3 scripts/space_delta.py 97cc2779` (base 97cc2779, the #719
checkpoint, against the #608 working tree at 9249c4df). No allocation,
pool or lifetime behavior changes, so the bounded-boot pool samples are
not re-measured.

```
| | qemu base | qemu change | rpi5 base | rpi5 change |
| text | 693768 | 693576 | 706728 | 706536 |
| data | 5408 | 5408 | 2889272 | 2889272 |
| bss | 1658480 | 1658480 | 1697360 | 1697360 |
| usable_ram_start | 0x40240000 | 0x40240000 | 0x710000 | 0x710000 |
no data/BSS symbol changed size
```

Assessment: text shrinks by 192 B on both targets, because one switch
replaces the comparison chain. Data, BSS and usable_ram_start are unchanged.
Adopted; no further action.
