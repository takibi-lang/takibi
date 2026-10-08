# Checked per-CPU places and ELF value copies: space review, 2026-10-08

Workload: fresh standard production QEMU and RPi5 linked kernels, plus the
maintained QEMU bounded boot with 69 views. The boot exercises ELF loading,
process-image install/reap, syscall scratch and directory enumeration. Native
elf64_validate executes the production packed-header copy helpers and checks
that changing the source bytes does not change the returned record values.
The two complete nine-pool endpoint observations from this boot are recorded
in PER_CPU_ELF_POOL_ENDPOINT_2026-10-08.tsv. They are not peak occupancy,
an atomic global snapshot, or evidence about real cache coherence or timing.
The publication gate supplies the separate real RPi5 verdict.

The base is d4c4d431fc4fdb23508f21cacd49a5270f0d4729. The candidate adds
complete-span ELF header value copies, checked per-CPU process-image and
active-root places, checked syscall scratch places, reference-typed TCP
connection consumers, and checked directory header/name slices. Existing
non-migrating CPU-local access and lock/owner ordering remain obligations;
checked indexing by itself does not prove CPU affinity or exclusion.

Measured with scripts/space_delta.py d4c4d431, llvm-size-19 and llvm-nm-19:

| Boundary | QEMU base | QEMU candidate | RPi5 base | RPi5 candidate |
| --- | ---: | ---: | ---: | ---: |
| text bytes | 716052 | 717340 | 725996 | 727172 |
| data bytes | 5070 | 5070 | 2888776 | 2888776 |
| BSS bytes | 1655712 | 1655712 | 1692544 | 1692544 |
| usable_ram_start | 0x40248000 | 0x40248000 | 0x718000 | 0x718000 |
| image reservation bytes | 2392064 | 2392064 | 5341184 | 5341184 |

Text grows by 1288/1176 bytes. No data/BSS symbol changes size, and no
persistent field, owner slot, pool payload, allocation policy or image
reservation changes. The packed ELF copies are bounded 64-byte and 56-byte
values; they remove exported overlay aliases at a small stack/value cost.
This is not a whole-stack high-water measurement. Accept the measured code
cost for explicit bounds and independent metadata values. No speculative
representation change or safety relaxation is justified by these numbers.

The fresh pool endpoint TSV is byte-identical to the preceding record-reference
review's endpoint TSV. At both phases the process pool has one 8192-byte chunk
and zero occupied slots. FD context, FD block, object and image each retain
one 4096-byte chunk and one occupied slot. Backing, TCP, retransmit and frame
have no chunks at those endpoints. Payload/slot sizes are unchanged: process
872/880, FD context 72/72, FD block 400/400, object 80/80, image 88/88, backing
40/40, TCP 224/224, retransmit 1592/1592 and frame 1528/1528 bytes. This does
not say that the boot never used other slots between these observations.

The raw-dereference ratchet records process_image 42 to 0, syscall 59 to 0,
address_space 10 to 6, and elf64 16 to 2. The two ELF sites are packed-header
copy mints with complete input spans. The remaining six address-space sites
are deliberate CoW user-VA probe accesses. Zero recorded raw dereferences
is not full confinement: syscall still forwards raw kernel buffers to copy
APIs, and FD probe-local unsafe atomics still require a typed location API.

ELF SHA-256:

- QEMU: c3d2ec4980fbe2787908d8ac191047e9552a88308762ee92e9e00e43ff3c06d2
- RPi5: 5738d3facdad98dd9b6f74cfbcc5c473a120aff110fe5be3a8ec04bb7ac42580

Next measurement: the typed atomic/probe or bounded-copy migration milestone,
process trust-boundary separation, final raw-authority confinement, or a
changed allocation/lifetime workload. The normalized OS-comparison boundary
has not changed, so no fresh Linux or FreeBSD observation is required.
