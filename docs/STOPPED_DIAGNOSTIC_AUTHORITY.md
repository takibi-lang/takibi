# Stopped diagnostic authority

The DDB process-copy API requires a borrowed
`MachineStopped[&kernel_world_stop]`. A subset stop, a partial result, a token from
another controller, or a call without a token cannot enter this API. The DDB
entry passes the complete token it retains until inspection returns. The copy
returns value snapshots, not a retained ProcessRecord pointer.

`world_stop_resume`, the private physical resume operation, declares
`changes_witness_WorldStopped` and `changes_witness_WorldStopPartial`. Both
complete and partial release inherit these boundaries automatically. The
checker propagates them through resolved direct calls and rejects a live
WorldStopped binding or a pointer/slice loan derived from that authority.
Moving the token into release does not end the pointer's lexical scope.
Scalar copies can survive release. An unrelated page-owner loan can also
survive it: resuming peers is not an assertion that that page was reclaimed.
Actual record destruction uses the separate `record_mutates_` contract.

The repeated-stop boot fixture exercises the production claim gate while
borrowing its existing complete stop. This probe cannot publish another
request or mint a second authority. Sixteen failed claims must answer Busy;
UnexpectedUnclaimed records a broken claim invariant and fails the fixture.
The shared claim helper is also the first acquisition step of production
world_stop_begin. Separate fixtures still exercise complete, partial and stale
acknowledgement results through the full API.

## Strength and remaining trust

These are local compile-time API and lifetime checks. They do not prove that
all remote CPUs acknowledged correctly, or that an arbitrary raw read or a
remote free obeys the protocol. The controller mint, per-request atomic
acknowledgements, interrupt entry and physical CPU holding pen remain trusted.
The generic controller API still accepts a caller-supplied subset for probes,
but that WorldStopped token cannot enter the DDB process-copy or RAM-check
APIs. Whole-machine entry captures the possible-participant mask under the
same gate as CPU_ON. Pending and uncertain starts are included before firmware
can expose them. See CPU_PARTICIPANT_AUTHORITY.md for this boundary and its
named trusted operations.

The lock-free DDB process-pool probe now derives a private
`MachineSlotView[stop, pool]` from the borrowed machine authority. Its payload
loan retains the stop identity. Resume, CPU-start changes, and actual process
slot removal reject a live view; resume also rejects an outstanding derived
pointer after the view itself has been dropped. A private `loan_transfer`
boundary can move the checked pointer lifetime to the borrowed machine token.
DDB record copies, parent-PID reads and address-space root selection use this
path, including the bootstrap record before the pool is initialized.

Full and partial machine stops save and mask the initiator's IRQ state before
claiming the gate. CPU-start reservations do the same. Their linear result
payloads carry the existing IRQ-mask and world-stop lock guard contracts;
release ends the authority before resuming peers and restoring saved IRQs.
Busy restores immediately. Terminal keep-forever retains the physical mask.
A derived pool view also carries IRQ-mask exclusion until it is dropped.
The save/restore implementation and physical IRQ behavior remain trusted.

DDB VM, process-image and first-block FD inspection now use a generation-checked
`RegionInspection` under the borrowed machine authority. The four private
mints retain IRQ exclusion. A held pool metadata lock returns Busy before
traversal, because quiescence does not establish consistency of an interrupted
update. Stale and Busy are explicit diagnostic outcomes, not empty live
records. Resume and CPU-start context changes invalidate all four permission
types. Local take, retire, free and chunk shrink also invalidate the matching
inspection type through compiler-inferred summaries. No runtime pin or lock
is taken by these DDB backing reads; bootstrap VM backing remains static.

The source gate fixes the four unproven mint callers and checks their
borrowed stop/IRQ contracts and complete physical invalidation markers.
A native test validates real metadata behavior. The shared kernel fixture
holds each real VM/image/FD guard on the initiating CPU while a full machine stop
queries its actual diagnostic mint; each must return Busy without waiting.
Compiler tests cover distinct pools/controllers, resume, local take/retire,
post-consumption loans, and no_copy payloads. Model evidence does not establish
physical holding or fault timing. Fatal capture now copies shared fields only with complete machine authority.
The terminal console borrows that retained authority for ps/proc; a refused
stop admits cached commands and reports live commands unavailable. Rendering
uses captured translation values, never a fresh VM lookup. Ordinary scalar
diagnostics retain the pool view through copying and return no pointer. The
legacy unproven payload accessors are removed; raw-authority file confinement
remains separate work.

## Space review, 2026-10-07

Workload: standard production linked QEMU/RPi5 images and the existing bounded
DDB process-copy workload. No allocation, payload, pool metadata, retention,
or workload occupancy change is introduced. Existing endpoint evidence in
PROCESS_RECORD_AUTHORITY_ENDPOINT_2026-10-06.tsv remains applicable to those
unchanged accounting boundaries; the linked-image boundary is measured anew.

The baseline ELFs were saved before editing from the published 1ddb61f2 tree,
whose exact-HEAD allcheck log reports PASS. Measurements use llvm-size-19 and
llvm-nm-19. The text column below is llvm-size's aggregate read-only allocation,
not exclusively machine instructions. Image reservation is usable_ram_start
minus kernel_image_start, including alignment and stacks.

| Boundary (bytes) | QEMU baseline | QEMU candidate | RPi5 baseline | RPi5 candidate |
| --- | ---: | ---: | ---: | ---: |
| llvm-size text | 691924 | 692116 | 700940 | 701148 |
| data | 5022 | 5022 | 2888728 | 2888728 |
| BSS | 1667904 | 1667904 | 1705120 | 1705120 |
| reserved image span | 2392064 | 2392064 | 5308416 | 5308416 |

ELF SHA-256:

- QEMU baseline: 9d132da4fa96758726e781d1722501a109ee7e5ddcfe608345fa82bd59db121a
- QEMU candidate: dfb5b35eaa88b389e6694557b6da1288972a6298e6c7a9037150b19b2f8b1c81
- RPi5 baseline: 46b5c4e40e2549a299036500e251cc98b3b0cf047d84adb0fdbd60f16df89de2
- RPi5 candidate: 606a116d57ae2d1903fa4ba8f93cfbdccc14b294c3a68e275780a043bd8dd6ae

Assessment: adopt the local stop-domain and resume boundary. Read-only image
allocation grows by 192 bytes on QEMU and 208 on RPi5; mutable storage and
page reservation stay unchanged. This does not establish physical timing or
cross-core reclamation safety. No cross-OS comparison boundary changed.
Measure again when diagnostic pool access/fatal-console authority is changed,
a new lifetime/resource is introduced, or the full safe-memory stage completes.

## Scoped process reads and initiator IRQs, 2026-10-07

Baseline: published 35c49a52 and its recorded linked-image measurements in
CPU_PARTICIPANT_AUTHORITY.md. Candidate: fresh standard production builds
with scoped process reads and saved IRQ flags in full/partial machine stops
and CPU-start tokens. These local flags add one word per retained token,
not a per-process field or allocation. MachineStopped and CpuStart now carry
three words; MachineStopPartial carries four. Pool payload, retained pages,
and workload occupancy are unchanged; their existing endpoint evidence is
reused only for those unchanged boundaries.

| Boundary (bytes) | QEMU baseline | QEMU candidate | RPi5 baseline | RPi5 candidate |
| --- | ---: | ---: | ---: | ---: |
| llvm-size text | 693220 | 694548 | 702220 | 703644 |
| data | 5022 | 5022 | 2888728 | 2888728 |
| BSS | 1667904 | 1667888 | 1705120 | 1705120 |
| reserved image span | 2392064 | 2392064 | 5308416 | 5308416 |

Candidate ELF SHA-256:

- QEMU: e3257c0d5542cd6549595475c3490d15e9c06ffe5dd836ffd912f7e2f43d3e9e
- RPi5: bcdf63e044d5cef07b8a00220a8b63f0502b0335b1c1a6dfc1a5d09f372f02c6

Measurements use llvm-size-19 and llvm-nm-19; text is aggregate read-only
allocation and image span includes alignment and stacks. Read-only allocation
grows by 1328 bytes QEMU and 1424 bytes RPi5. QEMU BSS shrinks by 16 bytes;
this is an aggregate linked measurement, not a pool-capacity change.
Data and page reservations stay unchanged. Adopt the scoped boundary and
initiator IRQ exclusion. The bounded model still assumes indivisible owner
reads; the IRQ lifetime rejection is separate compiler evidence. Physical
masking and save/restore remain trusted. No cross-OS comparison changed.
Measure again at RegionPool inspection or fatal-console migration, a new
resource lifetime, or completion of the safe-memory stage.

## Nonblocking RegionPool inspection, 2026-10-07

Baseline is the published aa30a644 measurement above. The candidate is a
fresh standard production build with scoped RegionInspection carriers for
AddressSpaceBacking, ProcessFdContext and FdBlock. Each carrier is one local
word; no payload, pool header, retained capacity or allocation workload changes.
The shared bounded boot exercises each owner-held pool guard and requires Busy
rather than inspecting partially updated metadata. The native executable also
checks value copying, alignment, generation, membership, free and shrink.

| Boundary (bytes) | QEMU baseline | QEMU candidate | RPi5 baseline | RPi5 candidate |
| --- | ---: | ---: | ---: | ---: |
| llvm-size text | 694548 | 699572 | 703644 | 708580 |
| data | 5022 | 5022 | 2888728 | 2888728 |
| BSS | 1667888 | 1667888 | 1705120 | 1705120 |
| reserved image span | 2392064 | 2392064 | 5308416 | 5308416 |

Candidate ELF SHA-256:

- QEMU: 21d84996d3af4c6bf65a819df22b5e06c6788f00ac1769bac589d19a8a89c25e
- RPi5: 96972f7711f5b85b6c8d3ee5ae017b85f070bba8a156efbdaf5bd676fd7f145c

Read-only allocation grows 5024 bytes on QEMU and 4936 bytes on RPi5. Data and
BSS are unchanged. Reserved span is usable_ram_start minus kernel_image_start, including the
core-zero idle stack, and is unchanged on both targets. Adopt the
nonblocking mint and explicit refusals. The diagnostic runs no pool lock or
pin operation. Physical stop, stable unlocked metadata, and the native mint
remain trusted; bounded model evidence is not a proof of these conditions.
Measure again at fatal-console migration or completion of the safe-memory stage.

## Repeated stopped-root publication, 2026-10-07

A peer retires its unwind root by clearing its frame and making its sequence
odd. The next publication starts from the previous even base, publishes an odd
in-progress stamp, writes the payload, then publishes the next even stamp.
Adding nonblocking pool inspection probes exposed the earlier publisher's
assumption that its input sequence was even: alternate completed stops instead
looked unheld to DDB. The full machine stop itself was acknowledged, while the
backtrace and stack-attribution readers correctly refused the odd root.

The shared bounded boot now makes three consecutive real full-machine stops
and requires every targeted peer's root to be usable before release. The
WorldStop action mapping names publication and retirement explicitly. Its
NoUnstoppedRead property still does not model sequence parity: refusals remain
safe, and usable publication has separate executable regression evidence.

After this correction and regression, fresh standard linked images measure
700076 text / 5022 data / 1667888 BSS bytes on QEMU, and 709076 text / 2888728
data / 1705120 BSS bytes on RPi5. Reserved spans remain 2392064 and 5308416
bytes, measured to usable_ram_start, including the core-zero idle stack.
Against the published aa30a644 baseline, read-only allocation grows 5528 bytes
QEMU and 5432 bytes RPi5. No pool payload, metadata, allocation, retained pages
or endpoint occupancy changes. Adopt the corrected finite publication boundary
and repeated-stop regression; no cross-OS comparison boundary changed.

Candidate ELF SHA-256:

- QEMU: 818465f831183236d0031878c87bc4d0973b16b22d55ef068b4881971bf92fe0
- RPi5: 4d4d108ccd975303d2f6f522f7397d5ecb1e36a751912ebd6d8268cf84f4ea62

Regression evidence uses the real two-core QEMU kernel: the standard fixed
image emits the consecutive-stop success verdict; an isolated source overlay
reverting only sequence-base normalization emits `stopped root publication:
failed`. The fixed UART DDB lane reports two matched roots with no attribution
mismatches, walks the stopped peer, agrees with GDB and resumes. Publication
still requires a separate clean exact-HEAD allcheck with actual RPi5 execution.

## Terminal capture and scalar-copy review, 2026-10-08

Workload: standard production QEMU/RPi5 linked images, the existing BRK,
exec, peer-fault and concurrent-fault console workloads, the resumable DDB
UART/software BREAK workloads, and the shared four-pool Busy-refusal probe.
Baseline is published 3b02676c. The allocation workload and per-process payload
are unchanged; the existing process-authority endpoint remains evidence only
for pool metadata, occupied capacity, allocation and retained pages.

| Boundary (bytes) | QEMU baseline | QEMU candidate | RPi5 baseline | RPi5 candidate |
| --- | ---: | ---: | ---: | ---: |
| llvm-size text | 700076 | 705468 | 709076 | 715540 |
| data | 5022 | 5022 | 2888728 | 2888728 |
| BSS | 1667888 | 1668000 | 1705120 | 1705120 |
| reserved image span | 2392064 | 2392064 | 5308416 | 5341184 |

Candidate ELF SHA-256:

- QEMU: d2d5549eca5150390b9ca04f09acf47253bd52accce151e319f39266da7a5e45
- RPi5: 0cddab0aa004c5b44b996fe8e4fd51e292ecc491e02967bffb926e8e89a36055

Read-only allocation grows 5392 bytes on QEMU and 6464 bytes on RPi5. Three
new scalar fields in each per-core crash cache retain availability and two
physical translations; QEMU BSS grows 112 bytes including alignment, while
RPi5's existing section padding absorbs it. Code growth crosses RPi5's next
32 KiB image boundary, reducing its allocatable RAM by eight pages. Its
reserved span remains below the checked 0x520000 image ceiling.

Adopt the explicit refusals and stopped-only capture: no per-process field,
new pin, or diagnostic blocking lock is added. Ordinary scalar readers extend
the existing pool view through the copy. Complete-stop holding, allocator
metadata interpretation and the named physical translation mints remain
trusted. No cheaper representation change is supported by these measurements;
file confinement and its final source union are the next measurement trigger.
