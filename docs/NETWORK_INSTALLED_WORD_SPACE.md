# Network capability installed word review (2026-11-09)

This completed typed storage migration is a measured milestone. Compare the
actual production ELF/object pairs with published f2bf60f5. Baseline originals
were copied from its retained archive, verified against the immutable manifest,
and inspected read-only. Input hashes stayed stable; no input-only objcopy was
used. Numeric observations and hashes are in NETWORK_INSTALLED_WORD_SPACE.json.

Only NetworkCapabilityStore.installed_once and its two accesses change.
BSS supplies zero (false); the sole private store site writes one after the
existing Place::Empty installation, before releasing the same masking Mutex.
The sole flag read remains under that mutex and tests nonzero. It is never
cleared. AtomicWord checks atomic cell access, not a refined boolean domain:
the zero/one property and the relation to the Place are current source/caller
premises. No field pointer escape or alternate writer is introduced. Mutex,
Place, linear guard, device identity, try-lock/DDB and waiting APIs and
algorithms are unchanged. Atomic access alone does not prove that protocol.

| Boundary | QEMU baseline -> candidate | RPi5 baseline -> candidate |
| --- | --- | --- |
| installed_once payload | 1 -> 8 B | 1 -> 8 B |
| installed_once offset | 28 -> 32 | 16 -> 16 |
| NetworkCapabilityStore | 32 -> 40 B | 24 -> 24 B |
| Text (llvm-size) | 822792 -> 822808 B | 4207396 -> 4207396 B |
| Data | 4624 -> 4624 B | 5600 -> 5600 B |
| BSS | 1318912 -> 1318912 B | 1933312 -> 1933312 B |
| usable_ram_start | 0x40210000 -> 0x40210000 | 0x7e0000 -> 0x7e0000 |
| network_capability_install | 384 -> 392 B | 148 -> 156 B |
| network_capability_take_waiting | 264 -> 268 B | 120 -> 124 B |

Mutex stays at offset zero and Place at offset eight. On QEMU the word needs
four bytes before it for alignment; its seven extra payload bytes replace
three bytes of old trailing padding, for net eight bytes of object growth.
On RPi5 its seven extra bytes consume existing trailing padding. No pool,
retained capacity, allocator workload or page reservation changes. The unchanged
rounded QEMU BSS is not a claim that the payload cost disappeared: 61 later
data symbols move by eight bytes and 167 by sixteen after further alignment;
the store itself keeps its address. Placement slack absorbs that movement
before the next fixed boundary. RPi5 data symbols do not move.

On both targets install adds an address calculation and a literal-one move,
replacing a byte store with stlr; waiting adds an address calculation and
replaces a byte load with ldar and a full-word zero test. Only those two
object code sections differ. QEMU install grows by eight bytes and needs eight more bytes of
next-function padding, shifting later code by sixteen bytes; waiting's four
extra bytes fit its existing alignment gap. RPi5 consumes existing gaps for both functions, so
other function addresses and linked text size stay fixed. Object call
relocation offsets and the two function sizes follow. The sole object unwind
changes are each function's FDE range: 384 -> 392 and 264 -> 268 on QEMU,
148 -> 156 and 120 -> 124 on RPi5; CFA instructions are unchanged. QEMU's
234 changed GOT words resolve to the moved code/data symbols. RPi5 has no
GOT change. Other object code sections and literal data are unchanged.

The waiting path pays one extra static address instruction per poll and stronger
ordering while retaining the existing lock. Installation pays two extra static
instructions in its successful Empty arm. No lock, spin, wait, IRQ-mask or
preemption transition is added. These instruction/image observations are not
measured physical cycles, interrupt latency or cache coherence. The small,
explained storage/code cost is adopted for the existing typed cell boundary.

Both target call graphs contain all nine socket-capability functions. Only
install and take_waiting body hashes change; signatures, qualifiers, inferred
effects, callers and function-value references match the published baseline.
Existing requires_mmu already follows from the mutex. Actual compiler globals
show composite through the existing recursive rule, so only this controller's
allowance row is removed. No classifier rule, fixture exemption, new guard,
atomic-bool capability or language change is added. Neither changed function
is mapped by the current model action table, and the actual model-map gate
passes without a restamp. No model action, property, bound or semantics changes.

The old34ee component passed the maintained QEMU main lane (76 views and four
shell smoke cases), including actual network installation/take/put through
TCP contention/pool and syscall workloads. Those captures and exact receipts
remain old-base evidence. The original module's source is identical between
published34ee and f2bf, and the exact three-statement migration is preserved.
The rebased candidate is built/measured on both targets; no post-rebase guest
result is claimed. Full combined runtime/hardware publication is coordinator
work. The normal network-present boot does not force NeverInstalled before
bring-up; BSS zero, sole store-one and compiled zero-test correspondence are
source/code evidence for that branch, not an invented runtime observation.

Measure again if this store's representation, flag domain, guard, Place
payload, waiter lifetime or allocation workload changes, or at the next
completed kernel stage.
