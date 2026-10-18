# Litmus tests for the kernel log's memory ordering (GitHub issue #645)

STATUS: WORK IN PROGRESS. The verdicts in expected.txt have not yet been run
through herd7 (the pinned herdtools7 build is not yet working), and the
check that ties each test to the compiler's emitted instructions is not yet
written.

Each test is the two-thread message-passing shape of one ordering claim in
kernel/printk/log.tkb (#612), with unfixed controls that weaken one access.

| Test | P0 (core 0, writer) | P1 (reader, any CPU) |
|---|---|---|
| LogPublish | `kernel_log_capture_retained_byte`: STLR text word (`kernel_log_text`), then STLR length (`kernel_log_lengths`), both via `kernel_log_publish` | `kernel_log_snapshot_record`: LDAR length, then LDAR text word, via `kernel_log_observe` |
| LogReuse | record begin: STLR `kernel_log_started` FIRST, then STLR a slot word | `kernel_log_snapshot_record`: LDAR the slot word, then LDAR `kernel_log_started` for the re-check |

Unfixed controls: `+unfixed-writer` makes P0's second store plain (STR);
`+unfixed-reader` makes P1's first load plain (LDR). herd7 must then allow
the outcome the fixed test forbids.
