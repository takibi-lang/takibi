# Peer-tick boot-probe rendezvous review

## Root cause and scope

An arrival or exit predicate bounded only by CNTPCT can expire while a loaded
host never schedules the other QEMU vCPU. A missing predicate then reports a
kernel/probe failure without giving its participant execution time. Previous
ordinary boots normally scheduled both participants before the short bound;
the entry-gate check protected monotonic evidence, not the clock that limited
the wait. The earlier pool-walk repair covered its round rendezvous but left
its entry and exit windows, and other probes, on the old clock.

The current tree has fifteen relevant files, not the thirteen in the original
issue inventory. The migration creates 46 shared window snapshots, including
three formerly local peer-tick windows in pool-walk and one separated signal
completion helper. Direct wall-clock while conditions fall from 48 to six.
The fifteen files and their shared window construction sites are:

| File under kernel/kernel | Window sites |
| --- | ---: |
| asid_contention_evidence.tkb | 3 |
| console_contention_evidence.tkb | 1 |
| ext2_mutation_contention_evidence.tkb | 8 |
| freelist_contention_evidence.tkb | 4 |
| init_once_contention_evidence.tkb | 2 |
| page_contention_evidence.tkb | 2 |
| pid_contention_evidence.tkb | 4 |
| pool_contention_evidence.tkb | 3 |
| pool_walk_contention_evidence.tkb | 5 |
| schedule_contention_evidence.tkb | 2 |
| signal_contention_evidence.tkb | 1 |
| tag_contention_evidence.tkb | 3 |
| tcp_connection_contention_evidence.tkb | 1 |
| occupancy_drain_evidence.tkb | 4 |
| fd_table.tkb (refcount probes only) | 3 |

## Implementation and trust

`PeerTickWindow` holds private peer/tick/budget/wall snapshots. The helper
selects CPU 1 for CPU 0 and CPU 0 for CPU 1. Existing non-migrating boot callers
use those participants; the API is not an arbitrary online-core deadline.
It does not take a raw atomic address, so A can type each caller's predicate
loads independently. No atomic cell, memory ordering or lock ownership was
changed by the clock migration.

At the common 64 Hz tick source, 16/32/64/128 ticks preserve the old nominal
250/500/1000/2000 ms budgets. A separate ten-second wall backstop retains
recovery when the peer cannot take timer interrupts. Tick progress is evidence
that an IRQ ran, not proof that the awaited operation ran. Unsigned subtraction
is modular; a window must not span a complete tick-counter cycle. Hardware,
the tick mint/increment paths, timer configuration and the backstop remain
trusted. No raw-pointer cast, unsafe block or liveness escape was added to the
helper.

The remaining direct wall-clock loops are intentional: the DDB console hold,
two ext2 reader lingers, the short IRQ-masked signal collision hold, the
stopped-peer tick-stability hold, and the scheduler's whole-phase collision
retry budget. Each definition states its purpose. The wall-bound inventory
retains the DDB and retry rows and one shared recovery backstop, rather than
pretending all timing bounds disappeared.

The missing-participant review also found that signal's failure retried every
remaining round. A single missed round now invalidates that phase, avoiding
sixteen repeated waits per phase. Init-once failure disarms/releases its private
rendezvous so a late arrival cannot be left spinning on an abandoned release.
Console, init-once, TCP-owner, signal and peer-initiated world-stop failures
now identify their missing-participant reason; existing successful output
remains unchanged.
The world-stop resume predicate compares against the stopped interval's final
tick sample, so a tick before the stop cannot satisfy post-resume progress.

## Recurrence prevention

The cheapest faithful execution tier is the maintained QEMU kernel: the
verdict depends on two real guest participants and their timer interrupts.
The delayed-entry overlay masks peer IRQs for 750 ms before every dispatched
probe entry. The corrected kernel must pass every ordinary view. Removing
the shared peer-tick condition and restoring the nominal wall-clock bound
must exit nonzero and print the selected entry failure. This approximates a
descheduled host vCPU; it is not a physical cache/timing proof.

A second overlay suppresses the sixteen dispatched probe entries but permits
real timer ticks. The first world-stop request uses the existing non-ACK
control to exercise its missing stop participant too. It runs the actual public probe consumers and requires
seventeen refusals, all named arrival/phase diagnoses, and a final completion
marker. It does not stop at the first failed view. Overlay counters require
exactly one attempted signal round in each failed phase. A second real stop
forces one tick before the SGI, then withholds observation of any tick after
resume; the stopped interval's final value must not count as resumed. Restoring
the old pre-stop baseline and signal loop must make the refusal runner exit
nonzero with both independent diagnoses. Forced schedules
are listed in the soak backlog; no soak schedule is proposed.

The source gate discovers while conditions across the evidence files and FD
refcount helpers instead of relying on entered/started local names. It refuses
new direct counter/deadline waits and loss of the shared helper's peer-tick
comparison. Controls restore real entry/helper conditions, add renamed and
qualified waits, add a second hold and remove its documented reason. Comments
and strings are masked. This catches the observed source shape; arbitrary
clock arithmetic hidden in an external helper, predicate correctness,
liveness and memory ordering are outside this gate's evidence.

Existing types already reject passing an i64 wall window where a
PeerTickWindow is required and prevent callers accessing its private origins.
They do not reject `peer_tick_window_start(read_cntfrq() as usize)`: the budget
parameter is still an ordinary usize. A separate clock-domain evaluation can
use a privately minted peer-indexed tick budget and a distinct wall-duration
wrapper to reject that program and cross-peer subtraction. Mint truth, wrap
arithmetic and tick progress still require review. Such wrappers would change
signatures/construction sites; whether their representation/annotation cost
justifies migration belongs to that evaluation, not this correction. No new
compiler capability or bounded liveness proof is claimed here.

Existing named stage/count reports make missing arrival distinguishable from
incorrect protocol data. The controls reuse them; no intrusive scheduler/IRQ
logging or new debugger is needed. The suppression control demonstrates the
new refusal diagnoses, while DDB remains the first tool for a responsive real
kernel stall.

## Incremental space review

This correction changes clock snapshots on bounded boot-probe stacks, not
resource payloads, pool metadata, allocation policy or allocation lifetimes.
The new window has four machine-word fields on AArch64 and no global storage.
The regression delay/suppression code exists only in generated overlays.
Existing tracked production pool and allocation observations therefore retain
their accounting boundary and are reused as an incremental review. This does
not claim an unchanged linked text size, unchanged optimized stack frames or
fresh physical timing evidence. Measure at the typed atomic/probe or bounded
copy milestone, final confinement, or a changed allocation/lifetime workload.

## Validation before publication

Both production targets build with `--forbid-trap`. The ordinary QEMU boot
passes all 70 views. The 750 ms delayed-entry kernel also passes 70 views;
the same kernel with the old nominal wall-clock predicate exits nonzero and
reports `console contention stage: secondary-never-ready` (three normal views
fail). The complete peer-tick regression target exits zero only after checking
that status and diagnosis and both refusal controls.

The missing-participant control completes in 11.4 host seconds locally:
seventeen public probes report their exact refusal reasons. Its second real
world stop reports `full=1 partial=1 resumed=0 inspections=1 repeated=16
busy=16 stale-refused=1`; its signal attempt counter is 2. With the old
pre-stop baseline and signal loop restored, the frozen observation is wrongly
reported as resumed (`resumed=1`) and the attempt counter is 32. The host
oracle exits nonzero with both specific diagnoses. These are observed forced
QEMU schedules, not a statistical failure-rate or physical-timing claim.

The 142-member fast gate includes the new source/overlay controls and the
ASCII scan. The exact rebased clean full hardware publication gate is a
separate final check; local targeted results are not a substitute for it.

## Atomic migration boundary

A source-scoped count after this correction still finds 31 raw atomic
intrinsic call sites inside 29 unsafe blocks in FD refcount probe functions.
The clock migration does not discharge the typed-atomic migration. The other
probe consumers also retain raw atomic calls; the console evidence already
uses AtomicWord. Recount on the rebased tree before moving them, preserve
memory orderings and rendezvous predicates, and exercise actual GDB controls
when a wrapper changes debug representation. No entire consumer file should
be declared a raw mint merely to bypass confinement.
