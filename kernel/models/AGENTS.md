# TLA+ models

Read `kernel/models/README.md` before adding or changing a model. It holds how
models are written, where one model ends and the next begins, and the action
table that maps each model action to the kernel functions it abstracts.

The rules an edit must keep:

- Plain TLA+ with Apalache `@type:` annotations, not PlusCal.
- One action per kernel critical section. A window between two critical
  sections is two actions.
- Every model has a fixed and an unfixed variant; the unfixed one must
  violate its property. Add a new model to `scripts/run_model_checks.sh`.
- Keep the action table current. `scripts/buildcheck_model_function_map.py` (run by
  `make kernelbuild`, on both kernels' call-graph tables) fails
  when a function or action it names no longer exists, or when a dropped
  path does not say why leaving it out is safe, in one of the three forms
  the README's "The dropped column" defines.
- A change to a function a row maps fails the same check until the row is
  re-read against the model and restamped with `make model-map-restamp`. Say in the
  commit what was reviewed.
- A passing variant takes every action of its spec; `make modelcheck` fails
  on one never taken. Allow-list in `coverage_allow.txt`, with the reason,
  only an action dead by design in that variant (#802).
- Run `make modelcheck`.
