# Exec page reservation space review

Normal linked kernels were compared with a5c8342b2 on QEMU and
Raspberry Pi 5. The measured path is the existing static or dynamic
exec image commit, including lazy L3 allocation and conditional
image-record pool growth.

| Linked boundary | QEMU base | QEMU reservation | RPi5 base | RPi5 reservation |
| --- | ---: | ---: | ---: | ---: |
| Text, read-only and unwind data (bytes) | 832248 | 833896 | 4225444 | 4226996 |
| Writable data and GOT (bytes) | 4624 | 4624 | 5600 | 5600 |
| BSS and stack sections (bytes) | 1310720 | 1310720 | 1908736 | 1908736 |
| Usable RAM start | 0x40210000 | 0x40210000 | 0x7e0000 | 0x7e0000 |

Writable symbol sizes and the five allocator map expectations are
unchanged. The reservation remains 16 bytes and the page pool remains
16608 bytes (16624 in its locked cell). Both token modes use the same
layout. The ordinary mode reserves no pages.

Both architectures give the exec reservation and commit functions
static frames of 656 and 864 bytes, up from 640 and 832. The single-page
allocation wrapper and its common callee use 16 and 176 bytes before
lower calls, compared with 160 for the old entry. These are
per-function static measurements. They do not bound the whole stack
or measure elapsed allocation time.

The ordinary adapters consolidate the explicit no-debit scopes from
56 to 20. Eleven adapters leave no separate linked symbols. The two
boot mapping calls supply their scopes directly so the slot
acquisition entries remain leaves.
Inlining the four allocator wrappers as well removes their separate
linked frames but adds 80 bytes of linked text on QEMU and 48 on
RPi5, compared with the chosen layout. The narrower code size result
keeps those four calls. Current allocator debits take the issuer
from the borrowed reservation and need no executing CPU sample.

The compiler checks that the live reservation is borrowed and
consumed once. It distinguishes real and ordinary modes. Identity
between two live real reservations still rests on the exec flow
passing through its own token. Both kernel graphs reach the same
shared publication functions, both typed allocator entrances, and
no ordinary allocator entrance from the exec commit.

Remeasure when the reservation representation, allocator entry,
image mapping path or linked reservation changes.
