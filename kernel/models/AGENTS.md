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
- Keep the action table current. `scripts/check_model_function_map.py` fails
  when a function it names no longer exists.
- Run `make modelcheck`.
