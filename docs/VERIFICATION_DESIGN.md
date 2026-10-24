# Verification design: initialization contracts (draft)

GitHub issue #954, step 2 (thin vertical slice). Status: PROPOSAL awaiting the
maintainer's approval of the syntax and semantics skeleton. Nothing here is
implemented yet; this file grows with the slice.

## Census of today's workarounds (kernel, origin/main a17c1028)

Compiler `zero_fill(...)` sites: 17 (the other 11 grep hits are
`user_zero_fill`, a user-memory store, and its definition).
`unsafe { assume_init(...) }` sites: 4. `borrow uninit` parameters: 0.
Shapes (provisional, read from the surrounding 15 lines):

| Shape | Sites | Count |
|---|---|---|
| Partial fill of a staging buffer by a callee, partial copy-out | syscall.tkb 2138, 2338, 2624, 3566, 8207, 8371, 4405 | 7 |
| Disjoint sub-slice stores that cover the buffer | syscall.tkb 6039 (rlimit) | 1 |
| Zero is the meaning (NUL tail, ABI padding, cleared frame) | syscall.tkb 947, 983, 1953, 5997, 6127, 8469; frame_ref.tkb 177 | 7 |
| Default value for a path that never fills (struct, not array) | process.tkb 2318 | 1 |
| Cross-function scratch staging, `assume_init` | syscall.tkb 575, 586, 597, 1941 | 4 |

The zero-is-the-meaning sites stay. The others are the slice's targets.

## Proposed skeleton

See the #954 decision comment for the syntax options; this section is
filled in once one is chosen.
