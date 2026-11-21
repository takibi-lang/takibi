# User page publication

The QEMU and RPi5 kernels check full initialization at
`address_space_map_page`. New mappings, COW copies and zero replacements
pass their live `PageOwner` to this entry. The init clause names the
owner's full 4096-byte view. The compiler checks the accessor body and
uses that view as a specification term.

A fresh variant payload starts without initialization knowledge.
Direct moves carry the allocation's knowledge to the destination
binding. Consumption ends that record. A later allocation has to
establish its own coverage. Calls can establish the requirement from
body-checked output facts, including the success outcomes from the
COW copy, ELF load and exec stack builders. Opaque writes through
a tracked owner or its view discard prior coverage. A direct
forwarding wrapper inherits the requirement at its callers.

Fork and in-place COW retain existing page contents. Fork retains
the source mapping reference before sharing its physical page. The
single-reference COW path changes the existing mapping's permissions.
During a COW copy, the current root's old PTE keeps its mapping
reference. The copy initializes a new owner, and successful publication
of the replacement PTE precedes dropping the old reference. Failure
before publication leaves the old mapping in place.

The copy relies on the current process's exclusive mutation of its
root. Fork creates a distinct child root, and teardown of another
process requires its matching Reapable generation. A sibling root may
drop its own reference while the copying root retains its reference.
The physical-page adapter checks alignment and allocator membership,
then releases the allocator lock before the raw copy. The retained
mapping supplies the source lifetime throughout that copy.

The compiler follows the storage selected by the owner accessor.
The allocator's unique frame authority, the correspondence between
the frame view and the owner's physical address, the caller's
permission bits, and the Arm descriptor write and TLB protocol are
trusted here. The build's resolved caller policy confines the existing
leaf writer, update and mapping-reference operations to reviewed
functions. The architecture layer clears a replacement L3 table
before linking it. That table initialization has a separate boundary
from the user payload predicate.

## Linked space

Comparison against `8f1dbc934` using `scripts/space_delta.py` and the
normal linked kernels.

| Metric | QEMU base | QEMU change | RPi5 base | RPi5 change |
| --- | ---: | ---: | ---: | ---: |
| Text bytes | 828148 | 829804 | 4221360 | 4223176 |
| Data bytes | 4608 | 4608 | 5584 | 5584 |
| BSS bytes | 1310720 | 1310720 | 1916928 | 1916928 |
| Usable RAM start | 0x40210000 | 0x40210000 | 0x7e0000 | 0x7e0000 |

The text costs 1656 bytes on QEMU and 1816 bytes on RPi5. Data and BSS
symbol sizes, the image reservation boundary and the checked allocator
capacities are unchanged. The two production replacement paths share
an inline entry to retain their existing direct stack depth to the
descriptor writer.

The existing boot fixtures now initialize their input pages before
mapping. For example, the address-space fixture writes 514 pages
(2105344 bytes) on its complete path and retains the same allocation
and release workload. This review measures linked space. It makes no
claim about the time cost of writing those fixtures on the board.
