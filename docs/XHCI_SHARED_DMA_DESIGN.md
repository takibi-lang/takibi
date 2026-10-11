# Shared fixed DMA for the maintained xHCI driver

The maintainer selected general region ownership plus generated protocol
permissions on 2026-10-11 (B+C). A common Takibi protocol declaration is the
selected source for both TLA+ and permission types. This is not implemented language syntax or
a claim of verified DMA safety. It separates partial memory authority from
runtime request concurrency. The first consumer remains the current synchronous
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

The names below describe the earlier operation contracts; their dedicated
shared fixed-DMA declaration is superseded by the general B+C design. They
are not accepted source syntax. Region identity prevents a token from
authorizing another allocation. A protocol owner retains the actual region,
not just a cursor or erased view. Its state and identity must be checked by
the compiler, with a unique initial region and no repeatable re-mint.

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

The common-declaration generator is authorized. Its source syntax and
representation must preserve the general retained-region contract below;
they must not introduce a dedicated DMA storage mechanism. Reservation moves
its region into the protocol owner. Payload obligations remain separate
resources tied to the same request. A general ring library is not required.

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

Territory A supplies the general memory substrate on its stored-authority
and safe-memory routes. Territory B supplies the protocol model and its
connection to types, then the driver consumer. Existing Place storage is
sufficient for the earlier cursor probe, but not evidence that a protocol
owner can retain actual region authority. A's MMIO migration must also
preserve the observation/notification hooks and use IoHandles there. No
DMA-specific storage exception is proposed.

Implement the selected common declaration and retained-region API with a
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

## B+C substrate probes and next boundary

Two additional CLI probes on db9c9d5c, with --regions, AArch64 and
--forbid-trap, establish missing prerequisites rather than hardware defects:

- A linear struct Pending[b: addr, n: usize] with private field
  memory: region(u8)[b, n] is rejected: "struct field 'Pending.memory'
  cannot hold a nested indexed owner". The general nesting, field move and
  borrow rules must permit encapsulation while preserving identity and
  invalidating references made before the move. This is on the shared
  stored-authority route, not a special DMA capsule.
- After region_of(bytes) succeeds, bytes[0] = 9 still compiles. An additive
  general owned-storage declaration must seal every direct access and
  address/cast escape of its backing array. Legacy region_of's reviewed mint
  is not that boundary. Its existing callers must not be silently migrated
  by a blanket ban.

The intended general contract, in schematic notation, is:

    lend(region[T, base, length], Ready[instance])
        -> Pending[T, base, length, instance]
    resume(Pending[T, base, length, instance], Completed[instance])
        -> (region[T, base, length], Ready[instance])

The pending owner contains the region. Other disjoint regions obtained by
split remain usable. Neither a stand-alone view nor a matching integer is
permission to reconstruct the pending region. Runtime observation creates
completion evidence at a reviewed boundary; generated protocol transitions
cannot silently turn an unrelated event or timeout into that evidence.
This contract is useful for user-space asynchronous ownership transfer too.

SharedRegionTransfer.tla is the first bounded evidence layer: two abstract
cells, nonempty subregion reservations, individual cell preparation,
publication, device reads, matching/foreign events, timeout, confirmed reset,
failed reset and restart. It checks disjoint CPU/device authority and
preparation before a device read. The fixed model passes; early publication,
foreign-event reclamation, timeout reclamation and restart after failed
reset each violate Safety in TLC and shallow Apalache checks.

It deliberately does not model TRB layout/wrap, endpoint recovery, session
marker/cache ordering, silicon, or the general ownership implementation.
Those are remaining obligations, not established by a passing first model.
No protocol types are generated yet. The current action-to-code map ties
observations to the existing driver by reviewed function bodies; it does not
prove implementation conformance. Memory ownership and generated transition
permissions must eventually meet in the same retained owner.

## Selected common declaration and generation boundary

The source is one restricted Takibi protocol declaration. The compiler
validates it once, builds one protocol representation, and emits both the
TLA+ actions and sealed permission APIs from that representation. TLA+ is an
output, not a second handwritten input to translate back into types. The
existing handwritten SharedRegionTransfer model is reference evidence until
the generated model reproduces its fixed and faulty verdicts.

The first declaration needs the following data, independently of its final
surface spelling:

| Declaration part | Required content |
| --- | --- |
| Identity | allocation base/length, protocol instance/session, and request identity where completion can outlive a reservation |
| Retained resource | the actual region, split by the caller before transfer; every state accounts for it exactly once |
| States | Ready and Reserved allow bounded CPU access; InFlight and Unconfirmed retain the inaccessible region; Down retains unconfirmed obligations; Halted permits reclamation only after confirmed quiescence |
| Transitions | consume one state owner and produce the declared successor or an exhaustive failure returning the retained owner |
| Observations | matching completion and confirmed reset are declared external contracts, each tied to the retained instance/request |
| Access | generated scoped access only in CPU-authorized states; consuming or moving the owner expires derived references |
| Properties and bounds | ownership disjointness, preparation before external read, and explicit finite model configurations; not compiler axioms |

The operation signatures are schematic, not accepted syntax:

    reserve(Ready[instance, base, length], count)
        -> Reserved[instance, base, length, request] | Refused(Ready[...])
    publish(Reserved[instance, base, length, request])
        -> InFlight[instance, base, length, request]
    observe(borrow InFlight[instance, base, length, request])
        -> Matching[instance, request] | NotReady | Foreign | Failed
    resume(InFlight[instance, base, length, request], Matching[instance, request])
        -> Ready[instance, base, length]
    expire(InFlight[instance, base, length, request])
        -> Unconfirmed[instance, base, length, request]

InFlight and Unconfirmed encapsulate the region; they do not destroy it and
later reconstruct it from an address. The generated API has no unrestricted
constructor for a state, Matching witness or initial authority. Request and
session identity must not rely on a reusable TRB address alone. Exhaustion,
late events and reset failure must retain ownership rather than re-mint it.
The exact xHCI observation correlates the pending request with the event's
TRB/TD, endpoint and slot under the reviewed device contract.

Every guard must have an explicit lowering category:

| Guard or obligation | How it is established |
| --- | --- |
| owner identity, state, consumption and resource conservation | checked type/ownership flow; generated sealed transitions cannot omit or duplicate the region |
| bounds and disjoint split/merge | existing refinement and region rules, with general retained-owner support |
| dynamic event fields, available capacity, reset outcome | generated or bound runtime checks with exhaustive outcomes; no success witness on failure |
| preparation and hardware publication | checked access through the operation API plus the reviewed encoding/cache/Cycle/notification implementation; an arbitrary state-returning function signature is insufficient |
| actual device completion/quiescence and platform visibility | explicit trusted observation and target implementation, never inferred from the model verdict |
| bounded Safety verdict | model evidence only; not an unbounded theorem or a compiler assumption |

Unsupported predicates, unbound observations, resource drops/duplication,
arbitrary external state constructors and actions with no lowering must be
rejected. A bare sequence of state labels or erased views is not the selected
B+C implementation. User-space asynchronous transfer uses the same resource
and transition mechanism, without xHCI-specific storage rules. General Z3
integration is unnecessary for this scope.

## Implementation order and Territory A handoff

1. B defines the shared protocol representation and declaration diagnostics,
   coordinating with A's lockless-log consumer so there is one generator.
2. A supplies general nested region retention, checked field moves and borrow
   expiry, plus an additive exclusive backing-storage boundary. Existing
   Place support and legacy region_of are not substitutes for those gates.
3. B generates the retained-owner permission API and TLA+ from the same
   declaration, then exercises real protected accesses in positive and
   negative compiler tests. A generated API that cannot retain its region
   does not finish this step.
4. B extends the model to wrap, request/session correlation, event snapshots,
   recovery and context obligations, then migrates the maintained driver.
   Driver/cache tests and measured space complete the consumer stage.

The substrate probes above still reject nested retention and accept raw
backing-array mutation. Until those general capabilities are available, the
first bounded model and this declaration contract are completed design work;
the generated ownership API and xHCI migration remain unfinished. The
handoff is a dependency on common memory capabilities, not a request for a
DMA-only exception or permission to count state-only tokens as completion.
