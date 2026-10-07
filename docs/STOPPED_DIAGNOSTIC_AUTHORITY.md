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

This is not yet a lock-free guarantee for every diagnostic. VM and FD backing
inspection still pins RegionPool records, and the fatal console and normal
diagnostic peek retain weaker paths. Those accesses and raw-authority mint
confinement remain unfinished. No runtime pin or new lock was added to the
process-pool copy path.

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
