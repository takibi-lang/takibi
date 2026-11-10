# Model job budget: incremental space review

The change concerns host test scheduling only. Both trace-control groups share
one existing model queue, with one internal worker each. The allcheck target
exports a default MODELCHECK_JOBS of min(nproc,16), normalizing empty values
and preserving explicit nonempty overrides through its two recursive makes.
Standalone modelcheck and cicheck-models retain their existing defaults.

No compiler, CLI or kernel source changes are part of this unit. The Makefile
changes only the allcheck target's variable and recursive invocation arguments;
compile/link recipes, compiler flags, linked inputs, fixture contents, storage,
allocation, ownership and resource lifetimes are unchanged. The peer retains
its 31-second idle, 270-second ceiling and original ARP/HTTP verdicts.

Reuse the current kernel image and occupancy evidence in
STRUCT_POINTER_CAST_REVIEW.md and STRUCT_POINTER_CAST_REVIEW.json. The previous
source-bound scheduling experiments used identical compiler, kernel objects,
ELFs and ext2 inputs across arms. The new aggregate default changes when host
work runs, not what the kernel stores or allocates. This review does not claim
new kernel measurements, lower kernel memory use, physical timing evidence,
or a static deadline guarantee.

The measured host tradeoff is separate from space: one aligned comparison of
model jobs24 versus16 reduced peer elapsed time from257.174 to229.181 seconds
and whole-run CPU from5280.675 to4668.046 seconds. Each setting has one arm;
host drift and the original failure's exact phase remain unresolved. A local
four-core comparison of the shared queue cost599.304 to625.571 seconds, with
CPU2071.943 to2096.885 seconds. No timeout or budget is increased to offset it.

Measure space again when compiler lowering, kernel storage/allocation or
lifetimes change, or at the next completed kernel feature/layout stage.
