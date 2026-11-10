# Boot snapshot authority: measured boundary

The boot log snapshot probes now borrow their existing BootPhase through the
real acquisition and return the existing snapshot guard with an authority
loan. Ordinary and short TaskMutex acquire bodies still spin unchanged.
Storage preparation is shared under the existing guard. This establishes the
narrow snapshot authority boundary, not scheduler-backed Mutex waiting.

The matched baseline is published `86c0cf54`; the candidate production source
is `86ccdaa3`. Normal QEMU and RPi5 ELF/object artifacts are hash-bound in
`BOOT_SNAPSHOT_AUTHORITY_REVIEW.json`. The baseline comes from the
coordinator's clean published allcheck; the candidate's normal and debug
builds passed. No A UART/flow/DDB implementation was imported. Initialization,
TX ownership/storage, phase boundaries and the allocator workload are unchanged.

| Boundary | QEMU delta | RPi5 delta |
|---|---:|---:|
| llvm-size text aggregate | +288 B | +272 B |
| .text section | +208 B | +192 B |
| covered text symbol bytes | +184 B | +184 B |
| remaining .text section gaps/alignment | +24 B | +8 B |
| .eh_frame | +80 B | +80 B |
| data / BSS | 0 / 0 | 0 / 0 |

Every changed text symbol is listed in the JSON report. All data/BSS symbol
sizes, BSS bounds and usable_ram_start are unchanged on both targets. The
existing snapshot payload is 65544 B, its store 24 B, and BootPhase,
TaskMutex and the existing guard are each 8 B. No pool or retained allocation
is added; existing allocator occupancy evidence remains applicable. This is
a measured foundation milestone with unchanged allocator work, not a fresh
occupancy or cross-OS comparison.

The new boot leaf is 20 B of code with a 16 B frame; the boot factory is
44 B with a 16 B frame; shared preparation is 108 B with a 32 B frame on both
targets. Ordinary take falls from 124 B / 32 B frame to 40 B / 16 B, but now
calls that 32 B preparation helper. This is an additional nested helper cost,
not a stack reduction. Torn-read and bounds probe frames grow 16 B each;
prologue and the four snapshot helper frames are unchanged. The JSON report
lists every selected function. Full selected disassembly contains 54 bodies
across baseline/candidate and targets; all 54 negative SP adjustments occur
within the existing parser's first twelve instructions. These are selected
single-function observations, not whole-call-path stack bounds or a repair
of the separate general late-prologue limitation.

Four durable in-process tests parse actual phase/mutex/factory/release bodies
with explicit spin/storage stubs (0.028 s, 0.05 s wall). A separate real-kernel
API positive uses build/copy/release; phase-ended, wrong-authority and
function-value cases reject with specific diagnostics. A raw-leaf bypass is
accepted by the compiler and rejected by the compiled caller check: that
boundary is build confinement. Removing only the real factory's @boot in an
external source copy keeps the positive accepted and makes the lifetime test
fail because the invalid phase-end order is accepted. No setup failure gets
negative credit.

Retain the explained fixed code and helper cost. No extra optimization or
new allocation mechanism is selected. Standard QEMU/RPi5 lanes exercise the existing boot/log runtime.
This report records source, image and selected-frame evidence, not physical
cycles. Fast-path and contended sleeping-Mutex cycle measurements lie outside
this report's boundary. Measure again when that backend/consumer integration,
a changed authority/storage/allocator lifetime, or the next kernel feature
or layout stage changes this boundary.
