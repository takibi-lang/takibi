# Cross-structure initialization experiment

Experiment date: 2026-11-16. This tests representative current kernel code;
it is not a claim of complete memory safety or a hardware concurrency test.

## Method

An isolated worktree at c9a57e20 plus the ongoing uncommitted strict-uninit
changes was compiled using the real QEMU and RPi5 source lists and compiler
flags. The RPi5 embedded filesystem image was copied from the existing build;
an initial missing-image failure was environmental, not a language verdict.
Both complete target compilations and their emitted Z3 obligations passed.
These are compiler/object-generation results, not full aggregate builds or
kernel executions. Mutations were applied individually and then restored.
No additional annotations, runtime clears or unsafe initialization assertions
were introduced into production code.

## Results

| Kernel example | Mutation | Result |
| --- | --- | --- |
| procfs_put_byte | Omit output byte store | Rejected: promised prefix not initialized |
| procfs_put_byte | Return offset + 2 after one store | Rejected: extra byte not initialized |
| procfs_put_usize | Omit local digits array store | Accepted: local arrays are untracked |
| syscall_statfs | Use slot after release | Rejected: linear value consumed |
| syscall_statfs | Release slot twice | Rejected: linear value consumed |
| syscall filesystem probe | Initialize, release, reacquire, consume new slot | Accepted: old initialization fact reused |
| page_alloc_contiguous | Use pool after giving back its guard | Rejected: derived pointer outlives guard |
| diagnostic_trace_record | Omit payload field d | Rejected: field not written at commit |
| diagnostic_trace_record | Commit before writing final field | Rejected: write token already consumed |

Seven mutations are correctly rejected; two expose limits. The fresh-slot
mutation also compiles for RPi5. Z3 accepts emitted facts for both accepted
bad cases: the solver cannot recover storage identity or reads that the
compiler did not model correctly.

## Prefix buffers

`procfs_put_byte` and `procfs_put_text` already use one uninit qualifier and
two boundary clauses each: the input prefix is initialized, and the returned
prefix is initialized. The text loop needs no handwritten loop invariant or
per-call proof annotation. The existing compiler carries the interval through
its mutable cursor. This is direct compiler acceptance/rejection evidence,
not a custom model of the renderer.

This guarantee is limited to the output footprint. `procfs_put_usize` uses
an uninitialized local array for digits, which current definite-initialization
analysis does not track. Removing its digit store leaves later reads accepted.
The documented local-array limitation is therefore relevant to real kernel
code, not just a hypothetical language corner. It needs static array tracking
before claiming complete initialization safety for the renderer.

## Slot ownership, identity and reuse

Syscall scratch uses a linear SyscallSlot and atomic claim/release of a slot.
Existing ownership rules reject use after consumption and double release,
without new annotations. They do not tie initialization facts to the selected
slot or its acquisition lifetime.

A minimal example constructs two distinct slot owners (indices 0 and 1),
initializes only the first, and calls a requires-init reader on the second.
Both the current experimental compiler and the saved pre-change compiler
accept it. The new Z3 leaf checks also pass. Same-slot reads and explicit
initialization of the second slot are positive controls; omitting both fills
is rejected. The real kernel release/reacquire mutation confirms applicability.
The unconfigured-filesystem probe may return before reading bytes, so this is
a demonstrated invalid API proof, not a demonstrated executed memory leak.

The implementation collapses scratch indices to one global field path.
Exclusive ownership of each slot does not justify that collapse. A suitable
static direction is to associate facts with element/authority identity and
invalidate dependent facts at consumption or require a proved preservation
relationship. The final annotation cost is not yet measured.

## Guarded access and publication

The page allocator's existing LockedCellGuard and derived pointer lifetime
reject access after unlock. The diagnostic ring's struct-publish mechanism
rejects missing payload fields and writes after commit. Neither experiment
needed a new proof annotation. The writer already has a publish declaration,
one begin/commit pair and six payload stores; these are real runtime/API
operations, not newly added ghost annotations.

These are compiler ownership/publication guarantees. Baseline Z3 checks
arithmetic and emitted initialization coverage, but did not independently
prove the guard or publication state machine. Mint validity, lock exclusion,
release/acquire ordering, reader sequence validation and storage lifetime
remain separate obligations. No hardware behavior was tested here.

## Decision supported by this evidence

Do not start kernel-wide adoption on the assumption that initialization
facts already identify the right storage. First address scratch-slot identity
and local-array initialization, retaining these real negative controls, then
re-run the representative set. Continue the linked-contract work as a separate
structural case rather than treating it as the missing universal mechanism.

No new runtime workaround is justified yet for either discovered limit.
Existing atomic slot claims, locks and publication sequence validation remain
runtime parts of the concurrent design; static checking can constrain their
use and prove conditional guarantees, not precompute which core wins a race.
If a static repair becomes disproportionately expensive, any proposed clearing
or runtime validity check must state the exact uncovered property and cost.
