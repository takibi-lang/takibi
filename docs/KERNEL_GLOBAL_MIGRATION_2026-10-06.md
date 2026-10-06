# Kernel global migration space review, 2026-10-06

Baseline: c5fc29971b07d95789808cb1cc3ac867e767cb8b. Candidate: the FD fallback
deletion and closed boot states in this change. Standard QEMU and RPi5 linked
kernels, same toolchain and normal `make kernelbuild` targets; no debug or
benchmark ELF. No allocator layout, pool retention or workload capacity changes.

| Platform | Text before / after | Data before / after | BSS before / after | Reserved span before / after |
| --- | ---: | ---: | ---: | ---: |
| qemu | 707444 / 706620 | 5062 / 5022 | 1668464 / 1667904 | 2392064 / 2392064 |
| rpi5 | 715988 / 715164 | 2888768 / 2888728 | 1705120 / 1705120 | 5341184 / 5341184 |

Commands: `llvm-size-19 kernel/build/{qemu,rpi5}/kernel.elf` and
`llvm-nm-19 --print-size` on each ELF. Reserved span is
`usable_ram_start - _start`, not file size. Both reservation deltas are zero.

Three obsolete FD payload symbols (400, 72 and 80 bytes) disappear. The six
old boot-state symbols total 170 bytes; the private BootExecutionContext is
184 bytes. The targeted symbol payload therefore falls by 538 bytes, while
closed tags cost 14 bytes relative to the old boot symbols. QEMU total BSS
falls by 560 bytes; RPi5 BSS is unchanged because other alignment absorbs the
difference. Text falls by 824 and data by 40 bytes on both targets. These are
distinct accounting boundaries, not additive claims of page savings.

A tracked-tree consumer search found no FD fallback consumer beyond dated
inventory documentation. Both linked symbol tables confirm all three payloads
and six old boot bindings are absent. The live missing-release diagnostic stays.
Boot plan backing remains permanent; no buffer is copied into the context.
The closed states prevent absent payload extraction and independently mutable
image tuple members, but do not prove boot ordering or single-mount publication.

The refactor also removes the two in-memory ELF mapping wrappers whose only
callers were unreachable fallback branches in the old boot/exec paths. The
unused-function compiler gate exposed them; ext2 mapping and shared mapping
implementation remain. No supported boot or exec feature is removed.

Assessment: adopt this inexpensive deletion and invariant improvement. Retain
all other reviewed global categories for current functionality (YAGNI); no
blanket structural grouping, cache padding, new locks or mount registry.
Existing pool endpoint and cross-OS allocation evidence remains applicable
because this change does not alter allocation shape. Full bounded boot/exec
behavior is validated by the publication allcheck, separately from linked space.

Next measurement trigger: a completed kernel feature/stage, new mount/device
lifetime, pooled resource or cache/allocator layout change.
