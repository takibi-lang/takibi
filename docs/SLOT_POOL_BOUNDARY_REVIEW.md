# Slot-pool source boundary review

The sleep and return checks now cover foreign production kernel files,
using the existing scheduler-sleep roots, acquire aliases and conservative
held intervals. Borrowed holders remain whole-body holders. This changes
host source-check coverage only; no compiler, kernel, native workload,
allocation, storage, model or target build input changes.

The 93 actual-main controls retain the previous 47 cases and add foreign
borrowed/local/indirect/transitive sleep and return cases across the five
existing pools. Status and specific diagnostics are checked independently;
valid direct calls after recognized release, sink consumption, borrowed
scalar returns and the retained-stack TaskMutex park name stay accepted.
These are source-policy fixtures, not compiler or runtime evidence.

The existing measured space checkpoint and its accounting boundaries are
reused unchanged. The production fingerprint is unchanged; the publication
gate reports no production source change. There is no new image, stack,
allocator occupancy or physical timing claim. Measure again when a kernel
consumer, allocation workload, lifetime, layout or completed kernel feature
changes, as required by SPACE_REVIEW.md.
