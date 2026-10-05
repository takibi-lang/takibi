# Small FD/process service space comparison

`workload.c` runs the same POSIX operations in the actual Takibi, Linux and
FreeBSD kernels: in one process, open `/hello.txt` 32 times, fork once, wait
for the child, close all files, then repeat with 128 opens. Each successful
open must return the next FD starting at 3. Every phase prints its count,
phase and PID and waits for one newline from the host. The child exits only
after its observation. The parent cannot close files until wait completes.
This is a cooperative observation gate, not a forced scheduler race.

The five phases are `baseline`, `opened`, `inherited`, `reaped`, `closed`.
The second count deliberately uses the same process with the FD capacity
retained from the first count. A complete capture requires every parent and
child observation and a zero exit status. The syscall sequence has no malloc,
file creation, data I/O, exec in the measured phases, threads, HTTP, or timing
verdict. It is the small FD/process slice of a service-level comparison;
it is not the allocator-only experiment in `../pool_space`.

## Measurement boundary

`fd_payload_bytes` is the sum of each actor's FD-context body and the
requested storage of its dynamic descriptor tables, plus the bodies of the
unique regular open file descriptions. Shared descriptions count once at
fork. Default embedded entries are already included in the context body;
dynamic-table growth does not remove them. Takibi counts its 72-byte context
and whole 528-byte blocks (including link/generation fields), with 80-byte
SharedObject bodies. Linux uses `files_struct`, dynamic `fdtable`/pointer
arrays/bitmaps, and `struct file`. FreeBSD uses `filedesc0`, dynamic
filedescent tables/free-table records/maps, and `struct file`.

Linux records the actual dynamic allocation usable bytes via `ksize` and
FreeBSD via `malloc_usable_size` as `fd_dynamic_usable`, separately from the
requested bytes. These fields are not substituted into the cross-OS payload
sum. The same public allocation boundary is used for both OSes; their shared
parent slab capacity is excluded. Takibi's pool reservation is a separate
observation below its payload boundary, not an additional charge added to
its payload total.

`process_payload_bytes` is ProcessRecord for Takibi, task_struct for Linux,
and proc plus its single thread for FreeBSD. It is a record-size observation,
not normalized OS functionality. VM objects, page tables, kernel/user stacks,
user RSS, credentials, inode/dentry/vnode caches, pathname contexts, stdio
file bodies, slab/generation metadata outside the named bodies, diagnostic
frontends, and the observer/harness are excluded. The Takibi FD context also
contains heap/mmap bookkeeping; Linux/FreeBSD keep those elsewhere. This
boundary is not total service RAM or a whole-OS space ranking.

All guests have two vCPUs, 1 GiB RAM, QEMU 8.2.2 TCG. Takibi is the maintained
AArch64/Cortex-A53 kernel; Linux and FreeBSD are the AMD64 guests pinned in
[the allocator replay README](../pool_space/README.md). The architecture and
OS feature sets differ. This experiment cannot attribute the process-record
size difference solely to allocator or language design. It makes no physical
cache, concurrency-proof, or throughput claim.

## Observers and evidence

The host never invokes target functions through GDB or edits target state.
`sample_takibi.gdb` stops all QEMU cores for a read-only snapshot, verifies
allocation locks are free, walks hidden region chunk headers, and excludes
intrusive free-list slots before decoding live ProcessRecord/FD contexts.
It verifies the matching DWARF record sizes. Six real production pool counts
and reservations are recorded at each gate and after process exit. This is
bounded phase evidence, not a global peak. Idle permanent-root objects remain
in the global sample; they are not attributed to the benchmark process.

Linux's observer looks up the named PID, releases the temporary PID reference,
holds the task/file locks while copying counters and identities, then prints
after dropping locks. Dynamic arrays must fit this bounded experiment and
be kmalloc-backed. The FreeBSD sysctl observer holds the process, takes its
filedesc read lock, and uses the matching 15.0 private filedesc0 allocation
shape. It requires the host-gated, single-threaded process to remain parked
until the request finishes. This is a trusted experimental restriction, not
a general-purpose process introspection API.

The ordered file-pointer fingerprint and min/max reference counts are observed
at every gate. At fork parent and child fingerprints match and all regular
file descriptions have two references; after wait they have one again. This
is evidence for sharing in this trace, not a proof based on a hash. The
workload's zero exit independently checks every open, fork, wait and close.

`captures/` preserves the primary and repeat observations. Actor PIDs and
address fingerprints may change on a repeat. All storage/capacity/resource
observations and Takibi pool rows must agree. `comparison.tsv` is reproduced
from the three primary captures:

```sh
python3 scripts/measure_service_space.py \
  --takibi kernel/benchmarks/service_space/captures/takibi.txt \
  --linux kernel/benchmarks/service_space/captures/linux.txt \
  --freebsd kernel/benchmarks/service_space/captures/freebsd.txt
```

The maintained read-only capture controls run in `make langcheck`. The
explicit cross-OS measurement is manual; ordinary builds do not download,
boot, or modify external guests. The kernel implementation and allocator
policies are unchanged by the observers.

## Takibi reproduction

Build the matching maintained DWARF kernel and a freestanding static PIE
with the Linux/AArch64 syscall adapter (gcc-aarch64-linux-gnu 13.2.0):

```sh
make kernel/build/qemu/kernel-debug.elf kernel/build/user/ext2-shell.img
aarch64-linux-gnu-gcc -DTAKIBI_RAW_ABI -O2 -fPIE -fno-builtin \
  -fno-stack-protector -nostdlib -static-pie -Wl,-e,_start -Wl,--build-id=none \
  kernel/benchmarks/service_space/workload.c -o /tmp/service-replay
cp kernel/build/user/ext2-shell.img /tmp/service-ext2.img
e2cp /tmp/service-replay /tmp/service-ext2.img:/bin/service-replay
printf '#!/bin/sh\nexec /bin/service-replay\n' > /tmp/service-launch.sh
e2cp /tmp/service-launch.sh /tmp/service-ext2.img:/bench.sh
printf '::sysinit:/bin/sh /bench.sh\n' > /tmp/service-inittab
e2cp /tmp/service-inittab /tmp/service-ext2.img:/etc/inittab
debugfs -w -R 'set_inode_field /bin/service-replay mode 0100755' /tmp/service-ext2.img
```

Use a copy of the fixture, not the build's original disk. Static executables
must have the maintained loader's ET_DYN shape; ordinary ET_EXEC is not the
input format this experiment uses. The ash launcher preserves an absolute
argv[0] for the static-image resolver.

Launch QEMU with `-machine virt -cpu cortex-a53 -smp 2 -m 1024 -display none
-monitor none -global virtio-mmio.force-legacy=on`, the matching kernel-debug
ELF, the copy as a virtio-blk disk, a socket UART, and a loopback GDB listener.
No network device or HTTP service is needed. For the recorded host ports:

```sh
qemu-system-aarch64 -machine virt -cpu cortex-a53 -smp 2 -m 1024 \
  -display none -monitor none -global virtio-mmio.force-legacy=on \
  -chardev socket,id=uart,host=127.0.0.1,port=22981,server=on,wait=on \
  -serial chardev:uart -gdb tcp:127.0.0.1:22982 \
  -drive file=/tmp/service-ext2.img,if=none,format=raw,id=vd0 \
  -device virtio-blk-device,drive=vd0 -kernel kernel/build/qemu/kernel-debug.elf
```

In another terminal run `run_takibi.py --uart 22981 --gdb-port 22982
--elf kernel/build/qemu/kernel-debug.elf --capture /tmp/takibi-service.txt
--uart-log /tmp/takibi-service-uart.log` from this directory (or name the
script by its repository-relative path). The paths above are repository-root
relative. It waits for the real zero-exit/reap observation before the final
snapshot. End that disposable QEMU after the capture.

## Linux reproduction

In the pinned Alpine guest build `workload.c` using gcc 14.2:
`gcc -O2 -static -Wall -Wextra workload.c -o service-replay`. In a guest
`/service-replay` directory put `linux_observer.c` and `linux/Makefile`, then
run `make -C /lib/modules/6.12.111-0-virt/build M=/service-replay
GCC_PLUGINS_CFLAGS= modules`. The plugin flag restriction is the same as
in the allocator replay; the guest kernel is unchanged.

Build a newc initramfs containing static BusyBox at `/bin/busybox`, the module
at `/linux_observer.ko`, the workload at `/service-replay`, the tracked
`linux/init` as executable `/init`, `/hello.txt` containing `hello from ext2`
and a newline, and empty `/proc`, `/sys`, `/dev` directories. Boot the same
linux-virt kernel with `-m 1024 -smp 2 -display none -monitor none`,
`-append 'console=ttyS0 rdinit=/init panic=1'`, and two socket UARTs:

```sh
-chardev socket,id=uart,host=127.0.0.1,port=22983,server=on,wait=on -serial chardev:uart
-chardev socket,id=control,host=127.0.0.1,port=22984,server=on,wait=off -serial chardev:control
```

Run `run_linux.py --uart 22983 --control 22984 --capture /tmp/linux-service.txt
--uart-log /tmp/linux-service-uart.log`. The control shell is a different
process; it does not add an observer FD to the workload. The init script
records the real workload status and powers the guest off.

## FreeBSD reproduction

In the pinned stock FreeBSD 15.0-RELEASE guest, copy `freebsd_observer.c` and
`freebsd/Makefile` into `/root/service-replay`, then `make` with matching
`/usr/src` installed. `vnode_if.h` is generated by that build. Compile the
same `workload.c` using `cc -O2 -Wall -Wextra workload.c -o service-replay`.
Create `/hello.txt` with the same contents as above. Load
`/root/service-replay/freebsd_observer.ko`, clear old dmesg copies, and run:

```sh
python3 kernel/benchmarks/service_space/run_freebsd.py --port 22975 \
  --key /path/to/guest-ssh-key --known-hosts /path/to/guest-known-hosts \
  --capture /tmp/freebsd-service.txt
```

The guest's SSH port is forwarded only on loopback. No observer FD is added
to the workload process. Unload the module after the capture and shut the
disposable guest down. Repeat each OS run and validate both captures before
using the report. Only these three OSes belong to this comparison.
