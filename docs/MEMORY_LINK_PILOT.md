# Source-derived linked-initialization experiment

Experiment date: 2026-11-16. This is research evidence, not shipped language
semantics or a kernel-wide memory-safety claim.

## Question and result

Can the shared FreelistCore add/pop operations preserve initialization safety
with runtime-selected indices, without clearing unused metadata first?

Yes, under the sequential storage/frame assumptions below. An OCaml research
checker uses Takibi's existing parser to read the actual bodies in
`kernel/lib/freelist.tkb`, builds path conditions and memory updates, and emits
SMT queries. It does not recognize source text with regular expressions.
The input SHA-256 was
`70ad38f871c33dd3e5940329758d7d4f695fa80799f3ca364b70ed2051fb348b`.

The checked property is initialized, in-range traversal, not acyclicity,
unique allocation, correct generation ownership or concurrency safety.
A certified set of initialized indices is closed under stored links; its
head is a member or the sentinel. This set need not include every physically
written cell. An empty list can certify the empty set without clearing its
unused array.

## Evidence

Capacity N and the inserted/returned index are symbolic unsigned-64-bit-range
integers. No enumeration of pool sizes, indices or initial array contents is
used. Array reads require initialized in-range elements; stores require
in-range indices. Function exits preserve the linked invariant.

| Actual bodies composed by the harness | Source paths | Solver result |
| --- | ---: | --- |
| add_index | 2 | UNSAT |
| add_index -> insert_begin -> insert_commit | 8 | UNSAT |
| init_empty | 1 | UNSAT |
| init_empty -> add_index -> insert_begin -> insert_commit | 8 | UNSAT |
| remove -> insert_begin -> insert_commit | 8 | UNSAT |

UNSAT means no violating execution in the encoded sequential semantics.
The init_empty sequence starts with no initialized array cells and does not
assume an initially valid linked invariant. The other sequences require that
invariant at entry. Additional checks fixed N to 0 and to the real bootstrap
capacity 2048; both passed. Individual queries took 0.008-0.015 seconds in
this local run, not a performance budget or scaling guarantee.

Four mutations of the actual input source produced SAT:

- omit the add_index link write;
- change the add_index bound from index < N to index <= N;
- construct Pending with index 0 instead of the head actually read;
- omit the remove link write.

Adding an unsupported real helper call failed extraction explicitly rather
than silently omitting its effects.

## Relevance to the kernel

The bootstrap path in `kernel/mm/page.tkb` uses FreelistCore with capacity
2048. `kernel/lib/slotmap.tkb` and `kernel/lib/refcount_slotmap.tkb` also use
its insert/remove operations. Those consumers make the shared core a better
applicability test than the native-only GrowablePool constructor alone.
Their complete call graphs were not verified. In particular, the bootstrap
consumer's full ascending initialization and its transition to runtime page
metadata are not covered by the init_empty sequence.

## Boundaries and remaining work

- The harness composes named bodies; it does not derive the entire caller
  graph from the wrapper's match expression. begin/commit operate on the
  same storage with no intervening mutation by another execution context.
- Storage identity, exclusivity, alias/frame behavior and lifetime are
  premises. The intentionally unsafe contention-probe API is not certified.
- Small helpers for owner-index projection, pending construction, owner
  construction and generation advancement have explicit research summaries.
  Payload ownership correctness is outside this property.
- The 112-line OCaml extractor supports the exact selected statement forms
  and fails on unsupported forms. It is not a general symbolic interpreter,
  type checker or independently verified compiler.
- The solver uses quantified mathematical arrays and integers. This is NOT
  the production policy where the compiler owns structural rules and Z3
  discharges pure arithmetic obligations. Translating the structural fact
  into the approved restricted type/contract domain is unfinished.
- Zero source annotations in this experiment do not establish zero proof
  cost: the harness supplies the invariant, composition and helper summaries.
  The final user-visible annotation cost is still unmeasured.
- No runtime clearing, bitmap, extra link word or unsafe initialization
  assertion was added. These results give no present reason to add them for
  this sequential add/pop property.

The next acceptance bar is to carry this guarantee through real checked API
contracts, reject the same four defects in the compiler, and apply it at a
maintained kernel caller. Kernel-wide applicability remains unestablished.
