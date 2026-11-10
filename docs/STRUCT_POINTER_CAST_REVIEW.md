# Struct-value pointer rejection: incremental space review

This corrects a frontend omission for an already-invalid cast. A nominal
ordinary struct value is neither its storage address nor an integer loaded
from it. Type inference now rejects that value as a raw/aligned-pointer
source before LLVM, including inside unsafe. Explicit atomic load followed
by the existing unsafe integer-address cast remains valid, as do actual
addresses, pointers/references, array bases, slice overlays and the existing
enum conversions. There is no implicit cell unwrapping or general cast change.

The kernel sources, LLVM lowering, storage representation, allocation and
lifetime workload are unchanged. Reuse the published GREEN
`3e019a8ee35788169cab3f873927ab6a66b85989` space/occupancy evidence for that
unchanged boundary. Actual maintained allbuild was run against the new
published caller tree before the compiler commit; the earlier d0ec allbuild
is retained only as earlier-base evidence.

Archived artifacts were copied and size/SHA-verified before inspection.
`STRUCT_POINTER_CAST_REVIEW.json` binds the candidate source and actual
normal/debug outputs that this allbuild produced:

| Artifact | Whole-file identity against GREEN3e | Loaded/code section changes |
|---|---|---|
| QEMU normal ELF | identical | none |
| QEMU normal main object | identical | none |
| RPi5 normal ELF | identical | none |
| RPi5 normal main object | identical | none |
| RPi5 debug main object | differs | none |

The debug object's differences are `.debug_line`, `.debug_str` and the
relocations for `.debug_line`/`.debug_info`; none has SHF_ALLOC. Its file grows
928 bytes, not kernel code or storage growth. Do not infer code growth from
nonloaded debug metadata. The QEMU debug object and both debug ELFs were not
built by this invocation and receive no measurement credit. An initial
readback wrongly assumed the QEMU debug ELF existed; that failed attempt is
retained separately and superseded by explicit artifact inventory.

Normal ELF byte identity establishes unchanged text, data/GOT, BSS, image
rounding, usable RAM start and emitted frames for this correction. It does
not establish a whole-callgraph stack bound or physical timing/coherence.
The host compiler binary changes; its file size is not a kernel-image or
compiler-performance measurement. Existing compile-budget gates remain the
only claimed resource controls. No new runtime pool/counter/token, occupancy
probe, guest or hardware measurement is warranted by this type-only repair.

Adopt the frontend rejection and reuse the existing kernel space evidence.
Next trigger: a changed accepted-program lowering, kernel storage/allocation
or lifetime workload, or the next completed kernel feature or layout stage.
