# Guarded protocol shadow storage: measured milestone

The process/core trace shadows use two private `no_copy` wrappers with one
`guarded_by(scheduled_process_run_lock)` array field each. Seven APIs borrow
and forward the existing run guard; direct indexed scalar access uses
`guarded_ref`. No new lock, mint, heap allocation, region, event representation
or protocol step is introduced. The event buffer is a separate closed-window
reporting boundary and is not migrated here.

Whole-wrapper copying and replacement are forbidden by existing `no_copy`.
Identity pointers remain legal; using their guarded fields still requires the
matching guard. The previous ordinary-wrapper copy acceptance is consistent
with ordinary structs being copyable, not evidence of a new compiler rule.
Existing private guard construction and its physical mutex hold remain
trusted. Types do not establish event-window closure or whole-protocol replay
correctness.

## Measurement boundary

Baseline is published GREEN `4eea42a7615cf0d2fe0fdf685bd992bab2922eec`.
Original normal/debug objects and linked ELFs were copied from the published
archive and hash-verified before inspection. Candidate objects, facts and ELF
hashes are recorded in `PROTOCOL_SHADOW_SPACE.json`. Both current platform
normal/debug globals tables classify the two declarations as `composite`.
Each actual wrapper has one member, `rows` at offset 0: process shadow
3072 bytes (64 x 48), core shadow 64 bytes (4 x 16). Neither grows.

| Linked production boundary | QEMU before | QEMU after | RPi5 before | RPi5 after |
|---|---:|---:|---:|---:|
| text bytes | 644912 | 644928 | 688644 | 688708 |
| unwind bytes | 122920 | 122928 | 133632 | 133640 |
| .data bytes | 136 | 136 | 336 | 336 |
| .got bytes | 4480 | 4480 | 5256 | 5256 |
| BSS bytes | 921600 | 921600 | 1536000 | 1536000 |
| process shadow bytes | 3072 | 3072 | 3072 | 3072 |
| core shadow bytes | 64 | 64 | 64 | 64 |
| usable RAM start | 1075904512 | 1075904512 | 8257536 | 8257536 |

All other linked section sizes, including GOT and read-only storage, are
unchanged. There are no data/BSS/read-only symbol-size changes. Shadow symbol
addresses are unchanged. The linked text increase is 16/64 bytes: changed
function bodies sum to 12/52 bytes, and alignment adds the remaining 4/12.
GOT/data section addresses shift by 8 bytes with unwind, without growth.
Object section sizes change only for those five bodies and unwind (+8 bytes
on each target); relocations/addresses move with the bodies, without a new
relocation-section size or storage section. Debug types describe wrappers
rather than bare arrays; no tracked debugger consumer of these shadows was
found. Untracked debugger expressions are not guaranteed compatible.

| Production function bytes | QEMU before/after | RPi5 before/after |
|---|---:|---:|
| process observer | 596 / 592 | 588 / 628 |
| trace open | 92 / 100 | 92 / 100 |
| observe core | 108 / 92 | 104 / 92 |
| observe process | 268 / 252 | 252 / 228 |
| opening probe | 204 / 244 | 204 / 244 |

Passing the existing guard occupies an argument register and shifts payload
arguments. Open adds guard forwarding at prepare/commit; the opening probe
retains and forwards the guard across its existing calls. Register allocation
also changes the observer bodies, differently for the two target CPUs. These
are instruction/image costs, not measured physical cycles or cache effects.
There is no new runtime guard validation or per-element atomic operation.

The actual debug linked text grows by 80 bytes on QEMU and 96 on RPi5. Debug
read-only/data/GOT/BSS and unwind section sizes are unchanged; nonloaded
debug metadata changes with wrapper types and shifted source lines. No
production image conclusion is inferred from debug-file byte size.

## Frames and retained allocation

Actual prologues, including hexadecimal pre-index adjustments, give these
frames identically on QEMU and RPi5:

| Function | Production before/after | Debug before/after |
|---|---:|---:|
| prepare open | 16 / 16 | 16 / 32 |
| commit open | 16 / 16 | 32 / 48 |
| opening probe | 32 / 32 | 32 / 32 |
| pass begin | 16 / 16 | 16 / 32 |
| observe process | 16 / 16 | 32 / 48 |
| observe core | 0 / 0 | 0 / 32 |
| pass end | 80 / 80 | 96 / 112 |
| process observer | 160 / 160 | 224 / 224 |
| trace open | 32 / 32 | 48 / 48 |

The maintained frame checker misses hexadecimal pre-index `stp` adjustments;
its raw results were retained and corrected only in the external measurement.
No checker or budget was weakened or changed. This is single-frame accounting,
not a whole-callgraph stack bound. Debug forwarding has a real 16-32 byte
helper-frame cost; production frames do not grow.

Global payload, retained pages, pool metadata, pool reservation, allocation
operations and usable RAM start are unchanged. Existing bounded-boot occupancy
evidence is reused only for that unchanged allocation/lifetime workload; no
new workload capture or Linux/FreeBSD comparison is claimed. No usable page
saving is claimed. Adopt the small measured image/debug-frame cost to enforce
the existing typed guard boundary. Next measurement trigger: another completed
feature or a change to shadow dimensions, event representation, guard passing,
stack call structure or retained allocation/lifetimes.
