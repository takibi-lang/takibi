# Online-prefix AtomicWord migration, 2026-11-09

The workload is the standard production linked QEMU and RPi5 kernel, compared
with published base `7e6653707d6de83fb56dd1541e50a3eff158aeaa` built in the
same worktree and toolchain before the source edit. No guest or hardware run
was used for this linked-space review. Existing boot occupancy evidence remains
applicable: no allocator, pool, resource lifetime or reservation changes.

| Boundary (bytes) | QEMU before | QEMU after | RPi5 before | RPi5 after |
| --- | ---: | ---: | ---: | ---: |
| llvm-size text (includes readonly data) | 822824 | 822824 | 4207428 | 4207428 |
| data | 4632 | 4632 | 5608 | 5608 |
| BSS | 1318912 | 1318912 | 1933312 | 1933312 |
| executable .text section | 645024 | 645024 | 688676 | 688676 |
| private counter payload | 8 | 8 | 8 | 8 |
| usable_ram_start address | 0x40210000 | 0x40210000 | 0x7e0000 | 0x7e0000 |

Every `llvm-nm -S` symbol address, size and kind is identical before/after on
both targets. Image reservations and retained pages do not change; no page is
freed. The changed .text words are exactly four instructions per platform:
clear's `str` becomes `stlr`, note's `ldr`/`str` become `ldar`/`stlr`, and
count's `ldr` becomes `ldar`. All other executable bytes are identical.
The count function remains 40 bytes, note 52 bytes and clear 84 bytes.
There is no extra call, lock, CAS loop or barrier instruction. This measures
instruction shape, not cycle latency or physical coherence.

The compiled count accessor has 49 direct calling functions on QEMU and 50
on RPi5, including `kernel_process_online_mask`, UART/NIC affinity, profile
hooks, probes and DDB; the additional RPi5 caller is xHCI reporting. Each
executed count call now performs an acquire load in place of its plain load.
All caller instructions remain byte-identical. CPU 0 alone clears and updates
the prefix via main -> report -> attempt -> note; clear is called by report.
The existing compiled caller checker verifies these four closed rows on both
targets, including its planted call, function-value and removed-call controls.
Both boot assembly entries initialize the MMU before entering main; neither
writer is a pre-MMU path. The main entry's CPU-0 selection and one-shot boot
execution remain trusted, as documented in TRUSTED_BASE.md.

The status-zero, core-equals-prefix, below-maximum predicate and the inclusive
read bounds with fallback one are unchanged. A successful PSCI status admits
a conservative prefix before the target handshake; this is not proof that
the target has reached Takibi. World-stop possible-participant membership,
including uncertain or sparse targets, remains independent and unchanged.
Acquire/release orders accesses when the acquire observes the release; the
comparison and store are not a multiwriter atomic read-modify-write.

Maintained regression coverage is the existing secondary layout/source check
and its 21 controls, plus the actual two production kernel builds and compiled
caller checks. The controls reject changed atomic storage/access, status,
ordering, increment, maximum, read bounds, fallback, extra writers and caller
admission. They hold bounded source premises, not arbitrary program semantics.
A one-time native diagnostic compiled the actual extracted declarations and
clear/note/count bodies verbatim with the actual AtomicWord module. Only the
two unrelated pool-initialization callees were empty providers. Its 14 cases
passed: zero and above-max fallback, clear to one, nonzero and PSCI-negative
status, out-of-order success, consecutive successes, duplicate/gap/core-zero
refusal, at-max retention and invalid stored-prefix refusal. This is one-time
sequential policy evidence, not a maintained executable regression or a
cross-CPU ordering test. The diagnostic script/source/startup/object/executable
and hashes are retained outside the tracked tree, with the build receipts.

The first diagnostic compile failed because extraction stopped at the array
length separator; it was corrected to extract the complete declaration line.
That failed receipt remains failed. A premature baseline copy attempted before
the QEMU link existed was retried only after the baseline build exited zero;
the complete successful pair below is the comparison input. An initial ad-hoc
CSV reader omitted the callgraph format header; the measurement uses the
repository's call_graph_table reader instead. Neither failed attempt supplies
measurement evidence. No product behavior defect was discovered in this slice.

The first full host run at `1f897799` exited two: the controls' new in-process
import lacked the existing source_scan.per_file convention. The first full
slowcheck also exited two because relayout's plain-copy run reached that same
cache-policy gate. Focused controls did not include the separate integration
policy. The correction caches online_problems by both semantic inputs (source
text and caller-table text), returns an immutable tuple, and reads no file or
ROOT inside that helper. This is a Python check-integration defect, distinct
from kernel behavior. No exemption was added. Replacement full host and
slowcheck gates are required; the failed receipts stay failed. Only the
checker and this report change after that head, so the production fingerprint
and measured ELF inputs remain unchanged.

SHA256 of linked production inputs and results:

| Target | Before | After |
| --- | --- | --- |
| QEMU | `4935e2cae06840c787709d9e485a1e105b33ab64cdbacbff8b75cc1f55faba4d` | `5f9240a727255d4aeb31538a23cd8544e64d22f041617bdb2a30dd23ad0bbf5d` |
| RPi5 | `a7c71b1a6cb5a3e265cdf0fa103f6883874302da2fcaeef4ab6dfe5a05945c2c` | `a9b5bbc7b9164499869d95b26d30d8f3e5d334e566f39eb6941ae181f1862534` |

Assessment: adopt the existing atomic type at unchanged payload, linked space
and instruction count. Sole-writer confinement stays a checked/trusted boot
boundary rather than a new language guarantee. The untyped allowance is
removed, and the ledger separately records the bounded source-policy premise.
No model or compiler extension is needed for this unchanged boot protocol.
Next measurement trigger: another resource/lifetime or allocation-workload
change, or completion of the next kernel feature/stage. Physical validation
and complete integration remain the coordinator's natural-boundary land work.
