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

**Last seen** is what lets a quiet row be retired on evidence rather than on
hope. `scripts/find_stale_issue_workarounds.py` refuses a row whose issue has
closed -- it needs the network, so it is run on demand rather than in a build.

| Symptom | Rate | Issue | Last seen |
| --- | --- | --- | --- |
| `process table: records MISSING uses=` | 2 in 16 `kernelcheck-qemu-main` runs, measured 2026-09-18 (1 in 8) | #514 | 2026-09-18 |
| `process image: target root FELL BACK TO 0 uses=` | one CI fail-stop, never reproduced locally; unmeasured | #516 | 2026-09-17 |
| `syscall_deadline_wait` | one CI stall of 202s in `kernelcheck-lifecycle-gap-qemu`; unmeasured, and the fixture that produced it now ends on a bounded nap count | #563 | 2026-09-17 |

## Reading a row

`process table: records MISSING uses=` is printed by the boot fixture in
`kernel/init/test_driver.tkb` when a pooled record did not resolve to the slot
its handle named. The lane fails on the `process_lifecycle` view, and the diff
has two halves, which is worth knowing before reading it: the positive line
`resources: every pooled record resolved to the slot its handle named` is
gated on the fallback count being zero and so DISAPPEARS, while the report
line appears further down. A measured instance:

    6d5
    < resources: every pooled record resolved to the slot its handle named
    9a9
    > process table: records MISSING uses=1 first_slot=0x00000000401bb880 reason=2

**The rate in this row is measured, not inherited, and that distinction
survives the two numbers agreeing.** The 1-in-8 recorded in
`kernel/lib/occupancy.tkb`'s header and in
`kernel/kernel/schedule_contention_evidence.tkb` belongs to a DIFFERENT and
FIXED defect: a probe cleared an `armed` flag and reaped a record while the
other core was still inside the loop, which the occupancy protocol closed.
Those comments say so -- "the fix was two atomic booleans and a comment".
Citing that number for a live symptom would have been reading a fixed
defect's rate as a live one -- a mistake that 16 runs on 2026-09-18 then
happened to vindicate, producing 2 failures. A borrowed number that lands on
the right answer is still not evidence, which is why the column says what was
measured over what. Both failures were `reason=2` on the `process_lifecycle`
view, one `uses=1` and one `uses=2`.

`process image: target root FELL BACK TO 0 uses=` is the same fixture
reporting that `process_image_root_index` answered root 0 for a target that
was not a valid slot. Root 0 is BusyBox init's live image, so a reader that
consumes it is inspecting PID 1's address space by accident.

`syscall_deadline_wait` is not a log line: it is the frame that appears on the
RUNNING process when the preserved DDB backtrace is resolved against the
archived debug ELF. The shape is a process that is Running with a Deadline
wait (`state=2 wait=4` on its `ps` line) while its parent is Blocked on
ChildExit. Since 2026-09-18 the `ps` line also carries `pending=` and
`masked=`, which is what decides whether the SIGTERM its parent sent was never
delivered or was delivered and blocked.
