# Space review at a completed unit

Space is reviewed as the kernel gains capabilities, rather than minimized
before its workload exists or left until the end. A completed kernel feature,
roadmap stage, or memory-layout/allocator milestone requires measurement.
Every publication that changes production sources carries a current review.
Small corrections that leave storage and allocation behavior unchanged may
reuse evidence with a reason. These are natural-boundary reviews, not hardware
runs for every commit.

## Procedure

1. State the feature and workload. Start with the maintained bounded boot's
   pool samples and the standard linked kernel. If the new feature is not
   exercised there, add an appropriate workload rather than claiming the
   unchanged endpoint represents it. Include a live phase and teardown when
   lifetimes, fork sharing, retained capacity, or caches matter.
2. Separate payload sizes, allocator metadata, occupied and free capacity,
   reserved pages, and the fixed code/data image. Record the baseline and
   candidate under the same boundary. Timing or cache tradeoffs require real
   RPi5 evidence; QEMU can validate deterministic accounting. A linked image
   comparison does not require a hardware boot.
3. Assess the result. Adopt cheap measured improvements; propose larger
   representation, ownership, retention or compiler changes before building
   them. No arbitrary minimum and no claim of OS superiority from unequal
   functionality. An unfavorable result is valid evidence, not a failed gate.
4. Preserve the report/capture, then update `docs/SPACE_CHECKPOINT.json`.
   Record the next concrete trigger: a new resource/lifetime, a changed
   allocation workload, or completion of the next feature/stage. Do not use
   a vague promise to review someday. If the same source tree is unchanged,
   documentation-only publication needs no new measurement.

Repeat Takibi/Linux/FreeBSD only if the normalized comparison boundary changes
or the decision needs fresh observations. Internal before/after changes often
need only Takibi measurements. Reuse the existing cross-OS baseline when its
scope still answers the question. No other OS measurement is required.

## Publication gate

`scripts/land.sh` invokes `scripts/space_checkpoint.py` after rebasing and
before its clean allcheck. For production changes, the checkpoint must match
all production source blob identities in that rebased Git tree. The scope is
root Makefile, compiler/CLI sources, and kernel Takibi, C, assembly and linker
sources, excluding manually built benchmark variants. Deletions count too.
The fingerprint excludes the checkpoint itself and documentation, avoiding a
self-referential commit hash. Rebasing onto a changed source tree requires
reviewing that combination and refreshing the evidence or justified reuse.

Generate the fingerprint after the implementation commits are current:

```
python3 scripts/space_checkpoint.py --head HEAD --digest
```

The checkpoint has exactly these fields:

- `date`: measurement/review date in YYYY-MM-DD form.
- `event`: `milestone` or `incremental`.
- `decision`: `measured` or `reuse`; a milestone must use `measured`.
- `source_sha256`: the fingerprint printed above.
- `workload`: the actual workload and accounting boundary.
- `evidence`: tracked nonempty report/capture paths.
- `assessment`: result and adoption decision, including unfavorable costs.
- `next_trigger`: when the next measurement becomes necessary.

Commit the checkpoint and evidence before running land. The gate refuses a
missing, stale or malformed record, absent evidence, and milestone reuse.
It cannot prove that a human chose a representative workload or honestly
classified a milestone. Maintained guidance requires that assessment; report
validators and executable tests check their narrower numeric claims. The
mechanism ensures the decision is visible and tied to the code, not that a
measurement always improves memory use.

## Current baseline

The FD layout reduction and durable RegionPool lifetime implementation have
both payload and linked-image observations, in `REGION_POOL_GENERATIONS.md`.
The QEMU endpoint sample and the existing FD/service and equal-object allocator
comparisons retain different, explicit boundaries. Production keeps one empty
FD-block/object chunk. The safety repair is accepted despite the fixed RPi5
image reservation cost; it is not a claim of reduced whole-kernel RAM.
