# Private reset-confirmation token space review

The workload is the maintained block timeout/reset ownership fixture and the
normal linked production kernel. A final zero status-register read, under the
existing block-device guard, mints one private linear confirmation for the
block used ring. No allocation, retained-owner lifetime, pool size, queue
layout or configured image reservation changes. The existing DMA QEMU lane
checks successful reset reuse and failed reset retention; it is deterministic
ownership evidence, not evidence for physical cache coherence or timing.

The baseline is published 7e6653707d6de83fb56dd1541e50a3eff158aeaa. Both
retained production ELFs were SHA256-checked against that baseline's manifest
before using the sizes. RESET_CONFIRMATION_SPACE.json records those hashes,
the candidate ELF and object hashes, and the candidate production-source
fingerprint. That fingerprint identifies the implemented source independently
of the later documentation/checkpoint commit; the worker audit records the
final source HEAD and actual verification exits.

| Boundary | QEMU before | QEMU after | RPi5 before | RPi5 after |
| --- | ---: | ---: | ---: | ---: |
| Text bytes | 822824 | 822792 | 4207428 | 4207396 |
| Data bytes | 4632 | 4624 | 5608 | 5600 |
| BSS bytes | 1318912 | 1318912 | 1933312 | 1933312 |
| Usable RAM start | 1075904512 | 1075904512 | 8257536 | 8257536 |

Both targets lose 32 text bytes and 8 data-section bytes. The only changed
mutable symbol is the removed one-byte virtio_used_reset_confirmed flag;
the remaining seven data bytes are section padding, not additional payload
removed. No physical page is freed. The linear token is local to the reset
operation and its device index is erased. Existing lock and owner slots do
not grow. The code boundary moves the final MMIO read to the mint entry:
virtio_blk_reset shrinks from 196 to 192 bytes, virtio_used_quiet from 52 to
20, and the former 144-byte reclaim helper becomes a 156-byte guarded block
reset entry. These symbol deltas do not sum to the section delta because
layout/alignment also contributes; the section table is the linked boundary.

Adopt this bounded safety improvement. Reset completion and fixed
block-device-to-slot association remain trusted; compiler checking covers
private construction, device-index mismatch, and single transfer into the
action. The next measurement trigger is another reset consumer, a changed
token/slot layout or allocation lifetime, or the next completed kernel stage.
