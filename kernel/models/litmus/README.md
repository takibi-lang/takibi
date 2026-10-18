# Litmus tests for the kernel log's memory ordering (GitHub issue #645)

`make litmuscheck` (a prerequisite of `make modelcheck`, so in allcheck and
CI's cicheck) runs herd7 over every test against expected.txt, then ties the
fixed tests to the RPi5 kernel object through emitted_map.txt
(scripts/run_litmus_checks.py). herd7 comes from opam: herdtools7, pinned in
.devcontainer/devcontainer.json and .github/workflows/ci.yml, which
scripts/check_herdtools_pin.py keeps equal. A pass is bounded evidence: the
AArch64 model says the two-thread shape is forbidden, and the lint says the
named functions use those instructions; it does not prove the Takibi code
has no other ordering dependency.

Each test is the two-thread message-passing shape of one ordering claim in
kernel/printk/log.tkb (#612), with unfixed controls that weaken one access.

| Test | P0 (core 0, writer) | P1 (reader, any CPU) |
|---|---|---|
| LogPublish | `kernel_log_capture_retained_byte`: STLR text word (`kernel_log_text`), then STLR length (`kernel_log_lengths`), both via `kernel_log_publish` | `kernel_log_snapshot_record`: LDAR length, then LDAR text word, via `kernel_log_observe` |
| LogReuse | record begin: STLR `kernel_log_started` FIRST, then STLR a slot word | `kernel_log_snapshot_record`: LDAR the slot word, then LDAR `kernel_log_started` for the re-check |

Unfixed controls: `+unfixed-writer` makes P0's second store plain (STR);
`+unfixed-reader` makes P1's first load plain (LDR). herd7 must then allow
the outcome the fixed test forbids.
