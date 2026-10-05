# Real FD pool empty-chunk retention experiment

This compares retention 1 (production) with 0 (experimental) in the actual
FD-block and SharedObject pools. Production sources and policy are unchanged.
The input uses the adopted 24-byte FdEntry and 400-byte FdBlock layout.

## Workload and accounting

One continuing process runs counts 1, 32, then 128. Each count has seven
batches of sixteen rounds. Each round opens /hello.txt count times, forks,
waits for its child to exit zero, and closes every regular FD. Every open
must return the next FD from 3. Parent FD capacity persists across rounds
and counts. Children copy the parent's full table, including unused entries.
This trace is deliberately serial; it does not measure lock contention.

clock_gettime(CLOCK_MONOTONIC) brackets each batch, using the kernel's ARM
Generic Timer. Printing occurs after the timed batch. A complete capture
requires all 21 batches in order, the done marker, actual init script exit 0,
and final pool samples after process teardown. Nonzero exit is failure.
There is no timing threshold. QEMU wall time is recorded only; RPi5 is the
physical timing evidence. Both use the same AArch64 program.

prepare.py copies the maintained kernel into a new output directory. It
changes the two empty-chunk thresholds and adds four counters per pool,
protected by that pool's existing guard. The grow timer covers contiguous
page allocation, owner transfer and successful region_pool_grow. The shrink
timer begins after region_pool_shrink detached a chunk, covering region
release and physical-page return; it excludes the detach/search itself.
Timers/counter bookkeeping perturb execution and are present in both
conditions. They are diagnostic observations, not uninstrumented estimates.
OOM or too-small grow failures do not increment the success counters.

The launch snapshot precedes initial userspace mapping; bounded_end follows
its exit and reap. Counter differences include launcher startup/teardown in
addition to the churn. Batch times cover only open/fork/wait/close rounds,
including their ordinary scheduling and interrupts. Pool reservation includes
permanent root state, slot metadata and slack. It is neither payload nor
whole-service RAM. Region handles retain their full-width generation and
existing stale-handle, pin and ownership rules.

Both pools contain one permanent-root object at final teardown. Retention 1
can keep one additional empty chunk per pool; retention 0 keeps the occupied
chunk only. The analyzer independently reconciles successful grows minus
shrinks with chunk counts and verifies all benchmark objects were released.
This is phase evidence, not a sampled global memory peak.

## Reproduction

Use root builds for the compiler, assembly objects and pristine fixture:

```sh
make kernelbuild kernel/build/qemu/kernel-debug.elf kernel/build/user/ext2-shell.img
python3 kernel/benchmarks/pool_retention/prepare.py /tmp/retain-qemu1 --retain 1 --platform qemu
python3 kernel/benchmarks/pool_retention/prepare.py /tmp/retain-qemu0 --retain 0 --platform qemu
python3 kernel/benchmarks/pool_retention/prepare.py /tmp/retain-rpi1 --retain 1 --platform rpi5
python3 kernel/benchmarks/pool_retention/prepare.py /tmp/retain-rpi0 --retain 0 --platform rpi5
```

Each output must be a new directory. The copied kernel is built using the
normal --regions --forbid-trap flags, DWARF, and the root's matching assembly
objects/linker scripts. Both linked assembly-invariant and boot alignment
checks must pass. No production target gains a retention option. Each output
records source hashes, input commit, platform and retention in provenance.json.

Compile the freestanding static PIE with gcc-aarch64-linux-gnu 13.2:

```sh
aarch64-linux-gnu-gcc -DTAKIBI_RAW_ABI -O2 -Wall -Wextra -fPIE -fno-builtin \
  -fno-stack-protector -nostdlib -static-pie -Wl,-e,_start -Wl,--build-id=none \
  kernel/benchmarks/pool_retention/workload.c -o /tmp/retention-workload
cp kernel/build/user/ext2-shell.img /tmp/retention-ext2.img
e2cp /tmp/retention-workload /tmp/retention-ext2.img:/bin/retention-workload
printf '#!/bin/sh\nexec /bin/retention-workload\n' > /tmp/retention-launch.sh
e2cp /tmp/retention-launch.sh /tmp/retention-ext2.img:/bench.sh
printf '::sysinit:/bin/sh /bench.sh\n' > /tmp/retention-inittab
e2cp /tmp/retention-inittab /tmp/retention-ext2.img:/etc/inittab
debugfs -w -R 'set_inode_field /bin/retention-workload mode 0100755' /tmp/retention-ext2.img
```

For QEMU, run each variant twice, using unused loopback UART ports:

```sh
python3 kernel/benchmarks/pool_retention/run_qemu.py \
  --elf /tmp/retain-qemu1/kernel.elf --image /tmp/retention-ext2.img \
  --output /tmp/retain-qemu1-run1 --uart 22981
```

The runner copies the disk for each disposable guest, uses two Cortex-A53
vCPUs and 1 GiB under QEMU 8.2.2 TCG, preserves raw UART, and terminates only
its own QEMU after success or failure. Capture does not write target state.

For RPi5, replace only the exact embedded fixture in each measurement ELF:

```sh
python3 scripts/patch_embedded_image.py /tmp/retain-rpi1/kernel.elf \
  kernel/build/user/ext2.img /tmp/retention-ext2.img /tmp/retain-rpi1/workload.elf
python3 scripts/patch_embedded_image.py /tmp/retain-rpi0/kernel.elf \
  kernel/build/user/ext2.img /tmp/retention-ext2.img /tmp/retain-rpi0/workload.elf
bash kernel/benchmarks/pool_retention/run_rpi5.sh \
  --elf0 /tmp/retain-rpi0/workload.elf --elf1 /tmp/retain-rpi1/workload.elf \
  --output /tmp/retain-rpi-runs
```

The wrapper takes the shared RPi5 lease for all six boots. The sequence is
1,0,0,1,1,0, giving three boots and 21 batches per count/policy. The maintained
four-core RPi5 kernel uses Cortex-A76 and its 54 MHz Generic Timer. Normal
SWD reset/load and USB fixture provisioning apply. No Ethernet peer is needed
for this local-file workload; the boot's ARP timeout occurs before launch and
outside the timed batches. Do not inject network traffic during the trace.
Raw UART, reset and load logs remain in each run directory. A SWD failure is
reported through the lease and stops the sequence; no automatic retry occurs.

## Results and controls

captures/ preserves the two QEMU repeats and six RPi5 observations. Run
analyze.py with captures from one platform only. qemu.tsv and rpi5.tsv keep
median/interquartile batch times, exact counter deltas and post-exit bytes.
Different platform clocks cannot be pooled. Repeated allocation/storage
counts must agree; repeated timing need not. The report states the limits
of this small trace before making any production policy recommendation.


The additional service/retain0.txt snapshot runs the previous gated
open/fork/wait/close service workload under the zero-retention kernel, using
service_space/run_takibi.py and its read-only GDB observer. The production
one-retention baseline is service_space/captures/takibi-packed.txt.
service/comparison.tsv records both pool reservations at each phase; payload,
FD capacities and shared-description reference observations must agree.
Use --takibi-fd-block-size 400 for both. The service snapshot is one bounded
functional/accounting trace, separate from the repeated timing workload.
