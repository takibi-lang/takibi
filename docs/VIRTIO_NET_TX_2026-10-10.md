# virtio-net completion deadline and retained storage

## Workload and policy

The maintained QEMU driver has two synchronous TX paths: a dedicated scratch
payload and an in-place reply that borrows an RX buffer. Both now use the
same elapsed-counter wait, with a 1 s dead-device policy matching the current
virtio-blk policy. Commit 564b0f1a restored virtio-blk to 1 s after a 30 s
extension failed to resolve a missing completion. The wall-clock registry's
old 30 s reason was stale and is corrected. This policy is not a virtio
hardware latency specification or proof of device progress.

The wait returns a must-use Completed/Unconfirmed variant. Timer and unrelated
IRQ wakes only cause a recheck; an observed used entry on the final deadline
check wins. Periodic wake and scheduling delay can postpone expiry handling.
On expiry the driver logs once and permanently disables this boot's queues.
The TX descriptor, scratch payload and in-place RX buffer are retained; the
TX used shadow is not advanced and the RX slot is not republished. Later
sends, reposts and acquisitions cannot revive the device, even after a late
used entry or IRQ. Disabled RX waits still yield so receive callers can check
their own deadlines. No reset or storage reclamation is attempted.

## Regression and trust boundary

The native TX and reply fixtures compile the real driver, including its
submission, completion, disable and RX-repost code. Deterministic providers
supply the architectural clock, timer wakes and device-written RAM used-ring
entries. The only source substitution is the unused IRQ handler's AArch64
interrupt_notify builtin, replaced with a no-op because AMD64 has no lowering
for it. The builder refuses a missing or duplicate notify anchor; every other
driver statement is copied verbatim from tracked source.

The tests execute immediate completion, more than 1000 unrelated wakes before
the deadline, absent completion, boundary completion and a delayed wake. Both
normal send paths complete and the RX reply is reposted. Both failure paths
return, log once, retain the used shadow and RX availability, refuse later
scratch writes/notifications and reject a late valid RX entry. A native
watchdog diagnoses the old unbounded loop promptly rather than hanging the
test runner. All native tests build with --forbid-trap.

Negative controls were compiled and executed independently; each command
exited nonzero and printed its own expected diagnostic:

| Control | Observed diagnostic |
| --- | --- |
| Actual old driver at 4e88fd5f, with only notify substituted | wait did not return after the elapsed deadline |
| Remove later standalone-send guard | later standalone sends leave descriptor, payload and notification unchanged |
| Remove RX repost guard on reply timeout | unconfirmed completion neither consumes TX nor reposts RX |
| Remove disabled-RX acquire guard | late interrupt revived RX after timeout |

The root defect was a nested IRQ-flag loop with no deadline, inside the
used-index loop. A timer wake did not change that flag, so a stopped device
kept the caller inside the inner loop indefinitely. Ordinary network tests
missed it because QEMU completed their descriptors; none supplied an absent
completion. The deterministic device oracle is the cheapest faithful test of
this instance, and the old-driver control establishes that it detects it.
The retention mutations establish that the test checks the actual driver,
not just the policy function in isolation.

Private submission prevents outside callers from bypassing the driver entry
points; the must-use result prevents ignoring an expiry outcome. Actual ring
and packet ownership still depends on the driver's guards and raw memory
boundary. This correction is not a new compiler liveness rule or fixed DMA
token migration. Bad code such as `while (pending()) { wait(); }` can still
compile: a completion-result type alone cannot forbid omission of the wait
API. Existing fixed DMA owners can encode buffer reuse authority when the
virtio buffers are migrated, while device progress remains trusted. No new
compiler capability is required for this bounded-wait correction.

Similar maintained paths were reviewed: GEM uses an elapsed deadline and
owned halt settlement; virtio-blk completion and reset use elapsed deadlines.
Historical examples are outside maintained implementation scope. The native
oracle cannot prove real MMIO, DMA ordering, caches or interrupt delivery;
ordinary QEMU integration exercises the real virtio path. The fail-fast
native watchdog and per-control logs make a recurrence diagnosable without a
QEMU hang or scheduler prints.

## Space measurement

Fresh baseline linked kernels were built at 4e88fd5f. After correcting the
candidate policy to 1 s, both final production kernels were rebuilt and
measured. Raw sizes and candidate image identities are preserved in
VIRTIO_NET_TX_SPACE_2026-10-10.json.

| Boundary | QEMU delta | RPi5 delta |
| --- | ---: | ---: |
| text | +312 B | 0 B |
| initialized data | +8 B | 0 B |
| BSS | 0 B | 0 B |
| usable_ram_start | unchanged (0x40250000) | unchanged (0x718000) |

The added disabled flag is one byte, with linked-section padding accounting
for the 8 B initialized-data delta. Existing queue memory, RX buffers and TX
scratch payload have unchanged size. There is no additional production pool
or dynamic allocation and no extra allocator page reservation. Timeout retains
already reserved queue/payload storage rather than allocating recovery memory.
Test-only fake MMIO and oracle state are absent from production kernels. The
small measured image cost is accepted; no structural optimization or fresh
cross-OS comparison is needed at this boundary.

Next measurement trigger: fixed virtio-net DMA owners, queue/buffer capacity
changes, device reset/recovery or another completed kernel feature/stage.
