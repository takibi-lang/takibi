# Cross-structure initialization experiment

Experiment date: 2026-11-16. This tests representative current kernel code;
it is not a claim of complete memory safety or a hardware concurrency test.

## Method

An isolated worktree at c9a57e20 plus the ongoing uncommitted strict-uninit
changes was compiled using the real QEMU and RPi5 source lists and compiler
flags. The RPi5 embedded filesystem image was copied from the existing build;
an initial missing-image failure was environmental, not a language verdict.
Both complete target compilations and their emitted Z3 obligations passed.
These are compiler/object-generation results, not full aggregate builds or
kernel executions. Mutations were applied individually and then restored.
No additional annotations, runtime clears or unsafe initialization assertions
were introduced into production code.

## Results

| Kernel example | Mutation | Result |
| --- | --- | --- |
| procfs_put_byte | Omit output byte store | Rejected: promised prefix not initialized |
| procfs_put_byte | Return offset + 2 after one store | Rejected: extra byte not initialized |
| procfs_put_usize | Omit local digits array store | Accepted: local arrays are untracked |
| syscall_statfs | Use slot after release | Rejected: linear value consumed |
| syscall_statfs | Release slot twice | Rejected: linear value consumed |
| syscall filesystem probe | Initialize, release, reacquire, consume new slot | Accepted: old initialization fact reused |
| page_alloc_contiguous | Use pool after giving back its guard | Rejected: derived pointer outlives guard |
| diagnostic_trace_record | Omit payload field d | Rejected: field not written at commit |
| diagnostic_trace_record | Commit before writing final field | Rejected: write token already consumed |

Seven mutations are correctly rejected; two expose limits. The fresh-slot
mutation also compiles for RPi5. Z3 accepts emitted facts for both accepted
bad cases: the solver cannot recover storage identity or reads that the
compiler did not model correctly.

## Prefix buffers

`procfs_put_byte` and `procfs_put_text` already use one uninit qualifier and
two boundary clauses each: the input prefix is initialized, and the returned
prefix is initialized. The text loop needs no handwritten loop invariant or
per-call proof annotation. The existing compiler carries the interval through
its mutable cursor. This is direct compiler acceptance/rejection evidence,
not a custom model of the renderer.

This guarantee is limited to the output footprint. `procfs_put_usize` uses
an uninitialized local array for digits, which current definite-initialization
analysis does not track. Removing its digit store leaves later reads accepted.
The documented local-array limitation is therefore relevant to real kernel
code, not just a hypothetical language corner. It needs static array tracking
before claiming complete initialization safety for the renderer.

## Slot ownership, identity and reuse

Syscall scratch uses a linear SyscallSlot and atomic claim/release of a slot.
Existing ownership rules reject use after consumption and double release,
without new annotations. They do not tie initialization facts to the selected
slot or its acquisition lifetime.

A minimal example constructs two distinct slot owners (indices 0 and 1),
initializes only the first, and calls a requires-init reader on the second.
Both the current experimental compiler and the saved pre-change compiler
accept it. The new Z3 leaf checks also pass. Same-slot reads and explicit
initialization of the second slot are positive controls; omitting both fills
is rejected. The real kernel release/reacquire mutation confirms applicability.
The unconfigured-filesystem probe may return before reading bytes, so this is
a demonstrated invalid API proof, not a demonstrated executed memory leak.

The implementation collapses scratch indices to one global field path.
Exclusive ownership of each slot does not justify that collapse. A suitable
static direction is to associate facts with element/authority identity and
invalidate dependent facts at consumption or require a proved preservation
relationship. The final annotation cost is not yet measured.

## Guarded access and publication

The page allocator's existing LockedCellGuard and derived pointer lifetime
reject access after unlock. The diagnostic ring's struct-publish mechanism
rejects missing payload fields and writes after commit. Neither experiment
needed a new proof annotation. The writer already has a publish declaration,
one begin/commit pair and six payload stores; these are real runtime/API
operations, not newly added ghost annotations.

These are compiler ownership/publication guarantees. Baseline Z3 checks
arithmetic and emitted initialization coverage, but did not independently
prove the guard or publication state machine. Mint validity, lock exclusion,
release/acquire ordering, reader sequence validation and storage lifetime
remain separate obligations. No hardware behavior was tested here.

## Decision supported by this evidence

Do not start kernel-wide adoption on the assumption that initialization
facts already identify the right storage. First address scratch-slot identity
and local-array initialization, retaining these real negative controls, then
re-run the representative set. Continue the linked-contract work as a separate
structural case rather than treating it as the missing universal mechanism.

No new runtime workaround is justified yet for either discovered limit.
Existing atomic slot claims, locks and publication sequence validation remain
runtime parts of the concurrent design; static checking can constrain their
use and prove conditional guarantees, not precompute which core wins a race.
If a static repair becomes disproportionately expensive, any proposed clearing
or runtime validity check must state the exact uncovered property and cost.

## Follow-up experiment: synchronous syscall descriptors (2026-11-16)

The stricter initialization checker now reaches a distinct lifetime boundary
in the EL0 readv fixture. A borrowed output buffer must remain live while a
local iovec stores its address and the kernel consumes the descriptor. The
output initialization assertion does not establish that lifetime.

Seven isolated source compilations with the experimental compiler and
`--target aarch64-none-elf --external-entry <entry>` gave these results.
Each rejection was checked for both a nonzero exit and its storage diagnostic.
The accepted cases generated objects; none of these experiments executed a
syscall.

| Representation | Result | Meaning |
| --- | --- | --- |
| Borrowed pointer passed directly to svc5 | Accept | Existing synchronous builtin boundary permits direct use |
| Pointer cast to usize in a local descriptor record | Reject | Aggregate component region tracking is absent |
| Pointer cast to usize in a local two-word array | Reject | Array storage loses the direct-local lifetime tie |
| Same array store inside unsafe | Reject | Unsafe does not waive lifetime checking |
| Address derived from a consumed indexed owner, returning a linear owner with the same indices | Accept | Existing reviewed ownership-handoff contract applies |
| Same handoff, but address comes from an unrelated borrowed parameter | Reject | An unrelated owner cannot justify retention |
| Borrowed address packaged into a newly constructed owner | Reject | Owner construction cannot erase the borrow tie |

The simplest rejected source shape is:

```takibi
fn descriptor(p: borrow *u8) -> usize {
    let mut words: [usize; 2];
    words[0] = p as usize;
    words[1] = 8;
    return svc5(65, 0, words as *usize as usize, 1, 0, 0);
}
```

The return value here is the syscall result, not the descriptor address.
Even so, the first store rejects before the synchronous use is considered.
The real fixture has two nonempty segments and an empty segment, plus a
short-read case with a deliberately invalid subsequent segment. Replacing
readv with ordinary reads would remove the behavior the fixture tests.

The existing indexed-owner handoff is not a general solution for a caller's
borrowed stack buffer. Its acceptance is a reviewed storage contract, not
proof that a local descriptor cannot escape. Giving this fixture new global
storage, clearing a buffer merely to construct an owner, or minting an owner
that silently forgets the caller's lifetime would change the problem.
Scoped callbacks also retain their declared borrow checks; they do not add
aggregate component tracking.

A potential narrow compiler extension is to track the union of source
lifetimes stored in a local descriptor aggregate. Using or exporting its
address must require all those lifetimes to remain live; returning it,
storing it durably, or passing it to a retaining callee must still reject.
Typed stores are the initial tractable surface. Raw alias writes, copies,
branch joins, loop-carried state and rebindings need explicit negative
controls before acceptance can be claimed. This is a proposed lifetime
analysis, not an implemented guarantee or a Z3 arithmetic obligation.

### Local word-array prototype and recommended syntax

A separate compiler copy, not the maintained compiler, was modified for this
experiment. The first candidate allowed a typed store into a local array and
unioned the stored value's authority dependencies into the array. Scalar
indexed reads retained that union. No parser or LLVM representation changed.

Ten controls exposed three unsound acceptances: loading through a pointer
alias made after the address store, an alias made before it, and an ordinary
borrowed scalar-load helper. The existing rule intentionally treats scalar
loads through borrowed pointers as copied data, so it lost the encoded
address's dependency. This candidate must not be integrated.

The restricted candidate adds a deliberately small syntax fragment: directly
named local word arrays, typed indexed stores/reads, branches, and direct
syscall descriptor arguments. Array aliases, passing the array to an ordinary
helper, indirect stores, shadowing and unsupported statement forms (including
loops) reject before transfer analysis. The experiment's gate applies broadly
to local usize arrays in the function; it is not a production classifier.
It is not evidence for arbitrary local aggregates or all alias shapes.

| Restricted control | Observed result |
| --- | --- |
| Construct two-word descriptor, use synchronously | Accept |
| Return encoded address by indexed load | Reject |
| Store encoded address to a global | Reject |
| Return address stored on one branch | Reject |
| Same global escape inside unsafe | Reject |
| Alias constructed after descriptor store | Reject |
| Alias constructed before descriptor store | Reject |
| Borrowed helper extracting a scalar from descriptor | Reject |
| Raw pointer alias used for descriptor store | Reject |
| Return the independent length word | Reject, known false positive |
| Owner-backed descriptor used before release | Accept |
| Same descriptor used after release | Reject |
| Release inside a branch, then descriptor use | Reject |
| Three iovecs: three bytes, empty, five bytes | Accept |

All rejection controls exited nonzero with the corresponding authority or
restricted-fragment diagnostic. These are compile/code-generation results,
not syscall executions or Z3 proofs. The final three-iovec object's .text is
byte-identical to an object built by the maintained compiler from the same
source with an ordinary, non-borrow pointer parameter. This one example adds
no runtime metadata, flag, clearing or instructions.

The recommended initial spelling uses existing syntax, inside an audited
ABI wrapper:

```takibi
fn probe(p: borrow *u8) -> usize {
    let mut words: [usize; 6];
    words[0] = p as usize;
    words[1] = 3;
    words[2] = 0;
    words[3] = 0;
    words[4] = (p + 3) as usize;
    words[5] = 5;
    return svc5(65, 5, words as *usize as usize, 3, 0, 0);
}
```

This is the compiled lifetime experiment, NOT a safe public readv API: its raw
pointer does not prove an eight-byte writable allocation, descriptor length,
ABI validity or successful initialization. A maintained caller-facing wrapper
should continue to accept `borrow uninit` bounded slices and return the
existing result variant with exact success-prefix contracts. Descriptor
construction stays within that audited boundary. The prototype does not make
an arbitrary svc5 call non-retaining: actual syscall semantics remain trusted.

No `scoped`, lifetime parameter, descriptor-specific type or per-access proof
annotation is justified by these results yet. Local dependency inference can
handle the narrow example. A safe production implementation still needs
binding-identity-based descriptor classification, alias/copy handling or
explicit rejection, joins, scope exit and loop controls. More precise
per-element tracking could accept the length-word control, but is not needed
by the measured direct-use example. These are implementation limitations, not
an undecidability result or a reason to add runtime initialization flags.

### Literature review: constrain the representation before widening analysis

The local word-array recommendation above was an experimental result, not a
settled language design. A subsequent review of primary sources suggests
investigating a typed borrowed descriptor before implementing general
field/element-sensitive tracking of encoded addresses.

- Rust's IoSliceMut is a lifetime-bearing wrapper around a mutable byte slice
  with an iovec-compatible ABI. Its Unix representation contains a private
  iovec and PhantomData<&'a mut [u8]>. The implementation constructs address
  and length together from a slice and keeps raw reconstruction inside the
  abstraction. It does not ask the borrow checker to recover a lifetime from
  arbitrary usize-array contents. Sources:
  https://doc.rust-lang.org/std/io/struct.IoSliceMut.html
  https://doc.rust-lang.org/src/std/sys/io/io_slice/iovec.rs.html
- Rust's documented borrow splitting distinguishes disjoint struct fields,
  but delegates more difficult separation to APIs such as split_at_mut,
  whose implementation encapsulates unsafe reasoning. NLL infers reference
  lifetimes from uses/control flow. Neither is a general proof that arbitrary
  raw pointers or integer encodings preserve a borrow. Sources:
  https://doc.rust-lang.org/nomicon/borrow-splitting.html
  https://rust-lang.github.io/rfcs/2094-nll.html
- Oxide formalizes borrowing with provenance approximations and proves type
  safety for its core language. It provides a basis for rules and negative
  controls, not an off-the-shelf whole-Takibi or raw-ABI verifier. Source:
  https://arxiv.org/abs/1903.00982
- Cyclone attaches regions to pointer types and combines regions with unique
  pointers. A scoped alias temporarily consumes the unique source, permits
  aliases within the region, and restores the source at scope exit. This
  restricts when aliases can be used instead of reconstructing all C alias
  relationships. Its lifetime checking is static; its bounds mechanisms must
  not be conflated with static bounds proofs. Sources:
  https://www.cs.cornell.edu/Projects/cyclone/papers/cyclone-regions.pdf
  https://www.cs.cornell.edu/projects/cyclone/online-manual/main-screen008.html
- Viper uses heap-location permissions, supporting separation logic and
  implicit dynamic frames. Contracts and invariants describe accessible
  state; backends discharge obligations using Z3. This can model richer heap
  sharing, but importing the framework is not a small replacement for the
  missing local-array transfer rule. Source:
  https://viper.ethz.ch/tutorial/

Takibi inference from these sources: keep address authority and ordinary
length values distinct in a typed abstraction, carry the buffer borrow
through descriptor storage and helper signatures, and convert to raw ABI
storage only inside a narrow boundary. A length accessor can return a plain
usize without exporting authority. The descriptor or a derived pointer must
retain the borrow. Merely tagging an arbitrary raw pair with a token is not
enough: constructors, mutation, copying, scope exit and derived accesses must
be checked or explicitly audited.

A writable uninitialized destination is an additional Takibi requirement:
IoSliceMut::new takes an initialized mutable byte slice, so its API cannot be
copied directly. The descriptor must grant write access without granting
readability; the successful syscall prefix determines subsequent readable
bytes. Alias exclusion and initialized coverage are separate obligations.

Recommended next experiment: a fixed synchronous descriptor abstraction
using existing indexed-owner/erased-view and scoped-borrow mechanisms where
possible. Measure the missing constructor/borrow relation before choosing
new syntax. Do not yet implement general usize-array alias analysis, a full
NLL engine, or a permission-logic verifier. This recommendation neither
establishes feasibility with current Takibi nor authorizes a new unchecked
retention exception. The deliberately invalid iovec in the short-read test
must remain an explicit ABI-negative fixture; a safe constructor should not
pretend that its invalid segment is a valid borrow.

### Borrowed synchronous descriptor: existing-mechanism experiment

Ten standalone object-compilation controls were run with the maintained
experimental compiler, without the separate array-taint prototype. Three
positive cases compile, four lifetime-misuse cases reject, and three
construction candidates reject because the current representation rules do
not support them. This is not yet an end-to-end readv implementation.

The successful core uses the existing authority-derived linear-guard rule:

```takibi
linear struct Buffer[id: usize] { index: {0..<4 as usize} @ id; }
linear struct IoBorrow[id: usize] { length: usize; }
fn begin(b: borrow Buffer[id]) -> IoBorrow[id] @ id {
    let mut d: IoBorrow[id] = { 8 };
    return d;
}
fn length(d: borrow IoBorrow[id]) -> usize { return d.length; }
fn end(d: sink IoBorrow[id]) {}
fn release(b: sink Buffer[id]) {}
fn probe(b: Buffer[0]) -> usize {
    let d = begin(b);
    let n = length(d);
    end(d);
    release(b);
    return n;
}
```

Buffer is a synthetic authority for this lifetime experiment. It is not an
allocator, a proof of backing storage, or a validated eight-byte buffer.
IoBorrow intentionally contains only length, so these results establish
borrow tracking and independent scalar results, not address encapsulation.

| Control | Result |
| --- | --- |
| Read length, end descriptor, release buffer, return length | Accept |
| Read length through another borrowed-descriptor helper | Accept |
| Move descriptor, read length, end moved descriptor, release buffer | Accept |
| Release buffer while descriptor remains live | Reject: live derived guard |
| End descriptor, then use it | Reject: consumed linear value |
| Return descriptor without its declared source-borrow relation | Reject: tied value escapes |
| Move descriptor, then release buffer before ending moved descriptor | Reject: moved guard retains loan |
| Store borrowed backing address in a runtime descriptor returned with @ id | Reject: aggregate storage loses region information |
| Give borrow-uninit slice parameter an @ id and return tied guard | Reject: slice singleton annotation unsupported |
| Substitute borrow raw pointer @ id in the constructor | Reject: that borrowed parameter shape unsupported |

Negative controls were checked independently for nonzero exit and diagnostic;
no syscall or kernel execution occurred. The unsupported-construction rows
must not be presented as evidence that every other encoding is impossible.
Code review confirms that the existing returned-guard relation is designed
around borrowed indexed authorities, not an arbitrary local slice lifetime.

This experiment narrows the remaining design work:

1. Tie a descriptor constructed from an ordinary local uninitialized slice
   to that slice's storage lifetime, without minting an unrelated owner.
2. Encapsulate its address and length so that the address retains authority
   while length accessors return ordinary scalars. The existing @ return
   relation alone does not permit arbitrary raw address fields.
3. Preserve per-output initialization contracts separately. A live writable
   descriptor must not imply that any output byte is readable.

Existing begin/borrow/end syntax already demonstrates the desired lifetime
behavior for indexed owners. It would be premature to add a general scoped
keyword or claim the exact local-slice constructor syntax is settled. A
narrow constructor/representation rule still needs design and validation;
ordinary array alias analysis and untracked integer encodings are not
required by the successful core. In particular, a successful metadata-only
experiment is not grounds to grant a raw aggregate-storage exception.

### Local-slice loan prototype (additional bounded experiment)

An isolated compiler copy extends the returned-guard source relation to a
named borrowed slice parameter. The proposed spelling is `@ output`, naming
the parameter itself rather than a static owner index. The parser already
accepts this spelling; the prototype changes validation and lifetime-source
mapping, not LLVM layout. This is NOT implemented in the maintained compiler.

```takibi
linear struct IoBorrow[tag: usize] { length: usize; }
fn begin(output: borrow uninit [u8; 8..]) -> IoBorrow[0] @ output
    ensures init(output[0..<0]) {
    let mut d: IoBorrow[0] = { output.len };
    return d;
}
fn length(d: borrow IoBorrow[0]) -> usize { return d.length; }
fn end(d: sink IoBorrow[0]) {}
fn probe() -> usize {
    let mut output: [u8; 8];
    let d = begin(output as []u8);
    let n = length(d);
    end(d);
    return n;
}
```

The empty initialization contract is significant. Current borrow-uninit
parameters default to a whole-output obligation if no relevant output range
contract is present. An `ensures true` clause does not suppress that default.
Descriptor construction writes no bytes, so the explicit empty range both
avoids that obligation and grants no readable bytes to the caller. This is
an experiment using existing init syntax, not a settled recommendation for
how a no-write constructor should be spelled.

Thirteen compile controls had the intended outcomes:

- Five accept: local buffer length result, helper length result, a live
  owner-derived slice, moved descriptor followed by length/end, and ending
  the descriptor on both branches.
- Seven reject misuse: returning a local descriptor, reading the uninitialized
  output after begin/end, shadowing the borrowed storage, double end, releasing
  the original owner behind a slice alias, returning a moved local descriptor,
  and ending on only one branch.
- One still rejects the unsupported representation: adding a source-derived
  raw address to the descriptor record. That rejection was not relaxed.

For owner-derived slices, the result keeps both the immediate argument
binding and its inherited source authorities. Keeping only the slice variable
would miss the original owner's lifetime. The caller tests exercise this
transitive source relationship; they do not infer arbitrary pointer aliases.
Each negative control checks both nonzero exit and its diagnostic.

The example still carries metadata only. It does not establish exclusive
mutation of all aliases, ABI storage validity, record-address projection,
syscall execution or initialized-output correspondence. Generic pointer and
aggregate storage rules remain unchanged. A further representation rule must
keep address extraction tied to the descriptor while allowing length to be
an ordinary scalar; merely making the address a private usize is not by
itself a compiler proof. The constructor/representation rule, collisions
between parameter names and static indices, additional alias forms and
function-wide compatibility remain unvalidated production-design questions.

### Address-bearing descriptor and native I/O experiment

The isolated compiler prototype now carries two words in IoBorrow: address
and length. This is a deliberately type-specific experimental rule, not a
production implementation of arbitrary borrowed records. The constructor
must have the exact closed body that obtains the raw u8 address and length
from the same borrowed slice, then returns the descriptor with its source
relation. Altered lengths, shifted addresses and narrowing integer casts
reject. Field mutation and locally forged descriptors reject. The narrow
recognizer is a way to measure the design, not a proposed user annotation or
a complete security audit of every construction path.

Projection rules distinguish the two fields. Address projection retains the
descriptor's authority even while represented as usize; a pointer-returning
accessor must declare its return relation. Length remains an ordinary scalar.
The existing unsafe requirement for integer-to-pointer reconstruction remains
in force; no general raw-pointer validity claim is inferred from the integer.

```takibi
linear struct IoBorrow[tag: usize] { address: usize; length: usize; }
fn begin(output: borrow uninit [u8; 8..]) -> IoBorrow[0] @ output !{unsafe}
    ensures init(output[0..<0]) {
    let mut d: IoBorrow[0] = {
        (unsafe { output as *u8 }) as usize, output.len
    };
    return d;
}
fn length(d: borrow IoBorrow[tag]) -> usize { return d.length; }
fn address(d: borrow IoBorrow[tag]) -> *u8 @ tag !{unsafe} {
    return unsafe { d.address as *u8 };
}
fn end(d: sink IoBorrow[tag]) {}
```

Fifteen compile controls had the expected outcomes. Live pointer use and
length-after-end compile. Returning the address as an unqualified integer,
using a pointer after end, converting it to an integer before end then using
it, and using a pointer forwarded by an annotated helper after end reject.
Wrong length, truncated/shifted address, mutable field changes, forged local
construction and direct return-literal construction reject. Arbitrary
whole-record address-taking remains rejected. Directly casting an indexed
owner to an iovec pointer also remains unsupported: this is a known remaining
ABI-entrance constraint, not a successful direct readv implementation.

A native Linux/AMD64 execution experiment avoids weakening that last rule.
A C adapter accepts the descriptor by value under an extern borrow contract,
constructs one local struct iovec, calls readv synchronously and retains
nothing. The Takibi caller passes a borrowed descriptor, ends it after the
call, and asserts the exact eight-byte output only if readv returned eight.
This output assertion and the adapter's non-retention remain audited
premises. The adapter is experimental, not an adopted kernel dependency.

Observed execution results:

| Input | Takibi result | Interpretation |
| --- | --- | --- |
| Bytes 1 through 8 | Checksum 36 | Actual output reaches the borrowed stack buffer |
| Four bytes followed by EOF | Zero | Short result is not consumed as eight initialized bytes |
| Immediate EOF | Zero | Empty result is not consumed |
| Invalid descriptor | Zero | Failed read is not consumed |

Removing the eight-byte initialization assertion rejects at the subsequent
array read, with nonzero exit and the expected initialization diagnostic.
Thus merely constructing/ending the descriptor has not fabricated an output
fact. The real readv execution establishes one-descriptor native ABI behavior,
not the complete kernel syscall or a Z3 proof of the external implementation.

Outstanding before adoption: replace the experiment's type-specific
recognizer with a reviewed closed representation rule; define the synchronous
ABI entrance without arbitrary owner address-taking; test multiple and empty
segments, source aliasing and branch/loop lifetime cases; and keep the kernel's
intentionally invalid segment outside the safe descriptor constructor. No
maintained compiler or kernel source was changed for this experiment.

## Production integration follow-up: typed I/O (2026-11-16)

The working compiler now owns linear IoReadSpan/IoWriteSpan descriptors,
retains their source loans, separates read/write direction, and exposes only
length, synchronous submission, and explicit end operations. No general
integer-array pointer-retention exception was added. The unit suite passes,
including lifetime, forgery, direction and initialization negative controls.

The actual user_payload ELF builds with normal vector calls migrated to
these descriptors. Its deliberately invalid null tail uses a separate leaf
assembly object linked only with user_payload test images. The kernel and
terminal program do not link that object. This exception was approved for
the negative fixture only; normal descriptor construction remains checked.
The existing eight-byte output assertion remains an audited syscall premise.

Native Linux execution with the integrated compiler, rather than the earlier
C submission adapter, passed three-segment input with an empty middle span:
8, 4, 2 and 0 bytes produced checksums 36, 10, 3 and 0. An invalid descriptor
number produced no output read. These are synchronous host ABI controls, not
kernel execution or concurrency evidence.

Six additional EL0 programs now compile through shared audited getcpu/read
contracts. The protocol-trace fixture previously compared all 64 bytes even
when its first read could return fewer; it now compares only the returned
prefix. No padding clear or dynamic initialization flag was added.

Full-build integration is not complete. The first aggregate exposed generic
field inference through a borrowed RefcountSlotMap parameter (fixed with a
compiler regression test) and the still-unintegrated GrowablePool partial
initialization contracts. The linked-initialization research report remains
research evidence; it must not be described as shipped compiler checking.
The subsequent integration described below migrates the signal_boundary and
terminal outputs. Publication and the complete native build remain outstanding.

### Integrated field contracts and execution evidence

The maintained checker now accepts inline field paths in `init`, including
nested scalar fields and ranges of inline fixed arrays. It does not traverse
pointer or slice-descriptor fields. The real GrowablePool constructor uses one
`borrow uninit` qualifier and seven field postconditions, with its existing
stores and loops. It leaves `core.next_free` uninitialized. The isolated
constructor generates native code and its emitted Z3 obligations pass; six
mutated producers/consumers reject for the expected initialization or contract
diagnostic. Permanent unit tests also distinguish record padding, wrong
indices and ordinary whole-record borrowing.

This is not yet a usable partial GrowablePool API. The full build rejects
nine diagnostics in its native fixture, plus three shared diagnostics while
building intrusive_pool, because ordinary whole-record borrows would erase
the partial `core.next_free` state. Checked linked initialization across
activation, pop, remove and traversal remains the missing structural rule.
The research checker and constructor-only prototype are not silently imported
as production proof. No runtime clearing, bitmap or additional initialization
assertion has been introduced for this gap.

Signal, affinity, clock, terminal-size and wait-output consumers now use
explicit audited output boundaries. The existing signal assembly always
writes its one-word output before returning; no signal assembly instruction
was added. Terminal-size and wait wrappers grant only the exact successful
output footprint. These are cross-image/assembly trust premises, not solver
proofs of the external implementation; TRUSTED_BASE.md enumerates them.

Verification performed during integration:

- Compiler unit tests, including the field-contract controls, pass.
- Both maintained kernel targets and their fixture objects compile.
- `make kernelcheck-qemu` passes: the normal boot checks 76 views, and the
  DMA, invariant, FDT and shell scenarios pass. This run precedes the
  field-projection-only change; it is not final-commit publication evidence.
- `make modelcheck` passes. WorldStop's Read mapping was reviewed: only
  the terminal dispatch buffer contract changed, not stop/read/resume order.
- A maintained `linux_user/io_span` fixture executes native vector writes
  and reads, including empty segments, short reads, EOF and invalid-fd
  preservation. It compares every returned byte and untouched suffix.
  Initialized sentinels are the execution oracle; the compiler rejection
  tests separately prohibit reading uninitialized output.

Strict local-array tracking initially increased QEMU compiler allocation to
3,563,723,578 words. Restricting branch-prefix candidates to observed endpoints
and rejecting coverage searches with no reachable final endpoint reduced it
to 742,344,494 words, below the existing 743,000,000-word gate. Coverage
acceptance equivalence is tested on 1,372 small interval/fact combinations.
The last timed cold Z3 initialization run took 3.39 seconds within the
existing five-second gate. These are measured checks, not complexity proofs;
allocation headroom remains small.

The subsequent field-API migration reduces the native GrowablePool errors to
five self-directed insertion diagnostics. Metadata/shadow operations pass a
limited native execution using their real API bodies. The arithmetic where
connection, native layout controls and remaining linked-contract guarantee
question are described in MEMORY_LINK_PILOT.md. The latest QEMU compiler
allocation measurement is 742,628,983 words against the unchanged
743,000,000-word gate. Whole-build completion is still blocked by link
initialization transfer, not by a new assertion requirement.
