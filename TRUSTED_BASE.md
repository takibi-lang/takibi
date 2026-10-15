# Takibi Kernel Safety and Trusted Base

This document states what a successful Takibi kernel build establishes, what
is checked only at runtime, and what remains trusted. It is an engineering
contract, not a mechanized proof or a claim of general memory safety.

The compiler and kernel live in one repository, so actionable ambiguity is
normally a compile error rather than a warning. A successful build is intended
to be a usable result, not a result that depends on somebody reading advisory
diagnostics. This does not imply that every possible kernel fault is currently
expressible or rejected by the type system.

## Five outcomes

| Outcome | Meaning |
| --- | --- |
| Static rejection | Parsing, typing, ownership, effect, exhaustiveness, or an enabled build policy rejects the program. No executable is produced. |
| Generated runtime check | The compiler accepts the program but emits a check whose failure calls `llvm.trap`. This is development-time containment, not the finished form of kernel code. |
| Bounded model check | A TLA+ model under `kernel/models/` checks a protocol's design over a bounded state space (`make modelcheck`). A pass is evidence for the design within those bounds, not a proof. It says something about the code only through a stated tie. Every model maps each action to the functions it abstracts, and a review stamp fails the build when those functions change. `StackOwnership.tla` is also replayed against a window of real runs on every kernel lane. `kernel/models/README.md` states each model's tie and how narrow a pass is. |
| Explicit trusted boundary | An `unsafe` block, raw pointer, MMIO operation, DMA/cache operation, extern declaration, ABI bridge, or assembly file relies on a locally reviewed assumption the checker cannot establish. |
| Outside the language model | Toolchain correctness, hardware behavior, concurrency protocols with no model, resource exhaustion, and other facts described below are not proved by Takibi. |

These are levels of assurance, and the project states each guarantee at its
real level. It aims to move defect classes toward static rejection at low
annotation cost (`README.md`, "Lightweight by design"). It does not raise a
bounded model check to the level of a proof by calling it one.

## What the compiler checks

Refined integers carry a half-open interval and a concrete representation
type. The checker proves only the interval facts supported by its documented
flow and arithmetic rules. Proven array and slice indices need no runtime
bounds check. An unrefined or insufficiently narrowed index generates a check
in permissive builds and is rejected under `--forbid-trap`.

Slices carry a pointer and a minimum length. Checked indexing and subslicing
use that length evidence. Conversion to a raw pointer discards the length and
moves subsequent validity, bounds, alignment, lifetime, and aliasing arguments
into the trusted boundary.

Affine values cannot be duplicated; linear values must additionally be
consumed. Static owner indices prevent an owner for one resource instance from
being substituted for another, and indexed views/borrows preserve the
relationships described in `SPEC.md`. These checks are path-sensitive within
the supported control-flow model. They are not a general lifetime or
separation-logic proof, do not infer arbitrary heap shapes, and do not prove
that an external resource constructor actually owns the hardware resource it
claims.

Effects constrain control flow. `may_block` propagates through resolved calls;
interrupt and exception roots reject reachable blocking operations. Function
pointer effect rows constrain indirect calls. `unsafe` marks a function that
contains a local trusted operation, and whole-program unsafe reachability can
be forbidden. Extern effect declarations are trusted because their bodies are
unavailable. Effects do not prove lock correctness, interrupt latency, or
hardware progress.

Closed variants provide exhaustive matching, and `must_use variant` prevents a
fallible result from being silently discarded. These rules establish handling
of the declared cases, not correctness of the code inside each arm.

`SPEC.md` is the normative language reference for all of these mechanisms.

## Build policy flags

`--forbid-trap` rejects a compilation when the compiler would otherwise emit
one of its recorded runtime trap checks, including unproved checked indexing,
checked refined casts, and exhaustive-enum casts. The decision is made from
type-checker/code-generator evidence rather than optimizer output. Success
therefore means that no such compiler-recorded trap site remains in the
compiled Takibi source set.

It does not inspect raw-pointer accesses, handwritten assembly, extern
implementations, arbitrary LLVM behavior, or hardware exceptions. It cannot
promise that the CPU will never fault. The maintained kernel targets use this
flag, and the exact source union is recovered from their emitted depfiles by
`make trustedbasecheck`.

`--forbid-unsafe` rejects a whole program when an unsafe effect is reachable.
It is stronger than merely requiring each local `unsafe` block to be necessary
and explicitly annotated. It still cannot inspect assembly or an extern body.
The maintained kernel deliberately does not use this flag: low-level boot,
MMIO, DMA, and context-switching code still require reviewed unsafe sites.

`--confine-raw-authority` confines type-checked raw dereferences, implicit
raw-field reference mints, local unsafe assertions and calls of
`region_bytes_assume` to explicitly declared mint files (`--raw-mint-file`).
Both maintained kernels build with it; their list is `kernel/RAW_MINT_FILES`.
The list is a ratchet the compiler enforces: an entry that does not exist, or
that this compilation reads and that holds no counted site, is rejected (a
file only the other target compiles is skipped). `--emit-raw-site-counts`
writes per-file site counts, and `make raw-site-counts` prints both kernels'.
Calling a mint does not grant the caller raw access. Authority-indexed reference
returns carry the existing local loan checks into ordinary field consumers;
raw-to-reference conversion is an unsafe assertion within the mint boundary.
The compiler's generated region primitives retain their explicit trusted source.
Header overlays (`bytes as &mut TcpHdr`, SPEC.md "Non-Raw Reference
Types") replace raw wire-header pointers in the network code. The compiler
is trusted to decide that every byte pattern is a valid value of the header
(packed, no declared alignment, unrefined integer and byte-array fields
only) and that the slice's proven length covers it; the decision is
`overlay_invalid_reason` and the length check in lib/type_inf.ml. The
older raw overlay, `bytes as *T`, and every other raw reinterpreting cast
(`*u8 as *T`, a literal address `as *T`) need `unsafe` when `T` holds a
field whose type claims more than its bytes -- refined, singleton, bool,
exhaustive enum, variant, reference (#772; `raw_claim_reason` and
`check_raw_claim_needs_unsafe` in lib/type_inf.ml). Under that `unsafe`,
the author vouches for the claim. Writing raw bytes through a pointer can
still break such a claim (#794).
Region backing globals (`region let mut g: [T; N];`, SPEC.md built-in
region) are the only arrays `region_of`, `region_table_of` and
`region_table_lock` accept, and the compiler rejects every other use of such
a name in the program, so a claimed region is the only way to that storage.
What stays trusted: `region_bytes_assume`, which mints a region over any
address it is given (confined to the mint files above); the built-in region
definitions the compiler generates; and references the name-based check
cannot see -- symbol names inside inline assembly strings and linker-script
symbol references -- which the check does not inspect.
Shared-reference direct stores and writable field-address aliases are rejected,
including nested and explicitly dereferenced places. Array-to-slice aliases
do not carry that readonly permission, so readonly behavior through a derived
slice is outside the current guarantee. Authority lifetime tracking alone does
not establish readonly permission.
This opt-in policy is file confinement, not proof of allocator metadata, physical
address validity, or mint lifetime claims. Extern and assembly bodies remain
separate boundaries. The maintained kernel's enabled flags and finite mint list
must state separately whether this policy is active there.

Without these flags, a program may contain generated traps or explicit unsafe
operations. That permissive mode is useful for early bring-up, but it is not
the maintained kernel's trap policy.

## Destructive record lifetime boundaries

The compiler rejects overlapping local authority-derived loans at
`record_mutates_<Authority>` calls, including wrappers and argument temporaries.
Unknown record identities and cross-authority aliases remain conservative.
The marker and its indexed authority contract erase; they add no runtime pin
or synchronization. Existing builtin pool pins retain their independent runtime
lifetime guarantee. Record mints, destructor footprint/completeness, and the
remote-free protocol remain trusted. This does not prove field-race exclusion.

A private `loan_transfer` boundary checks the original source-loan provenance
and binds the returned pointer to the destination authority. Both borrowed
authorities must share the return lifetime index. The assertion that the
destination actually protects the source allocation/domain remains trusted:
index equality alone cannot establish a physical lifetime relationship.
Existing source aliases do not transfer. The contract adds no runtime pin or
synchronization; ordinary call overhead depends on inlining.

## Logical context lifetime boundaries

The compiler rejects `changes_witness_<View>` calls and inferred direct
wrappers while a local binding or argument temporary still contains that
indexed linear erased view kind. Owned arguments transfer the obligation;
borrows do not. A different generation or phase does not imply a different
logical context. Runtime function values cannot erase this call summary.
There is no generated runtime check or synchronization. Truthful mints,
complete context-change marking, extern/raw-call behavior and the remote
scheduling/reclamation protocol remain trusted. This is local lifetime
exclusion at declared boundaries, not inference of physical context writes.

## Explicit trusted boundaries

Every `unsafe` block is lexically scoped and must justify at least one operation
the checker identifies as unsafe; an unnecessary block is a compile error. The
block says that the author accepts the missing proof for that local operation.
It does not make neighboring operations correct and does not weaken ownership
rules globally.

- Raw pointers and casts trust address validity, bounds, alignment, provenance,
  lifetime, and aliasing as applicable. A string-literal address, a kernel
  memory cast, and an MMIO cast have different rationales and are inventoried
  separately.
- `*io T` supplies volatile access semantics. The register address, width,
  permitted access direction, ordering requirements, and device state still
  come from the platform specification and driver reasoning.
- Raw atomic intrinsics (`atomic_load_acquire`, `atomic_store_release`,
  `atomic_swap_acquire`, `atomic_fetch_add_relaxed`, and
  `atomic_compare_exchange_acquire`) make a cross-core ordering or atomicity
  claim. The inventory reports these blocks as `raw atomic operation` and
  checks that their source files agree with RULE 2's allowlist in
  `scripts/check_lock_discipline.py`. This identifies the review question; it
  does not prove the protocol correct.
- DMA/cache builtins provide target-specific cache and ordering operations.
  Buffer ownership, descriptor validity, device completion, cache topology,
  and the chosen protocol remain trusted unless represented by separate
  checked types and state transitions.
- Fixed DMA records (`struct dma_fixed`) carry buffer ownership in CPU and
  Device tokens, so the checker rejects CPU access while the device may
  use the buffer. What stays trusted is the observation that returns
  ownership: `dma_finish_owned_rx`/`_tx` compile only in the record's
  declaring file, and `scripts/check_dma_mint_files.py` fixes which functions
  there may call them and which device observation each trusts (descriptor
  ownership bits, a used-ring advance, a reset read back, GEM's halt report).
  The compiler-created owner slot starts with the one CPU token.
- Device protocols (a `protocol` whose region is `tx` or `rx`, SPEC.md
  "Device protocols") put the cache work in generated wrappers on the
  publishing and finishing edges, and give an address only as a span of a
  device-state owner, or of a writable state declared `addressed`.
  Checked: no other CPU-access state yields a span and no device state
  reaches the region; a span dies with its owner; the region's
  extent is whole cache lines; every backing global of the protocol's element
  type and count is line-aligned. Trusted: the generator's placement of the
  cache operations (Protocol_decl.source_of) and the reuse of the
  `dma_prepare_tx`/`_rx`/`dma_finish_rx` lowerings; that the declared
  direction is what the device does (a device that writes a `tx` region is
  outside the proof); for an `addressed` state, that the device does not
  read the region while the CPU holds it -- for xHCI, that the controller
  fetches TRBs only after a doorbell and that a doorbell is rung only from
  a publishing lowering, after the generated clean; the `observe` lowerings of the files in
  `kernel/DEVICE_SEMANTICS_FILES`, which assert completion and quiescence
  like a dma_fixed mint file; `unsafe dma_span_address` and the bus
  translation applied at that site; and the line ownership of a region of the
  right type and count made by `region_split*` or `region_bytes_typed`
  rather than claimed from a backing global. Also trusted: that a stored
  owner is the one the device was programmed with. An owner kept in a
  `Place(exists b: addr. ...)` slot has an existential region identity,
  because `region_of` returns an anonymous one, so a driver that stores ring
  B's owner where the controller was given ring A's address type-checks
  (a driver error, not a memory-safety one: each owner still holds exactly
  its own region). Holder-tied identities (GitHub issue #750) would let the
  slot name its region and reject that statically. The emitted TLA+ model of
  a device protocol has no cache variables.
  The maintained consumer is the xHCI producer rings
  (`kernel/platform/rpi5/usb_xhci_rings.tkb`): its trusted observations are
  a nonzero completion code from `usb_await_event` for the one outstanding
  request (the driver is synchronous) and `xhci_halt_and_reset`'s confirmed
  halt and HCRST (`xhci_rings_quiesced`). The four rings share one protocol
  and live in four slots chosen by index, so a ring owner parked in another
  ring's slot is the wrong-ring case above. The same file holds the
  scratchpad buffers and array and the ERST, published for a session and
  returned only on that confirmed reset, and the input context, returned
  when the first Command Completion Event after its publication arrives:
  trusted, that this event belongs to the command that read it, which holds
  because each caller publishes the input context immediately before issuing
  that one command. The event ring and the output device context, which the controller
  rewrites for the whole session, are rx owners read through snapshot
  observations: trusted, the event TRB's Cycle bit as the mark of a whole
  entry, and that the output context's slot and EP0 words are written when
  Address Device completes. Still outside the owners: the DCBAA (its slot
  entry is written while the controller holds the table, which needs
  sub-region authority); it is an ordinary checked array whose bus address
  is taken by a pointer cast. With that, `usb_xhci.tkb` holds no raw site
  and is off `kernel/RAW_MINT_FILES`; the one raw step left, the bus-address
  export of a device span, is `kernel/platform/rpi5/usb_xhci_bus.tkb`.
  A snapshot observation (decision E1) trusts its lowering's validity test:
  that an element whose ownership marker says "written" (for an xHCI event
  ring, a Cycle bit equal to the consumer cycle state) was completely
  written by the device before the marker, so that the one copy taken after
  invalidating its lines is a whole entry; and that the release lowering
  tells the device only about entries the consumer has copied.
  The virtio-net packet buffers (`kernel/drivers/net/virtio_net_tx_dma.tkb`)
  are the #740 pool, `txrx` owners: trusted, that a used RX entry naming a
  descriptor means the device has written that descriptor's buffer, and
  that a TX used-index advance past the driver's shadow means it has read
  the one buffer posted, both read from a snapshot of the used ring. The
  virtio used rings (`kernel/drivers/virtio_used.tkb`, block and net, on
  the modern transport) are rx owners on backing globals of their own and
  are read only through snapshots: trusted, that a confirmed reset (status
  read back zero) ends the device's writes to a used ring. A transmit the bounded wait cannot confirm parks its buffer
  in a terminal device state, so no later write to it type-checks.
  The RP1 GEM descriptor rings (`kernel/drivers/net/rp1_gem_desc.tkb`) are
  rx owners, since GEM writes back into the descriptors it owns: trusted,
  that the RX ownership bit or the TX USED bit seen in a snapshot taken
  after invalidating the descriptor's line ends GEM's access to that ring
  (one RX descriptor, one TX frame in flight), that a confirmed halt ends
  TX descriptor reads, and, for both `addressed` Ready states, that GEM
  fetches a TX descriptor only after TSTART and never writes an RX
  descriptor whose ownership bit is set. GEM's packet buffers are the #740
  pool in the same file, `txrx` owners: trusted, that the ring observation
  above ends GEM's access to the one buffer its descriptor held, and that
  a buffer's address reaches a descriptor only from its device state's
  span.
  Generated protocol files (`<protocol Name>`) are exempt from
  `--confine-raw-authority`, as the built-in region file is
  (`lib/raw_authority_policy.ml`). The reason: a `u8` element read or write
  through `region_at` is a derived `*u8` dereference, so the generated
  `P_S_read`/`P_S_write` of a `u8` protocol count as raw sites, and no
  source file can be named as their mint file. What this trusts: that the
  generator (`Protocol_decl.source_of`) emits raw reads and writes only
  through `region_at` on the owner's own retained region, with the index
  proved against the count. It is the same trust as the built-in region
  definitions. The raw-dereference ratchet still counts these sites per
  generated file (`scripts/raw_deref_budget.tsv`, `<protocol ...>` rows),
  so a generator change that adds raw sites fails the build until it is
  reviewed.
- Per-CPU storage (`struct per_cpu`, indexed only by the `cpu_authority`
  value) is checked by the compiler. Trusted: `kernel/kernel/cpu_authority.tkb`
  reports the CPU it runs on (`cpu_id()`), the kernel action stays on that CPU
  because it is not preemptible (`KERNEL_PREEMPTIBLE == 0`, asserted there),
  and `cpu_here_for_boot_probe` names other CPUs only for the boot probe that
  `scripts/check_cpu_authority_mints.py` fixes as its caller.
- Definite initialization (SPEC.md, "Definite Initialization") trusts three
  premises. A `scratch` global's element is reached only by its own CPU, so
  any index names the same place (`kernel/kernel/syscall.tkb`'s
  `syscall_scratch`, indexed by the non-preemptible current CPU). A callee
  handed `&p` through a `&mut T` parameter stores every field of `p`. Each
  `unsafe { assume_init(...) }` states that bytes were written by means the
  checker cannot see. The maintained `assume_init` sites are all in
  `kernel/kernel/syscall.tkb`: `syscall_exec_argv_here`,
  `syscall_exec_path_here` and `syscall_script_line_here` rely on
  `syscall_execve_current` zero-filling `file_buffer` before execve's staging
  begins; `syscall_path_view_here` relies on `kernel_syscall_path_name`
  zero-filling `path_buffer` before it writes it. Uninitialized local arrays
  are not tracked yet.
- A RegionPool walked with no lock (`region_pool_first_unproven` and
  `region_pool_next_unproven`, GitHub issue #745) trusts that the pool's
  chunks are never shrunk while a walker may stand in one: the cursor reads
  the chunk list and slot bounds without the pool lock. Each slot it yields
  is validated again, under the lock, by `region_probe_held` (state and
  generation) before any record is read, so the walk can miss or repeat a
  slot during concurrent allocation but cannot reach a record that is not
  Held under the generation it names.
- A process record reference outlives the pool lock it was probed under
  (GitHub issue #745): `scheduled_process_record_locked`, `_current`,
  `_owned` and `_stopped` validate the Held slot under the pool lock, then
  transfer the loan to the run guard, the running process, the owner or the
  machine stop (`loan_transfer`) and let the pool lock go. That the record
  stays allocated while the reference lives rests on one fact the checker
  does not see: a process record is reaped (`scheduled_process_slot_remove`,
  which takes its Held permission back) only under the process-run guard,
  never while its process runs, and never while the machine is stopped.
  `RecordLifetime.tla` models that ordering (`ReadsOnlyLiveRecords`).
- `extern fn` and `extern symbol` declarations trust the linked symbol's ABI,
  effects, lifetime behavior, and implementation. Checker-only borrow and
  effect contracts cannot be verified against an unavailable body.
- Boot, exception entry, context switching, user entry, and architectural
  probe assembly trust instruction semantics, register-save conventions,
  stack setup, privilege transitions, and linker placement. Generated layout
  fragments reduce duplicated constants but remain part of the compiler/build
  toolchain assumption.
- LLVM lowering, the assembler, linker scripts, firmware interfaces, and the
  target CPU are trusted to implement the representations and instructions the
  compiler requests.

- Kernel stack bytes (#637, #672) are read and written only in
  kernel/kernel/stack_poison.tkb. A process stack is reached through its
  run's own `PageRunOwner`, held in the process record from adoption to the
  reap: the range is checked against the run and the base comes from the
  owner, so a process-stack range cannot name other memory. Trusted there:
  the arithmetic from a run's base to its bytes, and the linker-bounded
  stacks (boot, secondary, overflow, IRQ), which are still integer ranges
  until a section region source exists (#777).

Private files and narrow interfaces help contain these assumptions, but
containment is not proof of their implementation.

## Important facts not currently proved

Takibi does not currently establish all of the following:

- validity or lifetime of arbitrary raw pointers;
- freedom from data races, deadlocks, priority inversion, or memory-ordering
  mistakes across CPUs, interrupts, and devices;
- absence of stack overflow, resource exhaustion, or nontermination;
- correctness of linker scripts, memory maps, ABI declarations, assembly, LLVM,
  firmware, peripherals, or silicon;
- semantic correctness of protocols, device state machines, filesystems, or
  scheduler policy;
- confidentiality properties such as clearing every byte before exposing a
  page to another protection domain;
- absence of every architectural exception. `--forbid-trap` covers only the
  compiler-recorded checks described above.

Tests and hardware integration checks provide evidence for these properties;
they do not convert them into language theorems.

## Reproducible inventory

Run:

```sh
make trustedbasecheck
python3 scripts/measure_trusted_base.py --verbose
```

The normal output is a concise inventory. The verbose form lists the exact
depfile-derived `--forbid-trap` source union, any kernel `.tkb` file outside
that union, and every unsafe block with its primary syntactic rationale.
Assembly is split into production handwritten, generated, and fixture input;
raw casts, MMIO, extern declarations, and DMA/cache operations are reported as
separate boundaries. Counts intentionally live in generated output rather than
this document so that prose cannot silently become a stale status dashboard.

Unsafe blocks are reported as both a count and the number of lines they
enclose, because those two move independently and only the second is the size
of what the compiler cannot check. Splitting one routine into named
single-access primitives raises the block count while lowering the enclosed
lines; wrapping a longer body in one block does the reverse. Read the pair.

Raw-pointer dereferences are counted apart from `unsafe` blocks, because
`unsafe` gates only the moment a pointer is minted and a `*T` that exists can
be dereferenced anywhere. The compiler lists every such site with
`--emit-raw-deref-audit <path>` (`p.field`, `*p`, `p[i]`, and a store through
each; `*io T` and `*align(N) T` are marked; references, slices and arrays are
not raw pointers and are not listed). Each kernel object and standalone
EL0 Takibi payload object's build holds the list to the per-file budget in
`scripts/raw_deref_budget.tsv` with
`python3 scripts/measure_trusted_base.py --check-raw-deref`: a file with no
row, over its row or under its row fails, so the number moves down only by an
edit made on purpose (`--lower` makes it). A zero-site source has no row:
its first raw dereference is refused until declared. A successful audit must
still name a nonempty compiled source set in its depfile. The shared EL0
compile recipe and `check_el0_raw_deref_audit.py` keep every Takibi object
linked into a PIE on this gate. The budget names a reason for each file. It
counts sites, not distinct pointers, and it does not say which are
safe; choosing which files are mint sites is the later stages of the design.

A saved exception frame is a `FrameRef` (`kernel/arch/arm64/kernel/frame_ref.tkb`),
one private `usize`, so one register at the assembly boundary. Its words are
read and written only through accessors named for what they hold, each bounded
by a refined index, and the generic word access is private to that file. Three
functions make one, and each trusts something the compiler cannot see:
`frame_ref_from_entry` believes an assembly or generated entry's x0 is the frame
it just saved, `frame_ref_from_saved` believes a process record's `saved_sp`
is the frame that process last left the CPU with, and `maybe_frame_from_entry`
is the first for the syscall dispatcher, which boot probes call with no frame.
`frame_interrupted_stack_word` (GitHub issue #497, the sampling profiler's
frame-pointer walk) reads a word above an EL1 frame, on the kernel stack the
frame interrupted, only inside [frame + EXC_CONTEXT_SIZE, top of the frame's
2^(KERNEL_STACK_SHIFT+1) run); it trusts that the frame sits on such a run's
upper half, which the generated entry's stack guard checks, and that the
whole run is mapped RAM. The profile dump (`profile_session_dump`) walks every
core's buffer from DDB with the other cores stopped; it takes each buffer's
lock, so the trust is the world stop's, as for every DDB reporter.
Private affine fields do not themselves prevent zero initialization. The
stack-proof source gate rejects direct default `FrameRef` declarations in the
kernel; it is a lexical build check, not a general compiler guarantee for
default-initialized aggregates. The explicit mints still trust the address.
A frame is also indexed by a process (`FrameRef[process]`, affine): each mint
takes a generation, which supplies the index. The saved-frame mint has one
caller, `scheduled_process_saved_frame`, which takes the process's
`ScheduledProcessOwner`, so a delivery into a parked process (wait4's status
and pid, a signal wake, a UART byte, a deadline result) writes a frame whose
index is that owner's, and a frame of another process is a static mismatch.
`el0_context_resume` consumes its frame, so a frame used after it is refused.
What the index does not say is where it comes from at an entry: the entry
mint is given the CPU's current generation, so that a frame entering on this
CPU is indexed by whichever process this CPU runs, and the scheduler, which
writes `saved_sp` from the entered frame, still relies on that being the same
process as `current_handle`. A clone child's frame is minted on the
parent's stack before the child's owner exists, so `finish_clone` takes it
under its own index. `scripts/check_stack_proof_states.py` holds the callers of each to a declared
set and lists the few seams where a frame address is still a bare `usize` (an
assembly ABI, a stack-bound comparison, the debugger). What a block's result
was is a closed variant (`BlockSwitch`, `TimerSwitch`, `ExitSwitch`,
`CloneInstall`), not an integer with sentinel values; only the assembly's own
encoding of an exit, `SyscallAction::CloneParent`, still has one, and
`kernel_syscall_clone_parent_action` is the single place that writes it.

The classifier is deliberately mechanical. A block containing several kinds
of operation receives one primary category, so the detailed list is a review
queue rather than a semantic proof. A new explicit escape surface must either
fit a documented category or make the inventory report it as unclassified.
When one block contains a raw atomic intrinsic and another recognized pattern,
the atomic rationale is its primary category. The inventory also fails if its
classified atomic source files and the RULE 2 allowlist disagree.
Language guarantee changes belong in `SPEC.md` and must also be reflected here
when they change the meaning of a trusted boundary.
