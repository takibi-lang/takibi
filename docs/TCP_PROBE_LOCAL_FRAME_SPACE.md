# Pending TCP probe local storage review (2026-11-10)

The standard pending TCP chain probe now owns a 1514-byte local array for
one invocation. A constant-bound loop writes zero to every element before
any use. The three existing calls pass it to `pending_tcp_record` through
its existing borrowed slice parameter. That function copies all 1514 bytes
into the owned retransmit entry when `kept_slot == NET_KEPT_NONE`; it returns
only the entry address, not a view into the source. The body returns bool.
The kept-slot branch, chain order, interleaved connection, cleanup and
retained empty chunk checks are unchanged. No API or lock representation
changes, extra pool, heap allocation or fixture exemption is introduced.

## Measurement

`TCP_PROBE_LOCAL_FRAME_SPACE.json` records actual normal/debug objects and
linked images for both platforms, their hashes, section sizes, every changed
symbol size and full-body SP-changing instructions for the selected function.
The independent published baseline is commit 90224091, whose production
fingerprint also matches the documentation-only a28ee175 starting tree.
The archive manifest was verified before copying the eight published artifacts;
normal and debug identities are kept separate. Debug file bytes include
worktree path/debug information and are not a runtime allocation measure.

| Platform/image | Selected frame before/after (B) | Object text delta (B) | Linked text delta (B) |
| --- | ---: | ---: | ---: |
| QEMU normal | 256 / 1808 | +32 | +32 |
| QEMU debug | 416 / 1936 | +12 | +16 |
| RPi5 normal | 160 / 1680 | +28 | 0 |
| RPi5 debug | 288 / 1808 | +28 | +32 |

All four complete selected bodies allocate once with a 96-byte saving
prologue plus one fixed SP subtraction, and restore that amount at the common
return. They contain no later SP growth or dynamic allocation. Their largest
frame is 1936 bytes, within the unchanged 2048-byte per-function ceiling.
The full-body inspection supplements the general gate's limited prologue
window; neither is a whole-call-path stack proof. Nested callee frames still
add to the active stack. The existing fixed stack reservations are unchanged.

The exact 1514-byte `pending_tcp_probe_frame` BSS symbol and section disappear
in every object and image. Object BSS falls by 1514 bytes, but linked BSS
reservation sizes and every `usable_ram_start` boundary remain unchanged.
Each linked GOT loses one 8-byte entry; other linked data is unchanged.
Only the selected function changes symbol size. Linker alignment absorbs the
RPi5 normal function growth and rounds the other linked text changes as shown.
There is no claim of additional usable pages from removing the declaration.

## Workload and guarantees

The existing bounded boot chain probe supplies the workload: five entries for
one connection with another connection's entry interleaved, reset of each
connection, then reuse of the retained chunk and teardown. Its existing main
kernel view checks the chain verdict. No allocator workload, pool metadata,
capacity or retained-chunk policy changes. Prior allocator occupancy evidence
remains applicable at that unchanged boundary; this review measures the changed
permanent-global versus active-local lifetime and fixed images.

Existing definite-initialization and bounds checking establish that the local
bytes are initialized and the loop's stores are in range. The existing borrowed
copy boundary is used without an aggregate loan or nested-owner redesign.
Compiler/lowering correctness and the existing raw retransmit implementation
remain trusted; this is no new concurrency protocol or physical timing/cache
claim. Accept the measured active-frame/code cost for removing shared mutable
storage. Measure again if the buffer size, caller depth, copy API or allocation
workload changes, or at the next completed kernel storage milestone.
