# Shared fixed DMA for the maintained xHCI driver

This is a design proposal, not implemented language syntax or a claim of
verified DMA safety. It separates partial memory authority from runtime
request concurrency. The first consumer remains the current synchronous
USB mass-storage driver. Multiple outstanding requests are not required.

## Existing-language feasibility

At compiler revision 0335d45d, four temporary CLI probes were compiled for
AArch64 with --forbid-trap:

| Probe | Exit | Evidence |
| --- | --- | --- |
| Store/take an existential RingCursor[ring, position] in one Place | 0 | LLVM object emitted |
| Put an owner indexed by another ring into that Place | 1 | static value mismatch: &other_ring vs &ring_bytes |
| Put the same owner after a terminal submit consumes it | 1 | linear value 'cursor' was already consumed |
| Write the ordinary backing array without any owner | 0 | LLVM object emitted; the access boundary is missing |

The positive shape uses a private linear runtime struct with an addr ring
index and a usize position index, and an ordinary global container holding
Place(exists position: usize. RingCursor[&ring_bytes, position]). Its lock
view obtains the mutex address index through a pointer parameter. These
probes test storage shape and resource flow only: their trusted guard and
owner constructors do not model real locking, DMA, initialization or unique
initial authority. They are not hardware tests or the eventual regression
suite. Existing compiler tests cover the underlying Place operations.

A ring-level owner can therefore carry the cursor and pending range without
an array of per-slot owners. No new stored-array rule is a demonstrated
prerequisite. If later implementation needs holder-indexed array contents
or a new place witness, it must use the shared stored-authority route.

## Proposed API contracts

The names below describe contracts for a proposed compiler-generated fixed
shared DMA declaration; they are not accepted source syntax. Nominal types
are per allocation, preventing a token from authorizing another ring.
Generated opaque runtime owners carry dynamic indices; their state and
identity are checked by the compiler. They must have a unique initial owner,
like today's dma_fixed, rather than public constructors or repeatable mints.

| Operation | Consumes or borrows | Result and obligation |
| --- | --- | --- |
| reserve(owner, count) | consumes Ready owner | Reserved owner with bounded contiguous TRB span, or refusal returning the original Ready owner |
| write_trb(reservation, relative_index, value) | borrows Reserved owner | Access only within the reserved span; no escaping pointer or slice |
| commit(reservation) | consumes Reserved owner | InFlight owner; ordered cache/Cycle publication, then notification |
| cancel(reservation) | consumes unpublished Reserved owner | Ready owner, only when no descriptor has been published |
| settle(inflight) | consumes InFlight owner | matching completion returns Ready; Unconfirmed retains the InFlight owner |
| reset(session) | consumes session state | confirmed quiescence permits reclamation; failure retains device obligations |

The initial implementation permits one outstanding request per producer
ring. The owner is partial authority: it never grants CPU access to every
TRB while the controller is running. Restricting request concurrency does
not justify treating the whole allocation as CPU-owned. An owner in the
Reserved state provides access to its range; in-flight descriptors and
unrelated slots remain inaccessible. Any raw cast/address escape from the
protected allocation is rejected, unsafe blocks included.

Reservation includes Link TRBs and No-Op padding when wrapping. The current
EP0 request has two or three TRBs; bulk and ordinary commands use one. A
failed or short transfer needs command/endpoint-specific reclamation rules,
not a universal nonzero-code-means-entire-ring-free rule. Recovery commands
must remain possible for halted endpoints while payload obligations remain
outstanding. Initialization commands use the same writer as later commands,
rather than special direct writes to slots zero through two.

The exact source declaration, generated variant representation, whether
reservation lends or moves the cursor, and integration with fixed-DMA
payload obligations remain surface decisions. The contract above is the
proposed minimal capability, not authorization to add a general ring library
or a protocol-to-type generator.

## Other session allocations

- The event ring has a device writer and a CPU consumer. A typed polling
  operation returns NotReady or an event snapshot and a release obligation.
  The CPU cannot write an active entry; advancing ERDP discharges the
  obligation. Marker/cache ordering precedes snapshot creation.
- The input context uses existing fixed TX authority, tied to the command
  that references it. Matching completion or confirmed quiescence returns
  CPU ownership; timeout does not.
- The output device context remains device-owned. Expose bounded read-only
  snapshots justified by the relevant command/endpoint state, without
  granting a writable CPU slice of the live allocation.
- ERST and scratchpad pointers are initialized then frozen while reachable.
  Scratchpad page contents stay device-owned throughout that session.
- DCBAA entries are published individually: the current enabled slot's
  entry is installed after controller start and before Address Device.
  Freezing the whole array at controller start would reject that sequence.
- A confirmed stop permits reclaiming DMA authority; reset completion is
  additionally required before starting a fresh session. Failed stop/reset
  cannot reach initialization through a boolean-only success convention.
  Old-session completion evidence cannot authorize a new session's memory.

## Completion, ordering and representation

The existing event helper checks event type, not the TRB pointer. The new
completion observation must correlate command TRB address, or transfer TD
and endpoint/slot as appropriate, before producing reclaim evidence. Short
packet and error events need their actual xHCI semantics. This is an audit
finding, not evidence of an observed incorrect-completion defect.

Cycle publication, cache synchronization and doorbell notification are
separate steps. Writing a matching Cycle bit can expose a descriptor; the
absence of a new doorbell is not exclusive ownership evidence. A one-bit
cycle marker is also not an independent generation or session identity.

TRBs are 16 bytes, while this target maintains 64-byte cache lines. Producer
rings are CPU-write/device-read; event storage is CPU-read/device-write.
The lowering must respect those directions without changing TRB stride.
ERST (16 bytes), scratchpad pointers (16) and DCBAA (520) need isolated
full-line backing extents for protected declarations: suggested extents are
64, 64 and 576 bytes. These are backing extents, not new hardware lengths.
Actual linked space must be measured; this proposal does not claim growth
from those extents alone because current alignment already creates padding.

## Responsibility and evidence

The shared DMA access boundary is compiler/language work in Territory B.
Existing Place storage is sufficient for the tested shape. Territory A's
MMIO migration must preserve the observation/notification hooks and use
IoHandles for their register accesses; it does not mint partial-memory
owners or need to implement a DMA-specific stored-array exception.

Before implementation, approve the shared declaration/API surface and a
bounded transition model covering reserve, wrap, publish, matching events,
endpoint recovery, timeout and failed reset. Compiler rejection tests must
exercise real protected accesses and alias expiry, including raw escape,
wrong ring, write after commit, context mutation in flight and reuse after
failed reset. Model controls must independently expose early publication,
wrong completion, unsafe wrap and timeout-as-completion. Tie model actions
to implemented transitions; bounded evidence is not a proof.

Use native fixtures for deterministic driver decisions, and real RPi5 USB
read/write/recovery lanes for device and cache behavior. QEMU is insufficient
for RP1 cache visibility. Cache-order questions remain a separate visibility
review; token ownership does not answer them. Finish with measured space,
allbuild and clean allcheck. Device semantics, target cache/physical mapping,
bus translation and compiler lowering remain the explicit trusted boundary.

## Hardware references

Intel xHCI 1.2b, section 3.2.5, specifies input context lifetime:
https://cdrdv2-public.intel.com/625472/625472_xHCI_Rev1_2b.pdf

Intel's published xHCI specification, section 4.9.2, describes producer and
consumer ring ownership and cycle management:
https://www.intel.com/content/dam/www/public/us/en/documents/technical-specifications/extensible-host-controler-interface-usb-xhci.pdf
