# Territory B session audit, 2026-10-10

## Evidence boundary

The audited production/test endpoint is c2c9c56c40dc1572d9bf7462b51319bf221c8e2b.
The continuation starts with the shared bounds prototype at 2390c54f, then CPU
and private-default construction, readonly literals, GEM ownership/interrupt
completion, virtio-net completion and publication gates. Interleaved upstream
commits were reviewed as integration inputs, not attributed to Territory B.
The earlier explicit-stop work is recorded in its own 2026-10-09 audit.

The final clean allcheck log is
`.git/takibi-land/allcheck-c2c9c56c40dc1572d9bf7462b51319bf221c8e2b.log`.
It passed compiler tests, all native fixtures, static/slow checks, maintained
models, QEMU integration and RPi5 71-view boot plus DDB recovery. The exact
checked HEAD was pushed. QEMU race-window 633 recorded a timing-dependent
armed churn failure and an uncrossed reverted window under the existing
RPi5-gated policy; this is not evidence that both QEMU controls crossed.
Compiler-affecting milestones also ran allbuild; the reports below retain
separate physical, negative-control and space evidence. Full allcheck does
not replace the on-demand GEM hardware branch and IRQ controls.

## Defects and prevention

| Instance | Root cause and why tests missed it | Cheapest faithful regression, executed | Model/compiler strength and remaining trust |
| --- | --- | --- | --- |
| Bounds proof, escaped descriptor alias | Backend guard scan saw addresses taken inside a branch, but missed aliases retained before it; ordinary guarded reads never shortened the descriptor through such an alias | LLVM trap-site control: old backend emitted zero checks, repaired backend retains one; loop and early-return endpoint companions | Shared conservative address scan invalidates proof; load/store/address paths consume checker evidence. No unsafe workaround or protocol model needed |
| Bounds proof, shadowed loop counter/global extent | Backend name-based loop fact confused a fresh shadow with the loop binder and treated mutable global descriptors as stable | Old/candidate shadow probes plus LLVM shadow/global rejection controls | Resolved binding graph supplies element-index evidence. The smaller endpoint mechanism remains conservative and has alias controls; general arithmetic and arbitrary heap alias proof are not implemented |
| CPU authority defaults and casts | Privacy/literal checks did not cover uninitialized declarations or plain cpu_authority casts; per-CPU tests began with valid mints | Multi-file scalar/array/tuple/generic/inferred/unsafe/shadow tests, initialized LLVM positives and old-compiler CLI controls | Final binding types reject defaults, and by-value casts are rejected even in the mint file. CPU identity mint and freshness across preemption remain trusted; #638 is the existing freshness work |
| Private ownership defaults | Initializer-free FrameRef and aggregate/generic laundering bypassed private literal construction; the direct source gate only saw one spelling | Thirteen multi-file compiler controls, old/candidate CLI controls, zeroed-empty variant and same-file positives, one-word FrameRef LLVM check | Selected option A statically closes external construction including unsafe. Same-file affine defaults remain deliberately legal. Linear ownership already rejects unused/uninitialized linear authority; stronger mint-file construction is a future concrete-defect gate |
| Readonly literal slices | Byte literal and string-to-slice creation inferred writable authority; prior tests read only | Eight old/candidate CLI rejections plus literal/alias/subslice/cast/write-consumer compiler tests; writable-copy LLVM/native positives | Literal storage is readonly through checked slice APIs. Existing raw EL0 input ABI uses narrow unsafe read-source bridges; raw-pointer readonly semantics are not proved. Literal write authority was removed, not replaced by unsafe writes |
| GEM TX reuse after unconfirmed completion | Old wake cap returned normally without completion, enabling shared-buffer reuse; successful traffic and bounded wait tests did not test ownership | Actual Device-to-CPU compile rejection; four RPi5 confirmed/unconfirmed ready/reply overlays with checked physical bodies and later-send refusal | Fixed DMA Cpu/Device tokens statically deny buffer access without returned Cpu. TLC/Apalache and premature-authority/reuse mutants give bounded protocol evidence. USED/TGO stop observation, bus/cache semantics remain trusted |
| GEM delayed IRQ and wake-count policy | Descriptor queue zero used additional queue-one interrupt enable; timer/poll masked missing TCOMP. Wake count measured unrelated interrupts rather than elapsed time | RPi5 primary/wrong-bank timestamp controls, 33 checked frames per image; actual native wait oracle rejects old polling and covers over 1000 wakes and final completion | Named IoHandle removes arbitrary-offset API and undeclared fields; declaration offsets remain trusted. 14 ms is selected policy informed by 16 KiB/10 Mbps graceful stop, not normal-TX latency proof. Existing DMA model reviewed; no new WFE/SEV protocol defect established |
| Virtio-net indefinite TX wait | Inner IRQ-flag loop could not leave on timer wakes when completion was absent; QEMU normally completed descriptors | Native actual-driver standalone/reply fixtures, actual old driver watchdog, three retention-guard mutations; ordinary QEMU networking | Must-use completion outcome/private submission prevent some misuse. Elapsed expiry and queue retention are runtime guards, not static DMA ownership. No new raw access or trusted escape added; existing raw ring/storage is still trusted |
| Late publication failures and ignored clean status | Long aggregate started before independent host gates; explicit-status shell omitted clean failure handling. Ordinary green land runs could not expose it | Actual-shell mock traces for three failing gates, actual stale model stamp, clean/full failure, green/no-op; missing-gate/status mutants and old-clean mock-push control | Host build-time prevention, not compiler proof. Same exact-HEAD clean full aggregate still gates every push; mock providers prove ordering/status behavior, not remote or hardware behavior |

Two hardware-harness corrections are also included in the evidence: the GEM
fixture initially assumed local link-up implied host readiness and that a new
RX frame could arrive after MAC halt. The faithful fix starts with a real
RX/reply handshake and uses a genuinely pending owner after halt; all four
physical cases and payload/authority verifier controls passed. Ordinary boot
tests did not exercise these fixture-only assumptions. The paired baseline
launcher also lost its held board-lease descriptor through an unnecessary
nested subprocess; direct launch under the existing lease removed it. Its
first attempt stopped before loading, and the corrected paired physical run
passed. Existing lease inheritance/refusal controls cover the maintained
runner; the temporary launcher is not a new product API. Neither correction
weakens the lease, fabricates device observations or needs a compiler rule or
multicore model.

Protocol trailers marked `no` were rechecked: the bounds/construction/literal
instances are checker defects; GEM/virtio TX cases concern device completion
and DMA reuse, not a newly broken inter-core scheduler handoff. GEM's model
still covers the device ownership protocol at its stated bounded strength.

## Requirements, boundaries and similar shapes

All settled acceptance conditions of the completed issues are met. The bounds
prototype does not migrate the production allocator or give nominal integers
pool identity. That migration is the existing #252 design gate. Option A was
explicitly selected; no B annotation or prohibition inside every mint file
was promised. The GEM 15-second proposal was withdrawn, not measured as a
hardware guarantee. The virtio registry's stale 30-second explanation was
corrected against the real 1-second block policy and its restoration history.

Boundary coverage includes strict/equal bounds, missing and disjunctive
guards, reassignment, escaping aliases, shadowing, released/foreign Region
slots; direct/product/generic/variant defaults; readonly aliases and writable
copies; immediate, delayed, unrelated-wake, absent and final-deadline TX
completion; confirmed/unconfirmed halt and refusal after late IRQ. Tick
frequency, architectural counter behavior, periodic wake/dispatch and device
observations remain assumptions. Neither 14 ms nor 1 s proves hard real-time
return in the absence of any future wake.

Searches covered the maintained GEM/virtio-net/virtio-blk waits, kernel and
linux_user consumers, both literal creation paths, local/global/default/cast
construction, and LLVM load/store/address proof consumers. The native virtio
fixture generates from the real tracked driver and changes only the unused
AMD64-unsupported notification; it is not an independently maintained driver
copy. GEM's native fixture calls the shared real wait policy. Historical
examples were changed only where the language migration required callers to
compile; no historical driver parity work was added. Similar raw MMIO sites
remain on #637's route, xHCI session co-ownership on #720, cache visibility on
#625, and stored array authority on #131/#672. These are not claims of static
coverage already achieved.

Current README/SPEC agree with code. Dated GEM lifecycle/IRQ space reports
now explicitly identify their measurement stage, so the old poll description
and earlier linked sizes cannot be read as current behavior. HISTORY retains
past decisions rather than being rewritten. ROADMAP drops closed #734, #736
and #737; other listed issue states were checked through gh. The stale-comment
worklist produced two inspected false positives: #583 records a past refusal-
list removal, and #693 describes a newly created process before publication,
not unfinished issue work. Neither requires a production comment change.

## Diagnostics and disposition

Implemented aids already available in this session are the real-driver
native watchdog, per-control logs, pinned-source hardware comparison,
bounded submit/IRQ/wake/USED timestamps, checked physical-frame verifier,
packet capture, and serial publication gates with retained logs. These made
missing completion, wrong-bank enable and ignored shell status distinguishable
without scheduler prints. The existing compiler tests inspect real LLVM trap
calls rather than acceptance alone. No concrete gap justifies a generic new
debugger or another source parser. Existing #739 covers per-file mint counts;
#712/#567 cover compiler-derived attribution rather than more shadow parsing.

- Fixed and verified: all table instances, current documentation ambiguity,
  land exit-status comment and closed ROADMAP entries.
- Remaining follow-ups: #740 evaluates fixed DMA authority for virtio-net
  scratch TX and in-place RX replies. Its bad program is submit, receive
  Unconfirmed, then overwrite/repost without Cpu; existing fixed DMA types
  can reject reuse once the boundary is migrated. #741 locates the observed
  approximately one-second HTTP SYN retransmission tails, separately from
  #520 throughput. No packet-loss cause or new kernel defect is claimed.
- Deferred under YAGNI/design gates: universal liveness checking, unconditional
  B/no-default annotations, automatic reset/recovery, generic DMA allocator,
  broad debugger mutation and new soak scheduling. Existing #707 soak row
  already names naturally stalled GEM; forced observations are not a real
  stalled controller. No new soak workload or schedule is proposed.

The audit adds documentation and a shell comment only: production storage,
allocation and source fingerprint are unchanged, so existing measured space
evidence applies. Publication still runs the land skill's clean allcheck.
