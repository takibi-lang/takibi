# Readonly literal slice correction: space review

This incremental correction changes inferred slice access, read-only source
signatures and explicit EL0 raw-ABI input bridges. It introduces no storage,
allocation, ownership lifetime or LLVM lowering change. The accounting boundary
is the standard linked QEMU and RPi5 kernel, compared with 9a9788c6. Measurements
were collected with `python3 scripts/space_delta.py 9a9788c6` on 2026-10-10.

| Bytes or address | QEMU before | QEMU after | RPi5 before | RPi5 after |
| --- | --- | --- | --- | --- |
| text | 727520 | 727520 | 740272 | 740272 |
| data | 5400 | 5400 | 2889208 | 2889208 |
| BSS | 1658432 | 1658432 | 1697344 | 1697344 |
| usable_ram_start | 0x40248000 | 0x40248000 | 0x718000 | 0x718000 |

No data or BSS symbol changed size. The image reservation boundary and allocator
page reservation do not move. An independent byte-literal-to-writable-array
copy control also produces identical old/new AArch64 objects under
`--forbid-trap`. Source access is erased; this correction adds no runtime witness.

Payloads, pool metadata and retained capacity retain the existing workload
boundary and measurements: this change performs the same reads and copies and
adds no allocation or lifetime transition. The linked-image comparison is not a
new live-occupancy observation or an OS comparison. No space optimization is
required. Measure again when a feature changes allocation, retained capacity,
resource lifetime or linked image reservation.
