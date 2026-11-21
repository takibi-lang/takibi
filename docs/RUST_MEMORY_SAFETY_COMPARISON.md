# Scoped memory-safety comparison with Rust 1.91.0

Evidence reviewed on 2026-11-19 at Takibi `6a364041f`. The fixed Rust
baseline is stable 1.91.0, compiler revision `f8297e351`. The comparison
covers ordinary safe Rust with `core`, safe APIs whose implementations
use unsafe operations, and the additional premises at raw kernel and
device boundaries. Each verdict applies only to the property and scope
in its row. Whole-kernel and whole-language equivalence are unresolved.
The comparison uses published source, recorded checks, and the small
controls below. It includes no performance or hardware measurements.

| Property | Scoped verdict | Remaining boundary |
| --- | --- | --- |
| Array and slice bounds | Comparable for valid ordinary arrays and slices. Rust indexing checks the bound and `get` reports failure explicitly. Takibi can require static discharge where the maintained build rejects residual traps, a static requirement beyond ordinary Rust indexing in that subcase. [Rust slice indexing][index] | Unsafe slice construction on either side still depends on live storage, extent and alignment. [Rust raw slices][raw-slice] |
| Initialization of typed locals | Comparable for ordinary typed locals. Rust checks definite initialization. Takibi checks the finite leaves or intervals it tracks, including complete counted fills. [Rust borrow checker][borrowck] | External writers, recycled storage and raw initialization assertions need separate evidence. [Rust `MaybeUninit`][uninit] |
| Padding and initialized prefixes | Takibi can enforce an explicit initialized byte range or count-dependent prefix on supported paths. Rust typed initialization alone leaves padding outside that guarantee. Safe Rust can construct an initialized byte buffer for the same output. [Rust `MaybeUninit`][uninit] | Published statfs, sysinfo, uname, prlimit64 and signal fixtures observe only their specified successful bytes or extent. Complete exports and TCP received-prefix transfer are unresolved. |
| Selected storage | Comparable for the demonstrated current-owner or same-slot case. Takibi checks the selected storage in supported lease paths, including the checked Pipe fields. A valid Rust typed value still needs the pool API's handle-to-object invariant. [Rust borrow checker][borrowck] | Slot mint freshness, exclusivity, physical correspondence and Pipe buffer contents across wrap and reuse are separate premises. |
| Representation, alignment and provenance | Comparable for ordinary typed values with checked construction. Arbitrary raw conversions remain unresolved. [Rust raw slices][raw-slice] [Rust pointer contracts][pointers] | References and slices require valid storage. Integer addresses, FFI, raw physical memory and backend placement retain their own premises. |
| Aliasing and write footprints | Takibi's checked direct-call separation and bounded concrete heap checks have narrower coverage than Rust's ordinary safe reference rules. [Rust borrow checker][borrowck] [Rust `Sync` and interior mutation][sync] | Stored and indirect aliases, integer addresses and raw hardware aliases are outside the compared Takibi evidence. |
| Lifetime and reclamation | Comparable for the demonstrated direct helpers and indexed owner-derived views under their named premises. General Takibi reclamation coverage remains narrower than the ordinary Rust ownership comparison. [Rust borrow checker][borrowck] | Legacy Takibi `@` contracts, shared backing and raw views need specific evidence. Either language depends on the correctness of custom allocators and unsafe abstractions. |
| Reuse and freshness | General verdict unresolved. Ordinary Rust borrowing constrains live references to the owner lifetime. Takibi ties supported initialized byte facts to the current ownership interval and requires all 4096 bytes at fresh user page publication. [Rust borrow checker][borrowck] | Physical frame mint identity, retained fork/COW references, old COW source lifetime and shared teardown remain separate from fresh destination initialization. |
| Concurrency and preemption | Takibi's guard identities and selected bounded code/model ties have narrower coverage than ordinary safe Rust thread sharing and transfer under sound abstractions. [Rust `Sync`][sync] | Interrupt and preemption transitions, raw kernel scheduling, publication and reclamation require independent evidence. |
| Devices and visibility | Integrated device behavior remains unresolved on both sides. Takibi checks selected ownership and completion lengths, including modern virtio block completion. Rust volatile operations supply no thread synchronization. [Rust pointer contracts][pointers] | Physical completion, DMA and cache ordering, walker visibility and cross-core instruction first use are separate from initialized CPU-visible storage. |
| Independent checking | Takibi has an independent check for selected extracted arithmetic and finite obligations beyond the ordinary rustc comparison. | This evidence depends on correct extraction and cannot validate an arbitrary supplied premise. Optional Rust model checking and interpretation tools are outside this baseline. |

The [contract inventory](MEMORY_SAFETY_CONTRACT.md) describes Takibi's
consumer coverage and premises. [User page publication](PAGE_PUBLICATION.md)
distinguishes fresh destination initialization from retained mappings and
physical visibility. The [trusted base](../TRUSTED_BASE.md) and [model
correspondence](../kernel/models/README.md) state the compiler and bounded
protocol evidence limits. The local TCP producer prefix can be expressed
in the demonstrated subset. Its transfer through the current frame's
slot and later reacquisition is unresolved in the maintained path.

## Small compiler controls

Rust 1.91.0 rejected an uninitialized local read (E0381) and a borrow
used after its local owner went out of scope (E0597). Two safe Rust
programs ran successfully. One used `split_at_mut` to write to disjoint
parts of an array. The other encoded a record explicitly into eight
initialized bytes, leaving the three reserved bytes zero.

In optimized x86-64 objects, Rust's eight-element array lookup with a
plain `usize` index retained a bounds check and panic path. A private
`u8` newtype with a checked constructor still retained that path in
the separately inspected lookup. Combining construction and lookup in
one function preserved the input range check and eliminated the separate
indexing panic. An eight-variant `repr(u8)` enum produced a lookup with
no bounds check. Takibi accepted the lookup with a `{0..<8 as usize}`
parameter and emitted no bounds check. The plain `usize` Takibi variant
was rejected under the default trap policy. These controls compare
specific encodings and generated code, with no timing or broader
inference verdict.

Rust baseline sources are pinned to the [1.91.0 release][release].

[release]: https://github.com/rust-lang/rust/releases/tag/1.91.0
[index]: https://github.com/rust-lang/rust/blob/1.91.0/library/core/src/slice/index.rs
[raw-slice]: https://github.com/rust-lang/rust/blob/1.91.0/library/core/src/slice/raw.rs
[uninit]: https://github.com/rust-lang/rust/blob/1.91.0/library/core/src/mem/maybe_uninit.rs
[borrowck]: https://github.com/rust-lang/rust/blob/1.91.0/compiler/rustc_borrowck/src/lib.rs
[pointers]: https://github.com/rust-lang/rust/blob/1.91.0/library/core/src/ptr/mod.rs
[sync]: https://doc.rust-lang.org/1.91.0/core/marker/trait.Sync.html
