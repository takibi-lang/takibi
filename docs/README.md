# Documentation

This directory holds durable technical knowledge that should remain useful
after the issue or development session which produced it has ended.

- `compatibility/` records contracts with pinned external software. Each
  document identifies the exact artifact inspected, distinguishes required
  behavior from optional behavior, and states what change requires a new
  audit. `compatibility/METHOD.md` records how to establish such a contract,
  and the evidence ordering that applies to hardware bring-up as well.
- `BUILD_CHECKS.md` is the complete inventory of repository policy checks
  executed by `make langcheck`.
- `wont-compile/` is a catalog of kernel defect classes the compiler rejects,
  one entry per defect, each naming the test case that pins it. It is indexed
  by what goes wrong on the board rather than by language feature; `SPEC.md`
  stays authoritative for syntax and semantics.

Issue discussion remains useful for decisions and work status, but it is not
the canonical location for a current compatibility contract. Historical
events belong in `HISTORY.md`; current language behavior belongs in `SPEC.md`.
