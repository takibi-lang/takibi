# Virtio-net used-address metadata, 2026-11-09

This component changes only the stored RX/TX used-ring address metadata to
existing AtomicWord cells. The workload is the standard production linked
QEMU and RPi5 kernels compared with published
`34ee301584868ca5bf55a9a82e58f1c37e87dfec`. The immutable baseline's source_head,
both production ELF hashes and main.o hashes were verified against its
manifest before copying. Original baseline artifacts were read only. This
review uses llvm-size, llvm-nm, objdump and a read-only ELF section reader;
no input-rewriting objcopy command was used.

| Boundary (bytes) | QEMU before | QEMU after | RPi5 before | RPi5 after |
| --- | ---: | ---: | ---: | ---: |
| llvm-size text (including readonly data) | 822792 | 822792 | 4207396 | 4207396 |
| data | 4624 | 4624 | 5600 | 5600 |
| BSS | 1318912 | 1318912 | 1933312 | 1933312 |
| used-address payload | 16 | 16 | absent | absent |
| usable_ram_start address | 0x40210000 | 0x40210000 | 0x7e0000 | 0x7e0000 |

QEMU virtio_queue_setup grows from 168 to 172 bytes: a release store needs a
separate indexed-address calculation in place of the indexed plain store.
Four bytes of existing alignment padding absorb that instruction. LLVM also
reschedules registers within this function. Its FDE range changes from
0x4001c220..0x4001c2c8 to 0x4001c220..0x4001c2cc, without growing .eh_frame.
The stopped DDB reader remains 104 bytes, replacing its metadata load with
ldar. Its readiness load, zero/Unknown branch, raw ring acquire load, index
comparison and No/Yes results are unchanged. Only these two QEMU functions'
code and the setup unwind range change; all other allocated sections match.
Every symbol address and size is unchanged except setup's four-byte size
increase. The RPi5 production ELF is byte-identical: that platform compiles
the GEM implementation, and contains no virtio_net_used_addr or
virtio_queue_setup symbol. This is two-platform build coverage, not a claim
that RPi5 exercises virtio-net.

The setup store remains after queue_ready, with the same queue index and
programmed address. The existing exact setup source premise is updated for
the typed release store, with controls rejecting a plain store, absent store,
wrong index and reordering. The array remains zero-initialized and public for
the maintained native provider. That provider's three address reads now use
atomic_word_load before the existing raw casts. Both maintained native TX
and reply executables compile and match their exact expected output. They
exercise the actual generated driver copy with deterministic RAM/clock inputs;
they do not establish DMA coherence or real interrupt delivery, and do not
execute the stopped DDB adapter.

The adapter still borrows MachineStopped. AtomicWord protects address-word
access; an acquire observing the release orders preceding CPU operations,
not device completion, whole-ring ownership or cache coherence. Readiness
and zero handling retain their existing meanings. The subsequent raw ring
read stays in the trusted mint boundary, with no new raw site or authority.
The WorldStop Read action mapping was reread and restamped only because the
QEMU adapter body hash changed; no model action or property changed.

Territory B's later one-shot used-ring setup work was inspected in commit
88f5a048. This component keeps the published setup API and changes only its
final metadata store, not that earlier preparation block. No unready mutex
code is imported. The frozen online-prefix component is independent and is
not part of this component's source or measurement.

SHA256 of original linked inputs and measured outputs:

| Target | Before | After |
| --- | --- | --- |
| QEMU | `f956394295dad1ab09dd79008972a0b07b9d3c5f675dd901e602d701c708d7c0` | `c54ceeeaa4fde9137bedcb52aef2403247bc34bc46f4c6ce296e0cd918ac31cb` |
| RPi5 | `52a1a95e2adace47b9b1e5a2005cc05a369cee84b8a78bb8bdfbdf773447f1fd` | `52a1a95e2adace47b9b1e5a2005cc05a369cee84b8a78bb8bdfbdf773447f1fd` |

A first one-time measurement assertion expected every non-text allocated byte
to match and stopped on the setup FDE range change. The corrected measurement
explicitly records .eh_frame and independently checks its decoded range.
That failed diagnostic is not a product defect or a successful receipt.
The expected stale WorldStop map check was retained before the required
review/restamp. No new runtime behavior defect was found.

Assessment: adopt existing typed atomic metadata at unchanged payload,
reservations and linked section sizes. There is one extra cold setup
instruction and an acquire metadata load on the stopped DDB path; normal
RX/TX hot paths and all caller instructions are unchanged. No cycle-latency
or physical-page saving claim is made. No pool, allocation or lifetime changes,
so existing occupancy observations remain applicable. Hardware/full integration
validation belongs to the coordinator's batch boundary. Measure again when
queue layout, setup lifetime, allocation workload or the next kernel stage
changes. Fixture classification and reservation decisions remain separate.
