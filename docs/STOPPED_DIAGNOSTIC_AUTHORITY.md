# Stopped diagnostic authority

The DDB process-copy API requires a borrowed
`WorldStopped[&kernel_world_stop]`. A partial result, a complete token from
another controller, or a call without a token cannot enter this API. The DDB
entry passes the complete token it retains until inspection returns. The copy
returns value snapshots, not a retained ProcessRecord pointer.

`world_stop_release` declares `changes_witness_WorldStopped`. The checker
propagates this boundary through resolved direct calls and rejects a live
WorldStopped binding or a pointer/slice loan derived from that authority.
Moving the token into release does not end the pointer's lexical scope.
Scalar copies can survive release. An unrelated page-owner loan can also
survive it: resuming peers is not an assertion that that page was reclaimed.
Actual record destruction uses the separate `record_mutates_` contract.

An unexpected second complete token for an already claimed controller violates
the acknowledgement mint contract. The repeated-stop boot fixture fail-stops
without resuming either token in that impossible-success branch. Its expected
Busy path still tests sixteen attempted nested stops.

## Strength and remaining trust

These are local compile-time API and lifetime checks. They do not prove that
all remote CPUs acknowledged correctly, or that an arbitrary raw read or a
remote free obeys the protocol. The controller mint, per-request atomic
acknowledgements, interrupt entry and physical CPU holding pen remain trusted.
The generic controller API can still be requested with a caller-supplied core
count; a complete result must not be confused with a compiler proof that the
count includes every online CPU. The production DDB entry uses
`kernel_online_core_count()`.

The lock-free DDB pool probe keeps its IntrusiveSlotView through each copy,
but its unsafe probe currently relies on the stopped caller rather than a
checked derivation from the stop authority. The fatal console and diagnostic
peek also retain their existing weaker access paths. No escape is counted as
removed by this preparation, and no pin, runtime generation witness or new
lock is introduced. A full diagnostic/reclamation guarantee additionally
requires those accesses to derive from authority, complete reclamation
boundaries, a checked failure policy, and confinement of the remaining raw
mint operations.

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
| llvm-size text | 691924 | 691988 | 700940 | 701004 |
| data | 5022 | 5022 | 2888728 | 2888728 |
| BSS | 1667904 | 1667904 | 1705120 | 1705120 |
| reserved image span | 2392064 | 2392064 | 5308416 | 5308416 |

ELF SHA-256:

- QEMU baseline: 9d132da4fa96758726e781d1722501a109ee7e5ddcfe608345fa82bd59db121a
- QEMU candidate: 936c33b29e3251da166eea1cf21053c19edffd69683d34474cf299135036d4ec
- RPi5 baseline: 46b5c4e40e2549a299036500e251cc98b3b0cf047d84adb0fdbd60f16df89de2
- RPi5 candidate: 8f88213be7f930d85770b121915c304c98ab8106ad093df62c53f83d86f3011d

Assessment: adopt the local stop-domain and resume boundary. Read-only image
allocation grows by 64 bytes on each platform; mutable storage and page
reservation stay unchanged. This does not establish physical timing or
cross-core reclamation safety. No cross-OS comparison boundary changed.
Measure again when diagnostic pool access/fatal-console authority is changed,
a new lifetime/resource is introduced, or the full safe-memory stage completes.
