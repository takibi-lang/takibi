# Deferred divisor proof space review (2026-10-14, #791)

Change: lib/type_inf.ml retries the nonzero proof of a divisor whose type
was unresolved when its division was inferred, at the end of the enclosing
function. Compiler-only; it can only remove divide-by-zero trap sites.
Measured with `python3 scripts/space_delta.py main` (main 3474d149):

| | qemu base | qemu change | rpi5 base | rpi5 change |
|---|---|---|---|---|
| text | 695216 | 695216 | 745264 | 745264 |
| data | 4744 | 4744 | 2889536 | 2889536 |
| bss | 1486160 | 1486160 | 1692672 | 1692672 |
| usable_ram_start | 0x40218000 | 0x40218000 | 0x718000 | 0x718000 |

No section or data/BSS symbol changed: the maintained kernel has no divisor
of this shape left (the #740 workaround folded the constant). Adopted.
