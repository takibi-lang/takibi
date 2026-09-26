# Known intermittents

What a red lane is, before you diagnose it. One row per live intermittent, so
the minute between "CI is red" and "I know which question I am answering" is a
grep rather than a re-derivation.

This suppresses and retries nothing. Every lane still fails rather than warns,
and a row here changes nothing about a red run except how long it takes to
know what it is. The diagnosis lives on the issue; this file is only the map
from a symptom to its owner.

**Symptom** is a literal string the product can emit -- grep a UART log, a
`.actual`, or a lane's `run.log` for it. It must still appear in a kernel
source line, a view expectation, or a runner under `scripts/`;
`scripts/check_known_intermittents.py` refuses a row whose symptom no longer
exists anywhere, because a row that describes nothing is worse than no row.

**Rate** says what was measured over what. "Unmeasured" is an allowed and
honest answer; a borrowed rate is not.

**Issue** must still be open. `scripts/slowcheck_known_intermittent_issues.py`
refuses a row whose issue has closed, so closing an issue forces its row to be
removed or re-attributed. It asks GitHub, which is why it is in `slowcheck`
rather than `langcheck`, and why `make cicheck` needs `gh` authenticated --
an empty table asks nothing at all.

**Last seen** is what lets a quiet row be retired on evidence rather than on
hope. Nothing enforces it; it is the column a person reads when deciding
whether a row has gone quiet or has merely stopped being looked for.

| Symptom | Rate | Issue | Last seen |
| --- | --- | --- | --- |
| `the payload never asked for its input` | 1 of 9 cicheck runs after the alloc-rollback split | #607 | 2026-09-26 |
| `workload: peer read 98304 pattern bytes` | line MISSING from peer_filesystem.actual: 1 local cicheck; 0 of 30 standalone | #604 | 2026-09-26 |
| `ARP while HTTPd is listening` | 1 of 30 standalone samples | #605 | 2026-09-26 |
| `the scripted BREAK never fired` | 1 CI run of the DDB lane since e824b030 (run 36207501077); 0 of 10 locally | #603 | 2026-09-26 |

## Reading a row

`process image: target root FELL BACK TO 0 uses=` and the rest are below.

**A row was removed here on 2026-09-20, and how it ended is worth the space.**
`process table: records MISSING` was this table's first row and its first
re-attribution: from #514 to #569, once splitting the report showed every
reproduction was a RELEASED slot rather than #514's not-yet-written one.

It turned out not to be a race that needed closing. Every slot walk reaches
its slots through a cursor that probes under the pool lock, sees Live, DROPS
the proof, and returns a bare slot number; the caller looks that number up
again. A reap in the gap is a walk that raced -- and the walk already handles
it, because the absent record reads back Free and the walk skips it. The
defect was that the lookup counted it as a missing record, and a view
asserted that counter at zero. An expected race was failing the lane about
three `make cicheck` runs in eight.

The event still happens at the same rate and is now reported as one, on
`process walk: slot freed under a walk`, under a prefix no view asserts. A
counter that fires when nothing is wrong is not a detector, which is the
half worth remembering: the fix was to stop calling it a defect, not to add
a lock. Two rounds of locking were tried first and neither helped -- the
freeing side takes the POOL lock and the walk holds the RUN lock, so they
never excluded each other.

**A second row was removed on 2026-09-20.**
`process image: target root FELL BACK TO 0 uses=` reported
`process_image_root_index` answering root 0 for a target that was not a valid
slot -- and root 0 is BusyBox init's live image, so a reader taking that
answer was inspecting PID 1's address space by accident. The fallback is gone
(#516): every reader opens `ProcessImageTargetRootResult` and refuses.

Removing it found one reader that had been passing by luck. The httpd
loader's `map: pie pages=157 clean` asserted the user window was clear
through that fallback, after `process_image_unmap_pages` had already cleared
the target -- so it was asking about no target and being answered about root
0, which happened to be the root it had mapped into. It names that root now.

**#563's row was replaced on 2026-09-20 by the defect that closing it found.**
The napping-process stall is answered: `/bin/affinity` now checks the status
`wait4` already wrote, and a SIGTERM reaches a napping child -- on the same
core and, in a second arrangement, sent from core 0 to a child pinned to CPU
1. That is asserted on both platforms every run, so the stall's shape fails a
lane instead of holding one for 202 seconds.

Building that second arrangement is what found **#571**: the REAP after the
signal intermittently answered something other than the child's pid, which was
the peer-exit collection path rather than anything about signals. Its row was
removed on 2026-09-21 and the retry loop it stood on is gone.

**The table was empty for a day**, between #571 closing on 2026-09-21 and
#585 being filed on 2026-09-22, and the way it filled again is the part
worth keeping. #571 was closed by making its interleaving happen on purpose:
`kernelcheck-affinity-gdb-qemu`'s reap mode stops core 0 between wait4's two
walks of its child list and lets only the peer run, so the defect fails a
lane on every run instead of three runs in forty. A rate got it filed; only a
deterministic lane keeps it closed.

**#585 was the GATE mode of that same lane, filed and closed on 2026-09-22,
and it was never the kernel.** The check identified the probe's gate hit by
reading the rewound exception frame's saved syscall number, and skipped any
hit whose frame it could not read on the reasoning that such a hit belonged
to another process. gdb reads guest memory through the translation the
stopped CPU has active, which at the gate is the PROCESS's root -- and a
process root maps the kernel image's identity block, not every page the page
allocator hands out for a kernel stack. Whether a boot's stack run landed
inside that block was luck, so the probe's own hit came back `Cannot access
memory at address 0x406afd10` about one boot in ten and was counted as
somebody else's.

The check is register-only now: the dispatcher takes the syscall number as an
argument, so the same condition that already matched core 0's rerun
identifies the call on CPU 1 before the gate fires for it. Worth keeping
because the shape generalises -- **a gdb check that reads kernel memory is
reading it through whatever address space the guest happens to be in.**
