# Dynamic L3 table publication

An allocated L3 table is initialized through its live page owner. In
`address_space_pte_write`, the clear is `zero_fill(bytes[0..<PAGE_SIZE])`,
where `bytes` is the byte view borrowed from the new L3 owner. The private
`address_space_publish_l3` adapter requires
`init(page_bytes(l3)[0..<PAGE_SIZE])` and obtains the physical address from
that same owner. The normal QEMU and RPi5 build gates confine the resolved
raw install call to this adapter.

Initialization has no runtime certificate or check. The allocator's physical
address correspondence, the parent descriptor store, and hardware
walk visibility stay in the architecture trust boundary. The existing
source and emitted instruction ordering is clear, descriptor store, then
`dsb ishst`. The review covers lazy dynamic L3 allocation. Boot roots,
fixed identity tables, user payload initialization, and teardown ordering
are independent boundaries.

## Lowering and code evidence

A direct writable `u8` subslice outside an unsafe block qualifies for the
word loop on AArch64 when its emitted length is exact, agrees with the
proven minimum, is positive, and is a multiple of eight. This selects the
count from the length LLVM was given, including initialized constant
globals, independently of source spelling. The widened loop addresses ordinary non-volatile memory. Dynamic lengths,
lengths with a byte remainder and other types retain the element loop. `align 1` makes no natural
alignment promise. A target with strict alignment, including the existing
AArch64 MMU-off call closure, can split the store. The 64-bit machine
instruction below is evidence from the normal mapped kernels.

The normal QEMU and RPi5 objects both contain this loop in
`address_space_pte_write`:

```text
str xzr, [x0, x8, lsl #3]
add x8, x8, #0x1
cmp x8, #0x1ff
b.ls <loop>
```

The loop executes 512 eight-byte stores. It removes a call to
`mmu_table_entry_write` from each old clear iteration and adds one
`page_bytes` call during setup. There is one clearing pass. The published
path still calls the raw install after the loop. The outer frame stays
128 bytes and the install frame decreases from 48 to 16 bytes. Frame
sizes and instructions describe generated code; physical time and walk
visibility were not measured here.

## Space and compiler cost

Baseline `aae4cc731`, normal linked kernels with lazy user L3 allocation:

| Metric | QEMU baseline | QEMU change | RPi5 baseline | RPi5 change |
| --- | ---: | ---: | ---: | ---: |
| Text bytes | 830672 | 830680 | 4223996 | 4224020 |
| Data bytes | 4616 | 4616 | 5592 | 5592 |
| BSS bytes | 1310720 | 1310720 | 1916928 | 1916928 |
| Usable RAM start | 0x40210000 | 0x40210000 | 0x7e0000 | 0x7e0000 |

The only named linked text symbols whose sizes change are
`address_space_pte_write` (344 to 408 bytes) and `mmu_user_l3_install`
(72 to 28 bytes) on both targets. The sum of those symbol changes is 20 bytes. The reported image deltas
come from the full linked images.
Raw trust rows are unchanged versus that built baseline. The proof adds
two QEMU initialization obligations and two to its total range ledger.

Three interleaved normal main-object compiler invocations per version
and target produced these sample medians. Compiler time is process user
plus system time, and peak RSS is in KiB. The runs used separate output
paths under concurrent host work. The sample is too small to attribute
the observed RPi5-target compiler-time spread to the change alone.

| Compiler metric | QEMU baseline | QEMU change | RPi5 baseline | RPi5 change |
| --- | ---: | ---: | ---: | ---: |
| CPU seconds | 12.25 | 12.73 | 18.39 | 20.86 |
| Peak RSS (KiB) | 545872 | 545512 | 598964 | 599488 |
