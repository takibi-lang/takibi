# Native compiler soundness testing

`make compiler-fuzz` generates small Takibi programs, compiles each with
`--forbid-trap` for Linux/AMD64, links an independent C oracle, and executes
every accepted program. `make linuxcheck`, and therefore `make cicheck` and
`make allcheck`, includes this target. It requires the host `cc` command.

The short run uses seed 646 and 42 programs, cycling through seven families:
refined function parameters; chains of integer addition, subtraction and
multiplication with independently calculated intervals; fixed array reads;
slice reads; bounded loop writes and reads; both closed variant outcomes;
and inclusive upper-bound candidates. Sizes, constants, arithmetic chains
and additional inputs vary with the seed. Inputs include negative values,
zero, and values on either side of each range boundary. Arithmetic remains
far inside the i32 range, so the oracle does not depend on C overflow.

The C oracle checks returned results against the generator's mathematical
evaluation. It also checks each observed refined value against its promised
half-open interval. These checks execute outside Takibi, so Takibi's own
range reasoning cannot erase them. A signal, nonzero exit, result mismatch,
compiler internal failure, link failure, or command timeout fails the run.
Ordinary compiler rejections are recorded, with their diagnostics, rather
than failed. Syntax errors fail as malformed generation. Every ordinary
family must have an accepted, executed case; accepting nothing cannot pass.
`scripts/test_compiler_fuzz.py` runs native controls for acceptance, wrong
results, signals, timeouts, rejection logs, malformed generation, reduction
diagnosis preservation, and zero executed programs before the short campaign.

## Detection control

The short target additionally builds a compiler from the committed HEAD in
a fresh temporary directory. It changes only the synchronized `<=` upper
bound rules in the checker and code generator from `d` to `d - 1`. This
deliberately claims that an inclusive boundary is excluded. The main checkout
and its compiler remain untouched. A 14-program campaign must find an
accepted program that violates a refinement, with the specific oracle
diagnostic. A quiet campaign, an unrelated compiler failure, or only rejected
programs fails the control.

The failure is reduced by bounded line deletion, keeping the C inputs and
oracle unchanged. A deletion survives only if the smaller program compiles,
links and fails with the same diagnostic class. At most 64 deletion attempts
are made. The minimized result is replayed with the modified compiler; the
original compiler must independently reject it with a range-mismatch
diagnostic. Reduction is best effort, not a claim of global minimality.

Each subprocess has a five-second default limit. The normal short campaign
has a 60-second budget, checked between programs. The scratch build has a
120-second limit; the whole short Make target has a 180-second outer limit.
Exhausting a budget fails instead of silently dropping required cases.

## Longer runs and artifacts

```
make compiler-fuzz-long FUZZ_SEED=20261003 FUZZ_CASES=4000 FUZZ_SECONDS=600
```

The longer target omits the already gated scratch control. For direct use,
`python3 scripts/fuzz_compiler.py --help` lists the command and output bounds.
Generated sources, C oracles, compiler rejection logs, execution diagnostics,
and a JSON summary remain under the printed `_build/compiler-fuzz/` run
directory. A runtime failure also retains `minimized.tkb`. Keep the oracle
and the source together when turning a finding into a regression test.

This is bounded execution evidence, not a soundness proof. The initial subset
does not cover ownership, region handles, unsafe code, concurrency, other
integer widths, arithmetic overflow, division, or arbitrary syntax trees.
Hand-written compiler rejection tests remain necessary. Each real compiler
defect found needs its own diagnosis and faithful regression test.
