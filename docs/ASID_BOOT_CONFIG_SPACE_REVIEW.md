# ASID boot configuration space and code review

This review covers the private two-word ASID initializer boundary in the
standard normal/debug QEMU and RPi5 kernels. The baseline is the actual clean
86c0cf54 post-land objects/images, copied with before/copy/after hash binding.
Normal baseline artifacts also match the earlier tracked publication-copy
review. Debug baseline artifacts have their own identities; whole-binary
identity with the earlier worktree review is not claimed.

The workload is the existing bounded boot, ASID assignment/rollover and
stopped-debugger configuration access. This report measures linked image,
actual function instructions/frames and fixed storage. It does not measure
physical instruction cycles or prove a whole-call-stack bound. Pool payload,
metadata, capacity and retained allocation behavior are unchanged; existing
occupancy evidence remains at its original boundary.

| Image | Baseline text | Candidate text | Delta | Data (unchanged) | BSS (unchanged) | usable_ram_start (unchanged) |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| qemu kernel.elf | 822728 | 822824 | 96 | 4616 | 1314816 | 0x40210000 |
| qemu kernel-debug.elf | 899300 | 899420 | 120 | 4616 | 1314816 | 0x40220000 |
| rpi5 kernel.elf | 4207460 | 4207556 | 96 | 5592 | 1929216 | 0x7e0000 |
| rpi5 kernel-debug.elf | 4292848 | 4292968 | 120 | 5592 | 1843200 | 0x7e0000 |

The linked normal growth is .text +32 B and .eh_frame +64 B on each
platform. Debug growth is .text +64 B and .eh_frame +56 B. Alignment explains
why linked section changes differ from the sum of function-size changes.
Object function-size changes total +40 B normal and +16 B debug. The old
unused eight-byte ASID_BITS_FLOOR constant disappears from object rodata;
object .eh_frame grows by 64/56 B. All changed sections are recorded in the
companion JSON. No data/BSS symbol changes size and no image reservation or
usable-RAM boundary moves.

The two actual symbols remain distinct eight-byte objects with a private
usize payload at offset zero and file-backed initial bytes 8/255. All four
normal/debug image checks validate these properties. Existing stopped GDB
read/seed scripts are unchanged. The erased writer has no runtime field,
parameter or result: the mint returns void and initialization takes only the
width operand. The ordinary mint function call still exists: it costs 16 B
of code and a 16 B frame; the setter is 52 B of code with a 16 B frame.

Both existing getters have byte-identical object instructions and 16 B
frames before and after; each performs a plain value load, with no lock,
atomic, exclusive or readiness branch. The four allocator consumers used to
read asid_last directly and now make a direct getter call. The minimum shape
adds five AArch64 instructions and a nested 16 B getter frame. Actual caller
frames are separate measurements:

| Function | Normal frame before/after | Debug frame before/after |
| --- | ---: | ---: |
| asid_init | 32 / 32 | 64 / 64 |
| asid_assign_attempt | 48 / 64 | 96 / 96 |
| asid_force_rollover_needed | 32 / 48 | 64 / 64 |
| asid_rollover_stopped | 64 / 64 | 96 / 96 |
| asid_assign_locked | 32 / 32 | 32 / 48 |

The same frame observations hold on both platforms. Extra caller spill space
and the nested getter frame must not be confused with one another or with a
whole-path maximum. Only seven ASID-related object bodies change; getter
bodies and every other function's instruction/relocation body are unchanged.
The existing frame ceiling and exceptions are unchanged.

The measured cost is accepted for the existing-type private write boundary.
No speculative boot-cell framework, new type rule, readiness stop, atomic
bypass or unrelated optimization is introduced. Library internals, unsafe
mint uniqueness, primary assembly/MMU/CPU_ON timing and stopped debugger
stores remain trusted. Runtime lanes give their own functional evidence;
this linked-image review is not a claim about physical cycles.

Next measurement: changed initializer/reader representation, another writer,
a new ASID lifetime/rollover workload, or the next completed kernel layout or
allocation feature. No Linux/FreeBSD rerun is required because this internal
comparison does not change the cross-OS comparison boundary.
