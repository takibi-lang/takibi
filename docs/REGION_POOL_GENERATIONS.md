# Region pool generation lifetime

A RegionPool issues a new nonzero generation for every successful allocation,
under its existing guard. The counter belongs to the pool body, not a chunk,
and survives releasing every chunk. It never wraps: after `2^46 - 1`
allocations, `RegionPoolAlloc(T)::Exhausted` permanently refuses allocation.
`Full` consumes no stamp. All existing handles and release operations remain
usable at the limit. This budget is pool-wide, not per slot.

Retirement changes Live to Dying/Out without incrementing the generation.
The last holder gets indexed linear `RegionReleaseSlot(T)`, which can only
be adopted for release, freed, or abandoned with memory retained. It cannot
be published or used to access the element. Adoption preserves this type.
A retired slot must be freed and allocated again before it can be published;
that allocation receives a new stamp. Ordinary take/give retains the same
allocation identity, as before.

The pool is also `no_copy`, preventing whole-value snapshots and replacement
from duplicating or rewinding its durable allocator state.

The ownership distinction is checked at compile time using existing indexed
linear structs. The counter, state transitions, and raw page-region minting
remain in the trusted boundary. Executable tests are evidence for that
implementation, not a static proof of its arithmetic. Generations are scoped
to the selected pool's lifetime; numeric address/generation pairs do not
encode a global pool identity.

## Regression evidence

`linux_user/region_proto` releases and regrows the same exclusive page four
times. Old numeric handles must fail both take and pin, while the new handle
must work. A test-only, checked three-word layout overlay injects a counter
one allocation before exhaustion into a private empty pool. It verifies that
Full consumes no stamp, the final stamp works, retirement/free work at the
limit, and shrink/regrow does not reset exhaustion. This white-box injection
is confined to the native fixture and is not a production allocator API.

The same-address regression, adapted only for the old result names and layout,
prints `regrow: old take accepted` under the compiler at eba92f10. The corrected
fixture prints its successful four-incarnation result. Compiler rejection
cases cover publication after retirement, after last unpin, and after adopting
a release-only slot; existing cross-pool ownership tests still apply.

Permanent region tables have no chunk teardown and keep their separate
per-slot generation representation. The intrusive process pool already uses
a pool-global allocation counter. Their eventual generation-wrap policies are
separate from the same-address chunk reincarnation fixed here.

## Space observations, 2026-10-05

One RegionPool body grows from 16 to 24 bytes. Its slot word stays eight
bytes, its chunk header stays 24 bytes, and handles and pins do not grow.
The eight direct production RegionPools add 64 bytes in total; with the
104-byte intrusive process pool, direct production pool bodies total 296
bytes instead of 232. The private pin-sharing fixture also has a RegionPool.

FD entries remain 24 bytes and FD blocks remain 400 bytes, compared with
32/528 before their field reorder. Nine FD blocks still save 1152 requested
payload bytes; deducting all eight production pools' extra words leaves 1088
bytes on that payload-plus-pool-body accounting boundary. This is not a
reduction in allocated physical RAM: unchanged chunk counts keep the same
reserved pages even when more payload fits inside them.

[Linked layout observations](REGION_POOL_LAYOUT_2026-10-05.tsv) compare the
standard QEMU and RPi5 kernels before the FD reorder, after it, and with the
nonrepeating counter/release-only API. The [provenance](REGION_POOL_LAYOUT_2026-10-05.json)
records the baseline commits and implementation hashes. All builds use the
same toolchain, page geometry, and standard targets; debug and special workload
images are excluded.

| Platform | Text delta vs before FD reorder | Unwind delta | Static BSS delta | Reserved image delta |
| --- | ---: | ---: | ---: | ---: |
| QEMU | +3728 | +2096 | -16 | 0 |
| RPi5 | +3776 | +2056 | 0 | +32768 |

Read-only data grows 48 bytes on each platform. Direct pool bodies' logical
64-byte increase is not the entire BSS delta: alignment, FD fixture data,
and other linked static placement also contribute. The reserved span is
`usable_ram_start - _start`, including stack reservation and alignment, rather
than the ELF file size. RPi5 crosses a 32 KiB stack-alignment boundary; QEMU
does not. The board boot expectation therefore has eight fewer allocator
pages (259304 instead of 259312). No image ceiling is raised.

The FD payload reduction remains valid, but these measurements do not show a
whole-kernel reserved-memory reduction. Code and unwind information have a
fixed cost, and chunk capacity savings depend on the workload. Production
empty-chunk retention remains one; its measured timing tradeoff is unchanged
as historical evidence, not a timing measurement of this new implementation.

The [QEMU endpoint sample](REGION_POOL_ENDPOINT_2026-10-05.tsv), from the
68-view bounded boot, confirms 24576 chunk bytes and 296 production pool-body
bytes at both endpoints: 24872 combined. The earlier nine-pool baseline was
24808, so that reservation boundary increases by 64 bytes, despite the
smaller FD payload. This sample excludes the fixed kernel image and all
other allocations, and is not a peak measurement.
