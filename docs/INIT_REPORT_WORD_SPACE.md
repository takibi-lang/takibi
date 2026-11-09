# Init report display word: measured milestone

The completed migration materializes only the pure shell-code log projection
at the existing typed reaped callback. ProcessEnd, both callback callers,
wait4 and SIGCHLD retain their closed variants and implementations. This word
is not process status or a sentinel: zero is a valid displayed exit code.

## Source and protocol boundary

The private word has one store and one load in both actual compiler global
tables. The only writers remain the callback reached from deferred process
reaping and wait4 delivery. Its reported guard and reaper PID 1 guard are
unchanged. The projection store precedes the same release pending store.
The sole report path still requires pending acquire, current PID 1 and the
same successful pending 1-to-0 compare-and-swap, then sets reported. The word
is zero-initialized BSS and is never used to decide readiness. No field pointer
escape or alternate access is added. AtomicWord enforces typed cell access;
it does not prove projection correctness, publication, one-shot reporting or
the existing callback concurrency premise. Those remain trusted source facts.

The unchanged pure helper maps Exited(code) to code and Signaled(signal) to
128+signal. The mapping deliberately loses variant identity (Exited(143)
and Signaled(15) both display 143); no process state consumes that projection.
The maintained native wait_status executable exhausts both 256-value typed
payload domains, comparing projection before/after variant storage and
independently checking wait4 and SIGCHLD cases. Its existing 676 output bytes
remain identical after the new coverage line. Constructor masking and the
existing 18 host Linux oracle rows remain unchanged. Values above signal 127
are pure typed-domain tests, not delivered host signals.

The kernel prefix, unchanged decimal formatter and newline have identical
bytes. Existing shell_script views require `init script exit: 0`; the native
check covers other projection values without claiming 512 kernel executions.
Dated ProcessEnd storage reports describe their original measured trees and
are not current consumers or GDB contracts.

## Actual static image comparison

Inputs are the archived published 1a2a69ee production ELFs, objects and compiler
facts, copied and SHA-256 verified before read-only inspection, and actual
candidate artifacts. The assigned external evidence contains hashes, section
and symbol tables, targeted disassembly, relocations and frame dumps.
Inspection holds the existing shared kernel-build lock and checks input hashes
before and after. No original artifact is modified. JSON records full hashes.

| Boundary | QEMU before / after | RPi5 before / after |
|---|---|---|
| Retained display payload | 8 / 8 B | 8 / 8 B |
| Linked .text | 645008 / 644992 B | 688676 / 688676 B |
| llvm-size text | 822808 / 822792 B | 4207428 / 4207428 B |
| llvm-size data | 4624 / 4624 B | 5600 / 5600 B |
| llvm-size BSS | 1318912 / 1318912 B | 1933312 / 1933312 B |
| usable_ram_start | 1075904512 / same | 8257536 / same |
| Callback function | 76 / 80 B | 76 / 84 B |
| Report function | 360 / 340 B | 360 / 340 B |

The old variant and new AtomicWord each occupy an actual 8-byte BSS symbol
at the same address (QEMU 1075459712, RPi5 7685696). AtomicWord has value offset
0 and size 8 in both struct tables. No allocator, pool, object lifetime,
retained page or storage workload changes; previous occupancy and cross-OS
comparisons retain their original boundary. No RAM-page saving is claimed.

The callback now calls the pure helper and releases one word instead of
storing the variant tag/payload; the report acquires one word and no longer
calls the helper. The helper itself is unchanged. On QEMU callback growth
uses existing alignment padding, while report shrink removes 16 linked bytes.
On RPi5 callback growth uses existing padding; the report's 20-byte shrink
remains inter-function alignment padding, so linked text does not shrink.
These are static instruction/layout observations, not physical cycles,
coherence, latency or throughput measurements. The callback's existing stack
frame remains 16 bytes; the helper is called earlier on this same typed path.

Only those two object text sections change. Their relocation counts move
6-to-7 and 53-to-52, with the helper call moving between them. Renaming the
8-byte BSS section adds 12 string-table bytes; symbol-table size is unchanged.
Object eh_frame bytes change with those function ranges, at unchanged size.
All other object sections retain size and bytes. Linked relocation resolution
changes bytes in 392 QEMU and 73 RPi5 functions, including unchanged object
bodies; these must not be described as additional source changes. Linked GOT
size/address and unwind size/address stay fixed while their contents change
with resolved symbol addresses. Six QEMU GOT slots and one RPi5 GOT slot
change; 244 QEMU and 53 RPi5 function addresses shift by -16 bytes before
alignment absorbs the shift, while the remaining function addresses stay put. Full changed sections and symbols are in JSON.

Assessment: accept the existing typed cell for this display-only projection,
with unchanged retained payload and image reservation; the small QEMU text
reduction is incidental. No new authority, classifier, process representation,
atomic-bool capability or protocol is introduced. Remeasure when the next
kernel feature completes or the projection, image/storage lifetime or report
workload changes.

## Runtime evidence scope

The existing QEMU-main invocation completed on the f2bf60f5 leaf snapshot:
76 views, ext2 comparison and shell smoke tests including init-exit passed.
Only documentation and the trust ledger changed during that invocation;
production/native source snapshots and the start/end receipt are archived.
It is old-base runtime evidence, not a claim of a boot on the rebased image.
The subsequent published 1a2a69ee rebase preserves this leaf byte-for-byte;
both production builds and measurements above use the actual rebased source.
WorldStop/network integration and its hardware evidence belong to that
published baseline. Final feature hardware/integration remains the coordinator's
land responsibility. Model mapping requires no restamp: neither changed body
is mapped, and no action, property or protocol semantic changes.
