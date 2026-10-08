# RegionPool record references: space review, 2026-10-08

Workload: fresh standard production kernels, with the maintained QEMU boot,
68 views and halt/poweroff/restart PTY cases. The nine pool samples at boot
and bounded_end are retained in REGION_REFERENCE_POOL_ENDPOINT_2026-10-08.tsv.
These are two endpoint observations, not peak occupancy or a hardware timing
measurement. The final clean allcheck still supplies real RPi5 evidence.

The base is 09047c61, including the fixed-DMA receive/transmit mint work.
The candidate adds indexed RegionPool record references, guarded TCP retry
value copies, guarded PID value operations and bounded crash-trace output.
Measured with scripts/space_delta.py 09047c61, llvm-size-19 and llvm-nm-19:

| Boundary | QEMU base | QEMU candidate | RPi5 base | RPi5 candidate |
| --- | ---: | ---: | ---: | ---: |
| text bytes | 712468 | 713956 | 722524 | 723900 |
| data bytes | 5062 | 5062 | 2888768 | 2888768 |
| BSS bytes | 1655712 | 1655712 | 1692544 | 1692544 |
| usable_ram_start | 0x40248000 | 0x40248000 | 0x710000 | 0x718000 |
| image reservation bytes | 2392064 | 2392064 | 5308416 | 5341184 |

No data/BSS symbol changes size. The text growth is 1488/1376 bytes; indexed
references and scalar copies add no owner slot, process field or pool storage.
The RPi5 image crosses a 32 KiB stack-alignment boundary, costing eight 4 KiB
allocator pages. The boot expectation is updated from 259312 to 259304 pages,
and the existing linked-layout check verifies the exact value. QEMU's image
reservation is unchanged. No image ceiling or safety check is weakened.

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

- QEMU: 5d230804e165ebad4c8256c7932b1970bfe82bd36ea6b6515721092fdeac152f
- RPi5: 760c3bd99467374dcf64ea393aaf181bda6f916f6145efe9942da2f0a3e4b50c

Next measurement: guarded-record/per-CPU migration, final raw-authority
confinement, or a changed allocation/lifetime workload.
