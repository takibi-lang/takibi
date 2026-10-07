# CPU participant authority

Whole-machine readers require `MachineStopped[&kernel_world_stop]`, not
`WorldStopped[stop]`. The latter expresses only the requested subset and
remains useful for stop protocol probes. DDB process copies and ordinary-RAM
checks, ASID rollover, system shutdown, and cross-CPU profiling boundaries
use the machine authority. Early bootstrap can obtain it whenever every
possible participant acknowledges; the set need not be frozen after boot.

`cpu_start_reserve` claims the production stop gate and adds its target bit
before issuing a `CpuStart` token. Both platform CPU_ON entry points consume
that token, call their private firmware issuer once, and finish the reservation
before returning the raw PSCI status to the shared bootstrap reporter. The
same token cannot be reused or retained by the caller. CPU_ON entry and its
status translation are named firmware trust sites in the platform init files.
The SMCCC intrinsics themselves are still raw authority in the language;
this API migration does not claim their confinement has been enforced.

Only PSCI INVALID_PARAMETERS removes a newly reserved member, relying on the
platform contract that it means this target does not exist. An old member is
never removed. Every other status, including a timeout or uncertain failure,
keeps that target possible. The scheduler retains its separate contiguous
online prefix; that prefix is not authority for world-stop membership.

`world_stop_machine_begin` claims the same nonblocking gate before capturing
`CpuParticipants` from the possible mask, including bootstrap CPU 0. It checks
that its initiator belongs to the set. `world_stop_begin_claimed` publishes a
fresh generation and asks every other member to acknowledge. A complete
subset token is ended inside the mint, and the captured participant authority
is stored in `MachineStopped`. There is one stored linear owner field, and no
extra mask copy. Partial and Busy results cannot enter machine readers.
The SGI API takes a mask, so sparse or pending reservations are not silently
reduced to a CPU prefix. The gate stays held until stop release or terminal
shutdown. No additional lock, allocation, or per-process field is introduced.

CPU reservation changes the participant context. The checker rejects it in
any resolved caller retaining a machine token or its authority-derived loans.
The physical resume operation invalidates subset, partial, machine,
participant and CPU-start witnesses; both complete and partial releases
inherit that summary. Machine release ends its stored participant before the
physical resume boundary. Scalar snapshots can survive this boundary; a
pointer loan must end lexical scope first.

## Verification and trust

Production-body compiler tests read the real reservation, mint, release and
both platform firmware issuer functions. They check subset rejection, scoped
read loans, rejection of CPU start during full inspection, rejection of
complete or partial release with live diagnostic loans, single-use CPU_ON,
and raw resume with a live start token. They simulate no hardware.

WorldStop.tla explores three CPUs and two non-reused request generations.
Its fixed variant holds NoUnstoppedRead; removing full membership or allowing
startup through the held gate violates it. The action table in the model
README maps the steps to the implementation and records reviewed body stamps.
These are bounded model results, not a proof of the kernel or hardware.
RequestResolves guarantees a waiting request reaches Complete or Partial
under fairness of resolution. It does not guarantee successful retries under
arbitrary interrupt masking or competing initiators.

Trusted operations remain finite and named: reservation and full-stop mints
in occupancy.tkb; platform CPU_ON issuers and truthful PSCI status; acquire/
release atomic instructions; interrupt dispatch and the holding pen; CPU
identity and exception entry. Initiator IRQ exclusion is now carried by the existing IRQ-mask guard
contract on full/partial machine-stop and CPU-start result payloads. Saved
IRQ restoration is ordered after authority release. Static types do not
prove physical quiescence or the correctness of IRQ save/restore instructions.
Raw-pointer confinement and the fatal-console / diagnostic-peek migration
remain separate parts of the safe-memory work. A crash console which falls
back after Busy or Partial still has no full-machine authority.

## Space review, 2026-10-07

Baseline: published eaf01fbe. Workload: standard production linked images,
bounded bootstrap CPU_ON attempts and DDB process-copy inspection. The
participant word is per controller, not per process; full-stop tokens carry
one mask and one owner word at this measurement boundary, with no additional
mask copy or allocation. Subsequent IRQ-scoped tokens also carry saved flags.
Existing pool endpoint evidence remains applicable to unchanged allocation,
payload, retained-page and occupancy boundaries. Linked images are measured
anew with llvm-size-19 and llvm-nm-19. Text is aggregate read-only allocation.

| Boundary (bytes) | QEMU baseline | QEMU candidate | RPi5 baseline | RPi5 candidate |
| --- | ---: | ---: | ---: | ---: |
| llvm-size text | 692116 | 693220 | 701148 | 702220 |
| data | 5022 | 5022 | 2888728 | 2888728 |
| BSS | 1667904 | 1667904 | 1705120 | 1705120 |
| reserved image span | 2392064 | 2392064 | 5308416 | 5308416 |

ELF SHA-256:

- qemu baseline: dfb5b35eaa88b389e6694557b6da1288972a6298e6c7a9037150b19b2f8b1c81
- qemu candidate: f2a8dc8592c1f45afa9a50cc2452cbce5f8ee54293570cceac2414e7ca6ed018
- rpi5 baseline: c777d458fd68368f3c7f05b5a5e624af4dd47bd20d1138ee724f9538046a9f80
- rpi5 candidate: d2f6308c91465bc02b936ee35d46ad6502e3cab8a294227f99c1dde9460a27dc

Assessment: adopt the typed startup/full-stop boundary. Read-only image
allocation grows by 1104 bytes on QEMU and 1072 on RPi5. BSS,
data and image reservations are unchanged despite the per-controller word,
which fits existing layout padding. This is no claim about physical timing
or whole-kernel memory safety. No cross-OS comparison boundary changed.
Measure again when diagnostic pointer derivation or fatal-console authority
changes, a new resource/lifetime is introduced, or the safe-memory stage ends.
