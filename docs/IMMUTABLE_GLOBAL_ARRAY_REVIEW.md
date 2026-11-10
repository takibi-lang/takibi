# Immutable global arrays: incremental space review

The frontend now carries the existing readonly access of immutable global
array storage into element access, slice casts, aliases and subviews.
Writable element access and writable pointer decay are rejected. The checker
remembers the binding even before an unannotated embed_file or array copy
has learned its array type, so later global initializers follow the same
rule as function bodies. Local shadows and mutable value copies remain valid.
This introduces no storage syntax, runtime token or deep raw-pointer guarantee.

## Production boundary

The current maintained callers were rebuilt for both platforms. The four
normal outputs below are byte-identical to the published GREEN
08d88c747e1a2d886e7a7e89b2f69688862375cf archive, whose original file hashes
were checked before comparison. IMMUTABLE_GLOBAL_ARRAY_REVIEW.json binds the
candidate compiler, source fingerprint, actual outputs and native inputs.
The build ran before the second implementation commit; its saved source
contents were checked against that commit, rather than relabeling its HEAD.

| Normal artifact | Identity against GREEN08d |
|---|---|
| QEMU linked kernel ELF | identical |
| QEMU main object | identical |
| RPi5 linked kernel ELF | identical |
| RPi5 main object | identical |

This establishes unchanged normal text, data/GOT, BSS sizes, linked image
rounding, usable RAM start and emitted frames for the maintained production
callers. It is not a whole-callgraph stack bound, a physical timing/cache
result, or a measurement of unlisted debug outputs. No kernel API, pool,
allocation or lifetime workload changed. Reuse the existing kernel space
and occupancy evidence at that boundary.

## Native FDT fixture cost

The native parser test had 17 immutable embedded fixtures passed through the
existing raw-address API. Each fixture is now copied with slice_copy into a
same-size mutable local array in app_main. The immutable sources remain
readonly. The local backing storage stays in that frame through every parser
and returned-map use; general raw integer-address lifetimes remain trusted.
No production FDT API migration is involved.

The original native program was freshly compiled with the retained compiler
and recorded source/fixture hashes. Its object and ELF exactly reproduce the
preserved prior artifacts. The candidate was built by the maintained target;
its object is also identical after rebasing and the initializer correction.
Compiler binaries differ, while all non-app_main native function bodies and
readonly data sections are byte-identical. The changed object sections are
app_main text, its relocations, its symbol-size entry and unwind information.

| Native boundary (bytes) | Original | Candidate | Change |
|---|---:|---:|---:|
| Embedded fixture payload, 17 readonly symbols | 70847 | 70847 | 0 |
| Linked readonly data, including strings | 74495 | 74495 | 0 |
| app_main local stack reservation | 4888 | 75736 | 70848 |
| Saved-register storage | 48 | 48 | 0 |
| Fixed app_main frame, excluding return address | 4936 | 75784 | 70848 |
| Maximum additional outgoing arguments in emitted sequence | 384 | 384 | 0 |
| app_main machine code | 5731 | 6553 | 822 |
| Linked text, including alignment | 32176 | 33000 | 824 |
| ELF file | 117224 | 118048 | 824 |

The frame increase is the 70847-byte copied payload plus one alignment byte.
Outgoing argument space, call return addresses and callee frames are separate
boundaries; these figures do not claim the whole program's peak stack usage.
The copies add no BSS fixture storage. They are a native test cost, separate
from the unchanged kernel image and allocation workload. No timing or compiler
performance claim follows from the linked file sizes.

Adopt the inferred readonly correction and the bounded native fixture copies.
The focused suite contains 24 cases, including code-generation positives,
actual missing-guard and eager-filter negative controls, readonly aliases,
inferred global roots, mutable copies and lexical shadows. Whole maintained
allbuild passed after the initializer correction. Next measurement trigger:
changed accepted-program lowering, kernel storage/allocation/lifetimes, a new
completed kernel feature or layout stage, or changed native fixture backing
storage and lifetime.
