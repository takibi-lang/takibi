# Scoped memory-safety contract inventory

This is a property and premise inventory, not a soundness theorem or a
Rust-equivalence claim. Source baseline: 7749c2a0 (2026-11-17), containing the
7a3c452c initialization integration. SPEC.md is normative. Historical pilot
results in MEMORY_LINK_PILOT.md and MEMORY_CROSS_STRUCTURE_PILOT.md describe
experiments at their stated revisions, not today's acceptance verdicts.

## Claim boundary

There are two distinct questions: what every accepted program in a safe
language subset guarantees, and what the maintained kernel guarantees under
its enforced build policy and audited interfaces. A green kernel build does
not answer the first. The present inventory establishes neither blanket
claim; unresolved rows below are obligations, not exemptions.

The initial analysis envelope is typed Takibi with checked indexing,
initialization contracts, supported direct-call provenance, affine/linear
owners and checked guards. It excludes executing a raw dereference or an
unsafe assertion as a *safe operation*. Calling an abstraction implemented
with unsafe still depends on that abstraction's stated preconditions and
implementation. An absence of an unsafe effect in a caller alone does not
prove that its inputs, allocator or external environment are valid.

Configurations examined here are the maintained AArch64 QEMU and RPi5 main
source sets and AMD64 compiler controls, using the default trap rejection.
The kernel additionally enforces raw-authority confinement, execution-model
and source/build policies from the root Makefile. This document introduces
no new accepted programs, exclusion flag, trust allowance or runtime fallback.
The final supported subset and any narrowing of the target claim require a
maintainer decision after the inventory has been exercised.

An object is inline local/global storage or an allocation supplied by an
allocator contract. A range is a half-open byte interval within that object.
An index or numeric address does not by itself establish allocation identity,
permission, lifetime or freshness. Alignment and valid typed representation
are independent of initialized-byte coverage. Typed record reads require
fields; byte disclosure also requires padding. An initialized pointer value
does not establish initialized or valid pointee storage.

Aliases name the same object or overlapping ranges; distinct parameter names,
selector spellings or lifetime indices alone do not establish separation.
A permission is the access an owner/guard/view contract grants, conditional
on a valid mint. Storage reuse begins a new ownership interval: retained
numeric addresses are not automatically permissions for the new interval.
Other cores and devices can access storage only under the relevant protocol
premises; an arithmetic proof cannot establish their ordering or completion.
Leaks, fairness, deadlock and functional correctness are separate properties,
except where safe reclamation explicitly needs progress or quiescence.

## Finite initial obligation matrix

Each bad shape is an obligation to reject or to place behind an explicit,
reviewed trust boundary. A mechanism column is not a claim of complete
coverage. Existing source tests are in test/test_takibi.ml unless named.

| Property and bad shape | Current enforcement / positive control | Remaining premise or missing evidence | Owner |
| --- | --- | --- | --- |
| Bounds: read element N from an N-element object | Refined intervals, checked indexing and default trap rejection; narrowed in-range indexing generates code | Layout, lowering and external slice length/address truth; solver checks extracted arithmetic only | #637, #954, #986 |
| Initialization: read an unwritten scalar/array element | Init_flow leaves and intervals; `local array: an unwritten element rejects` versus complete counted fill | Raw writes/assume_init and external outputs are audited; export coverage below is incomplete | #203, #954 |
| Padding: publish init after only field stores, then view bytes | Whole init checks padding; init_fields permits typed fields only; `whole init rejects unwritten padding` versus zero-filled producer | Extraction/transfer rules and layout remain compiler trust; mutable aggregate calls discard old padding | #203, #986 |
| Selected storage: fill slot A, consume slot B; release and reacquire | Selector/authority-sensitive facts; `slot facts: different live owners stay distinct`, same-owner and explicit refill controls | Token mint uniqueness/exclusivity; no inference that two selectors are distinct allocations | #203, #637 |
| Representation/alignment: reinterpret arbitrary bytes as a reference or constrained value | Cast/type restrictions, zero_fill representation gate, checked typed API boundaries | Arbitrary raw/integer conversions, backend placement and FFI representation need audit; no universal provenance claim | #637, #986 |
| Aliasing/frame: modify a certified link through another parameter or global | Body-derived footprints and inferred separation; direct callers discharge separation; init-link concrete-heap oracle | Unknown aliases invalidate supported facts; general stored aliases, indirect calls and integer round trips need consumer controls | #637, #954, #132 |
| Lifetime: free/move authority while a derived view remains usable | Owner/guard-derived views, held spans and body-checked borrows summaries; real exec-metadata result/copy/match/release/reuse controls | Legacy @ contracts retain their separately reviewed boundary; general heap provenance, reclamation and physical owner/storage correspondence remain premises | #637, #132, #1159 |
| Reuse/freshness: old view reaches a removed/reinserted slot | Linear consumption and generation-indexed API rules | Allocator freshness, failed/partial construction, teardown and shared backing require real-consumer coverage | #637, #638, #132 |
| Concurrency: use wrong guard or expose guarded payload through bytes | guarded_by identity, no_copy and typed bulk gates; matching-guard access | Physical mutual exclusion, guard mints, interrupt/preemption transitions, publication/reclamation and raw paths remain distinct obligations | #638, #1159, #986 |
| Devices: CPU reads before DMA completion or reuses an in-flight buffer | Typed device/protocol owners and cache/DMA APIs; bounded models and selected instruction ties | Physical coherence, actual completion, hardware ordering and storage lifetime; QEMU is not hardware evidence | #637, #986 |
| Independent checking: feed a wrong place/transfer fact to Z3 | Arithmetic/finite coverage re-check plus planted-fault controls; concrete heap oracle for Init_link | Z3 does not reconstruct execution or validate arbitrary extractor/transfer rules; LLVM/assembly correctness is trusted | #986, #954, #955 |

Bounded protocol checks are evidence only at their stated bounds and code
ties (kernel/models/README.md). The matrix does not promote a modeled
protocol to global race freedom. The [scoped Rust 1.91.0
comparison](RUST_MEMORY_SAFETY_COMPARISON.md) records property-level
evidence and unresolved boundaries. Whole-language equivalence remains
unresolved.

## Original initialization acceptance re-audit

On the source baseline above, `make build` succeeded and the unchanged
`init-contracts` group passed all 111 cases. The exact first Takibi code
blocks from the #1511 and #1512 issue bodies were compiled as independent
AMD64 files, with `--external-entry main` (and `--external-entry leak` for
the padding example). No generated control was executed.

| Control | Compiler exit / object | Specific verdict |
| --- | --- | --- |
| Original #1511 padded record producer | 1 / absent | ensures needs p initialized, including padding |
| Same producer with zero_fill(p) before field writes | 0 / present | Byte-view consumer generates code |
| Original #1512 two live distinct slots | 1 / absent | peek requires storage[v1.index].buf initialized |
| Same source with peek(a) | 0 / present | Same-slot helper chain generates code |
| Same source with fill(b) before peek(b) | 0 / present | Disjoint-slot use generates code after initialization |
| Real syscall probe: release initialized slot, acquire fresh, format fresh | 1 / absent, both targets | syscall_exec_format requires syscall_scratch[v2.index].file_buffer initialized |
| Same real mutation, zero-fill fresh.file_buffer before formatting | 0 / present, both targets | Complete source sets generate objects and solver obligations |

The real mutation changes only kernel_syscall_filesystem_unconfigured_probe:
keep the original fill, release slot, acquire fresh, call
syscall_exec_format(fresh, 0), then release fresh. It was compiled in an
isolated source snapshot using the exact main-object command lines expanded
by `make -n -W kernel/kernel/syscall.tkb kernel/build/qemu/main.o
kernel/build/rpi5/main.o`; only output/facts paths and compiler location
changed. Both negative commands independently returned nonzero and the
initialization diagnostic. Both positive emitted obligation sets passed
scripts/buildcheck_range_obligations.py: cold initialization solver time
3.39 s QEMU and 3.99 s RPi5, within the unchanged 5.0 s ceiling. These are
compilation and arithmetic/coverage results, not kernel execution evidence.

Maintained controls additionally cover conditional output success/failure,
record-array prefixes, typed copies/stores, mutable-call padding loss,
whole-byte restoration and readonly preservation. The existing planted
padding fault in scripts/buildcheck_range_obligations.py requires a SAT
counterexample under the internal fault flag. Slot controls test extraction
by comparing distinct selectors, consumption, selector mutation and branches;
the solver alone cannot detect a collapsed selector supplied as a premise.

The historical procfs_put_usize omitted-digit-store mutation was also
re-run on both complete target source sets. Both now reject at digits[at]
with the uninitialized-read diagnostic. The historical accepted result in
MEMORY_CROSS_STRUCTURE_PILOT.md therefore does not describe current behavior.
The current local-array regression group covers omitted and sparse stores
and a complete counted fill; SPEC.md now includes uninitialized local
arrays in its tracked-place inventory.

No new production annotation, runtime store, unsafe site or storage was
needed for this re-audit. Slot mint uniqueness and raw-memory assumptions
remain named trust, rather than being discharged by these controls.

## Solver checkpoint on the direct TCP send revision

A clean allcheck passed on 8f6832d8e (2026-11-20), including the maintained
QEMU and RPi5 kernels. Their main-object obligation sets contain 2,230 and
2,533 SMT inputs, respectively. The pinned Z3 gate passed on both. Cold
initialization checking took 3.43 s on QEMU and 4.04 s on RPi5 against the
5.0 s budget per target. The maintained fault controls obtained counterexamples
for deliberately incorrect range, indexing, initialization coverage, path
facts and padding obligations. The selector and reuse tests above and the
Init_link concrete-heap oracle check separate premises that a solver cannot
recover from the emitted arithmetic alone.

This checkpoint covers extracted arithmetic and finite byte-coverage
obligations under the documented compiler and external premises. The direct
send path uses the TX frame. Establishing that a TCP read uses the extent
written by the current receive after RX slot reacquisition remains open.

## User-visible byte paths: initial coverage inventory

The initial source audit found nine direct copy-out call sites in
kernel/kernel/syscall.tkb, plus the forwarding call inside
kernel/mm/user_memory.tkb. There is no maintained copy_to_user_raw symbol.
This is a source-backed entry inventory, not complete export certification.

| Boundary / consumers | Current check | Remaining audit |
| --- | --- | --- |
| copy_to_user | borrow init []const u8; length check, COW resolution, UserAccessWindow | Source construction/provenance and actual source lifetime; destination mapping/assembly are trusted |
| copy_to_user_span | borrow uninit source with requires init(source[offset..<offset + length]); checked tail forwards to copy_to_user | Every producer's range fact and alias/lease identity |
| Pipe reads (two wrap segments) | Projected lock identity, bounded cursor stores, and copy_to_user_span from pipe_of(owner).buffer | Written ring ranges across wrap/reuse and exact consumption of the successful prefix from the same locked cursor across VM and COW |
| TCP reads (buffered and freshly received) | copy_to_user_span from tcp_frame_bytes | Frame ownership, received extent, publication and DMA completion |
| procfs file reads | `procfs_render_file` initializes `[0, total)`. With `offset < total`, the read copies `min(total - offset, requested)` bytes from the selected scratch slot and then updates the offset | Renderer input provenance, destination faults and file-offset semantics |
| ext2 file reads | `Ext2ReadResult::Read(n)` establishes the scratch prefix `[0, n)`. Each iteration copies that prefix before updating the file offset and delivered count | Block/device completion and actual byte fulfillment, destination faults and partial-result semantics |
| syslog snapshot reads | `kernel_log_snapshot_copy` initializes the prefix it returns. The syscall holds one snapshot guard and copies a chunk from the selected scratch slot only after checking `staged == chunk` | Snapshot construction and guard implementation, destination faults and partial-result semantics |
| prlimit64 | Two checked 8-byte stores initialize the full 16-byte output in the borrowed scratch slot before `copy_to_user`. The initial successful RLIMIT_NOFILE read checks both words and adjacent sentinels | Physical slot exclusion, destination faults and output cases beyond the initial successful read |
| uname | The syscall clears its borrowed scratch buffer, writes six fixed-width fields and passes the first 390 bytes to `copy_to_user`. The successful peer TTY fixture checks all six field tails and adjacent sentinels | Physical slot exclusion, other field values and faulting destinations |
| user_write_byte/u16/u32/u64 and user_zero_fill | Typed scalar inputs or constant zero; range/COW checks and access windows | All callers and all padding/holes of user ABI records; untouched user bytes are not kernel disclosure |
| Fresh user pages, including exec/stack and COW copies | [User page publication](PAGE_PUBLICATION.md) checks full initialization of the incoming `PageOwner` at `address_space_map_page` | Allocator and frame identity, COW source lifetime, descriptor visibility and TLB ordering |
| Retained fork/COW mappings, signal frames, shared backing | Existing-page reference or ABI paths | Reference and teardown lifetimes, and record-specific initialization |
| Raw/assembly/device output paths | Named mint files and external contracts | Audit bypasses of the typed entry set; confinement is not initialization proof |

For the five scratch-backed paths in this table,
`owned_by(SyscallSlot.index, 1)` ties the staging buffer and copy source to
the same live slot borrow. The procfs, ext2 and syslog paths use
`copy_to_user_span`. The prlimit64 and uname paths establish initialization
within the invocation and use `copy_to_user` before releasing the slot.
The maintained compiler controls exercise a live slot's local view and
reject a different selector or borrowed slot, a wrong token type, a
contract on a consuming parameter, and a read without initialization in
the call.
[Syscall scratch evidence](SYSCALL_SCRATCH_SPACE.md) records the paired
builds. Physical slot exclusion depends on the acquire compare-exchange
and release store. Destination mapping, COW and the PAN access window
retain the premises of the common copy-out boundary.

The signal-frame writer clears the checked 4688-byte destination before
storing the populated fields. Ordinary and alternate-stack delivery use
the same writer. In the ordinary signal-boundary fixture, the handler
verifies that all 3560 prefilled bytes after the FPSIMD terminator are zero.
The fixture also checks the terminator and `uc_stack` padding. This
observes the successful ordinary frame; it leaves alternate-stack padding
and unsuccessful writes outside the measured coverage.
The EL0 fixture adds 44 executable bytes and keeps its mapped extent and
stack reservation. The normal QEMU kernel ELF is byte-identical. RPi5
executable section size and usable RAM start agree with the baseline;
its packed ext2 image changes the linked read-only data size.

Both normal kernel links validate the complete resolved PAN open and close
leaves before using the compiler's narrow write-frame assumption in a
kernel artifact. Each leaf must be a strong defined function containing
exactly its expected PAN write and return. The check establishes the
absence of a memory-writing instruction in those two leaves. Destination
mapping and COW retain their own premises.

The full Pipe read/consume proof is deferred. A first-span fault must
consume nothing, and a second-span fault after wraparound must consume
only the successful first span. The projected-lock and cursor-store checks
cover parts of this path. The prototypes left cursor continuity across
user mapping and COW unproved and were left out of the maintained kernel.

On RPi5, a fixed-size USB READ(10) finishes with a checked destination
only after the current receive reports the full byte extent and the
matching CSW reports a complete successful command. The linear receipt
holds the DMA CPU token until copy or discard. The aligned receive
placement, event fields, and cache assumptions are recorded in
[the READ(10) evidence](XHCI_READ10_SPACE.md).

The remaining review includes ring and frame consumers, allocation-backed
exports and scalar ABI writers. In particular, TCP RX still needs
current-receive initialization evidence across reacquisition, and fresh
COW publication still relies on the lifetime of the old copy source.

Both normal kernel builds check the resolved callers of the physical PTE
read and its raw descriptor helper. Only the reviewed VM paths and stopped
crash translation read PTEs by physical table address. Raw descriptor
reads are limited to the architecture's PTE read, PTE update and L3 link
lookup.

The process record's backing handle has two reviewed writers. Publication
zeroes a fresh region slot and records its address and generation. Release
tries to pin the named slot and clears the handle. A successful pin is
retired, with slot reuse deferred while another pin remains. Both normal
builds check the callers of publication, release and their shared setter.
The lifetime of the backing record is distinct from the lifetime of the
physical tables it names.

Both initial exec stack builders clear the stack page, then write the
16-byte `AT_RANDOM` payload between the auxiliary vector and argument
strings. The vector points to the payload's user virtual address. Each
payload store checks its index, and an out-of-range index returns
`Invalid` before publication. The page uses the common full-initialization
mapping gate, with its existing allocator and architecture premises.
The payload bytes come from fixed patterns and provide no entropy.
The existing distro image and httpd loader views check auxiliary vector
setup for static and dynamic exec. They do not compare the payload bytes.

For a supported, nonempty `ppoll` descriptor array, the syscall checks
the writable span of all 8-byte `Pollfd` records. Each visited record
supplies a four-byte `fd` read and a four-byte read starting at `events`
that also spans `revents`. The result store writes only the two-byte
`revents` field. The `fd` and `events` bytes stay caller-owned and
unchanged. The ready count includes entries with nonzero reported events.
Earlier stores can remain visible if a later access faults or the call
blocks. A zero-descriptor call has no descriptor array output. Physical
access retains the common user-range and access-window premises.

For `getdents64`, fixed procfs entries, numeric procfs entries and ext2
entries all write the header fields, name bytes and trailing NUL directly
into the caller's buffer. A completed record contributes its eight-byte
aligned length, including up to seven alignment bytes after the NUL that
stay caller-owned and untouched. A pending record that does not fit in a
nonempty buffer is left unwritten. The call returns `EINVAL` if it has
written no records, or returns the completed prefix. A store fault can
leave part of the attempted record changed. Procfs PID enumeration and
ext2 exclude that record from any returned prefix. The affinity fixture
checks the fixed `takibi` entry's six padding bytes and the next byte
after the returned extent when it fits in the buffer. The BusyBox `ls`
and `ps` checks exercise enumeration without inspecting raw padding.

The implemented `newfstatat` routes for procfs nodes and ext2
directories, applet links and files each validate a 128-byte result, zero
the full span, and write selected scalar fields directly into that span.
Success requires all the stores to report success, so padding and fields
without explicit values are zero. Lookup failures before output leave the
result untouched. A fault once output starts can leave earlier writes
visible. The BusyBox shell checks exercise pathname metadata such as
directory size, without comparing every output byte or the surrounding
extent. The kernel has no separate `fstat` dispatcher arm.

The `getresuid` and `getresgid` paths write real, effective and saved
IDs in order, each to a separately checked four-byte destination. A
fault on a later destination can leave earlier IDs written. The
credentials fixture checks all three values and the four untouched
bytes after each ID for both calls. It also checks `getresuid` with
an invalid first pointer. Faulting later destinations are untested.

On success, `pipe2` writes two four-byte descriptors and
`clock_gettime` writes two eight-byte timespec fields. Both check the
entire result span before writing. A failed store can leave earlier
writes visible. On a store fault `pipe2` also closes both descriptors.
The pipe wrap fixture uses both descriptors and checks eight untouched
bytes on either side of the pair. For realtime and monotonic clocks,
the clock fixture reads both fields and checks eight untouched bytes
on either side of the result.
Neither fixture checks partial-store behavior.

`accept` and `accept4` return the descriptor without accessing their
address and length arguments. The implemented `getpeername` first
clears a checked 16-byte address and sets its first byte to 2
(`AF_INET`), then writes 16 to a separately checked four-byte length.
The output length is fixed, and a length fault can follow a successful
address write. If the destinations overlap, the length store can overwrite
part of the address. The socket views check connections and descriptors
without comparing the address and length bytes.

For `wait4`, a supplied status pointer receives one checked four-byte
status word when a child is delivered. The optional usage result is
cleared across a checked 144-byte span before waiting or reaping, so it
can change before the call returns a child. An invalid usage destination
fails before reaping. The regular child fixture checks the status and
reads the two microsecond fields from a previously filled usage buffer;
it does not inspect the remaining usage bytes.

`getcwd` writes only the root slash and trailing NUL and returns 2.
A buffer smaller than two bytes returns `EFAULT` before output, and
the shell startup exercises the usable result. `getcpu` writes its
optional four-byte CPU and node results separately, so failure of the
second write can leave the first visible. `sched_getaffinity` writes
one eight-byte mask and returns 8 even when the accepted buffer is
larger. The EL0 CPU fixture checks node zero and the reported CPU's
membership in the mask. These fixtures do not compare adjacent bytes.

The `TIOCGWINSZ` ioctl clears its checked eight-byte reply and writes
the fixed row and column counts. `TCGETS` copies all 36 settings bytes
under the process-run lock. The UART read writes received bytes
individually and counts them after successful stores. Bytes after a
successful read's returned extent stay caller-owned. A failed store
can leave earlier bytes visible. The terminal views check settings
and input behavior without inspecting every raw output byte.

The shared `getitimer` and `setitimer` output helper checks a
32-byte span and writes four eight-byte interval and remaining-time
fields. A write fault can leave earlier fields visible. The ordinary
timer fixture checks `getitimer` and the previous timer value returned
by `setitimer`; it does not compare adjacent bytes.

The kernel-only EL0 fixture checks successful scalar ABI output in the
existing userspace view. For statfs, both the ext2 root and procfs overwrite
a nonzero 32-byte reserved tail with zero. For sysinfo, all 104 bytes after
uptime overwrite a nonzero pattern with zero, while eight sentinel bytes on
each side of the 112-byte result are preserved. For `getrusage(RUSAGE_SELF)`,
all 112 bytes after the two timevals overwrite a nonzero pattern with zero,
while eight sentinel bytes on each side of the 144-byte result are preserved.
These checks cover the observed tails and extents. They do not add any claim
about uptime, CPU accounting, other fields, or faulting destinations.

The existing successful `wait4` fixture checks all 144 bytes of Takibi's
zero-filled rusage output and eight adjacent canary bytes on each side.
The shared Linux fixture checks the canaries and its existing timeval
bounds. The zero-fill check describes the current Takibi result and makes
no claim about child accounting or fault and reap ordering.
The fixture frame grows from 352 to 368 bytes and its executable text
by 128 bytes, with the same mapped end. The normal QEMU kernel ELF is
byte-identical. The RPi5 linked text accounting grows by 16 bytes from
the embedded fixture, with the same kernel RAM reservation.

## Refreshed trust measurement

`make trustedbasecheck` passed on 2026-11-17. The depfile-derived inventory
reported 180 source files / 99,365 lines (RPi5 164 files, QEMU 143, EL0 test
payload 4), with 35 kernel Takibi files outside that union. It counted 115
explicit unsafe blocks / 139 enclosed lines, 454 raw-pointer casts and 108
extern function/symbol declarations. Production handwritten assembly was
34 files / 2,837 lines; generated assembly 15 / 1,125; fixture assembly
1 / 27. These syntactic counts describe review surfaces, not independent
premises or a proof strength.

The ledger report uses different scopes. Its source-wide unsafe count was
178, extern functions 74, and assembly lines 2,864. The
[trust ledger](TRUST_LEDGER.json) recorded 144 QEMU and 154 RPi5 build-derived
raw sites on 2026-11-11 (76 and 86 after excluding probe-linked evidence
files). The 2026-11-17 entry records 146 and 156 (78 and 88 under the same
exclusion). The two added sites on each target are the raw output-address
conversions in `el1_resume_probe_checked` and
`crash_snapshot_copy_leveled_frame`. The
[trusted base](../TRUSTED_BASE.md#explicit-trusted-boundaries) records the
assembly output and lifetime premises for these wrappers. The compiler
checks their Takibi callers against the wrapper contracts.

The ledger in published `e0ec95e88` retains the later counts. The normal
QEMU and RPi5 facts from the subsequent L3 neighbor check agree with the
ledger totals and the two sites in `user_entry_extern.tkb`. These are
counts of compiler-reported sites. Assembly stores and pointer lifetime
remain audited premises.

No trust premise is retired or added by this document. Before making the
final scoped claim, complete each matrix row's source-backed controls,
export inventory, compiler/external trust justification, measured migration
costs and property-by-property Rust comparison. Any required new language
rule, runtime fallback or broader trust premise returns for a decision.

The scoped exec-metadata lifetime migration and its address/authority controls
are reviewed in [the measured lifetime report](EXEC_METADATA_LIFETIME_REVIEW_2026-11-17.md).
It extends the lifetime row above; it does not discharge the other rows or
turn the source-pinned initialization/export inventory into a universal proof.

Ordinary direct-helper lifetime inference and its termination, transfer and
cost controls are reviewed in [the inference report](INFERRED_REFERENCE_LIFETIMES_2026-11-17.md).
This closes the demonstrated unannotated reference-to-slice helper gap; it
does not establish general heap inference or discharge the remaining rows.
