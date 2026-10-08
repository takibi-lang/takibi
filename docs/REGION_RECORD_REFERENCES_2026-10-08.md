# RegionPool record references: space review, 2026-10-08

Workload: fresh standard production kernels, with the maintained QEMU boot,
69 views and halt/poweroff/restart PTY cases. The nine pool samples at boot
and bounded_end are retained in REGION_REFERENCE_POOL_ENDPOINT_2026-10-08.tsv.
These are two endpoint observations, not peak occupancy or a hardware timing
measurement. The final clean allcheck still supplies real RPi5 evidence.

The base is b70b1ffb, including the fixed-DMA receive/transmit mint work.
The candidate adds indexed RegionPool record references, guarded TCP retry
value copies, guarded PID and ASID value operations, bounded crash-trace output, array-field
loan tracking and FD guarded scalar access.
Measured with scripts/space_delta.py b70b1ffb, llvm-size-19 and llvm-nm-19:

| Boundary | QEMU base | QEMU candidate | RPi5 base | RPi5 candidate |
| --- | ---: | ---: | ---: | ---: |
| text bytes | 714036 | 716052 | 724092 | 725996 |
| data bytes | 5070 | 5070 | 2888776 | 2888776 |
| BSS bytes | 1655712 | 1655712 | 1692544 | 1692544 |
| usable_ram_start | 0x40248000 | 0x40248000 | 0x718000 | 0x718000 |
| image reservation bytes | 2392064 | 2392064 | 5341184 | 5341184 |

No data/BSS symbol changes size. The text growth is 2016/1904 bytes; indexed
references and scalar copies add no owner slot, process field or pool storage.
Both platforms keep the upstream image reservation: 2392064/5341184 bytes.
The upstream IRQ-count milestone already occupies RPi5's 32 KiB boundary;
this stage needs no further allocator-page change. The exact linked-layout
check remains in force. No image ceiling or safety check is weakened.

ASID copies three words under its existing lock; FD copies individual scalar
fields. Neither exports an alias. This costs small bounded stack values, not
new persistent storage. The QEMU 69-view and PTY evidence covers the record,
ASID and compiler stage before the last FD scalar migration; the final clean
allcheck tests that combined HEAD, including real RPi5.

The retained pool samples keep the existing payload and slot boundaries:
process 872/880 bytes, FD context 72/72, FD block 400/400, shared object 80/80,
image 88/88, backing 40/40, TCP connection 224/224, retransmit 1592/1592 and
frame 1528/1528. At both endpoints the process pool has one 8192-byte chunk
and no occupied slot, while FD block/context/object/image each keep one
4096-byte chunk and one occupied slot. This supports these bounded workload
observations only; it does not measure whole-kernel free-page metadata or
claim an OS comparison at unequal functionality.

Adopt the modest text growth and explicit RPi5 reservation cost for checked
record access under existing slot, pin and stop authority. The change has no
new persistent storage to trim. Existing raw accessors remain supported for
primitive instances and language compatibility; removing their code would
need a separate measured compiler/code-generation change. No speculative
optimization is made to avoid an alignment threshold.

ELF SHA-256:

- QEMU: 3cbda79ba42705b7ebf231bcb24c02b024627793732c0c3ebd1ca2f4cfca057a
- RPi5: 079ef61e6f07881bdd093d655b42c2eba8bb9bb4606a544fe2f59b6fb55ab27b

Next measurement: guarded-record/per-CPU migration, final raw-authority
confinement, or a changed allocation/lifetime workload.
