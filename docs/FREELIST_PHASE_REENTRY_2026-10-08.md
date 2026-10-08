# Freelist phase re-entry correction

## Failure evidence

GitHub Actions run 37771243822 tested edd90a04edbb4554848d450635f0c0b10878726d.
Build every tree succeeded; the hardware-free aggregate failed only the
ordinary QEMU pool_contention view. Its retained UART reports:

```
freelist contention stage: incomplete
freelist contention counts: primary=4096 secondary=4102 duplicates=4096 empty=0 overlap=4096
```

The secondary's local loop restarted after returning to its idle dispatcher
while the primary still kept the same phase armed. Already-published primary
rendezvous sequences admitted the repeated lower sequences. The phase-wide
completion counter now bounds admission and supplies the next sequence;
secondary exit is checked after disarm before the next phase reset.
No production allocator behavior, allocation workload or global state is added.

## Regression evidence

The 678 overlay holds the primary before disarm. Its corrected boot passes
all 70 views. Both phases report primary=4096 and secondary=4096; unlocked
has duplicates=4096, locked has duplicates=0, and neither exhausts the chain.
Restoring the exact previous secondary loop under the same hold reports:

```
freelist contention stage: incomplete
freelist contention counts: primary=4096 secondary=11877 duplicates=4096 empty=0 overlap=11819
```

The runner requires a nonzero reverted command, the incomplete signature,
and primary=4096, secondary>4096, empty=0. It refuses an unrelated failure
or a passing reverted command. The aggregate includes this lane in both
allcheck and cicheck. This is evidence for the exercised two-core protocol,
not a proof of arbitrary scheduling, physical cache coherence or liveness.

## Static source gate

`check_probe_round_restart.py` discovers 16 current `_secondary_run` entries
called by the secondary dispatcher and refuses an invocation-local
`for ...: usize in 0..<...ROUNDS` batch in their bodies. Each discovered entry
must have exactly one maintained body. It accepts the current shared-count
loops and rejects the actual previous freelist body before a kernel runs.
Controls separately check the rejection status and named diagnostic, iterator
renaming, qualifiers, comments/strings and new/missing/duplicate entries.
Ordinary local buffer loops remain permitted.

This is a lexical build-time rule, not a new Takibi type/effect rule. It does
not inspect helper-hidden repetition, local while loops, numeric round bounds
or arbitrary alternative admission paths. The mandatory two-core regression
continues to verify the actual production protocol. An indexed shared phase
participant could express Running versus Done at the API boundary, but a
signature-only linear token cannot prevent a trusted global mint from issuing
two participants for one phase. Stored authority and the atomic admission
boundary require their separate design; no parallel owner mechanism is added.

## Incremental space review

This corrects a bounded boot fixture and adds a generated test overlay; it
changes neither production storage nor allocation lifetimes/workload. Reuse
the current allocation and pool endpoint evidence at its recorded strength.
No fresh Linux/FreeBSD comparison is needed for this unchanged boundary.

As a supplementary linked-image observation, llvm-size-19 compares the
original CI artifact with the locally built ordinary QEMU kernel:

| Boundary | Original CI artifact | Corrected local build | Delta |
| --- | ---: | ---: | ---: |
| Text bytes | 719396 | 719524 | +128 |
| Data bytes | 5078 | 5078 | 0 |
| BSS bytes | 1658608 | 1658608 | 0 |

These are linked section sizes, not payload occupancy or whole-kernel RAM.
This is a cross-build QEMU observation; it is not a fresh RPi5 size comparison.
The existing RPi5/pool space reports retain their separately stated strength.
The next measurement trigger remains a new allocation/lifetime workload or
completion of the next kernel feature/authority stage.
