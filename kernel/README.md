# Takibi kernel

This is the standalone Linux-compatible kernel tree from GitHub issue #177.
It is not an example and must not depend on files below `examples/`.

The first maintained platform is Raspberry Pi 5. TF-A hands control to a
small AArch64 EL2 boot shim; the monolithic kernel then runs at EL1 and user
processes run at EL0. Ordinary kernel services do not use EL2 HVC calls.

Build targets:

```text
make kernelbuild-rpi5  build the RPi5 kernel
make kernelcheck-rpi5  build and integration-test the RPi5 kernel
make kernelbuild       build every maintained kernel target
make kernelcheck       build and integration-test every maintained target
```

`kernelcheck-rpi5` requires the Raspberry Pi Debug Probe, the project UART
cable, and the resident RPi5 JTAG stub, just like the examples hardware lane.
A build-only result is never reported as an RPi5 integration pass.

WARNING: `kernelcheck-rpi5` overwrites the first 1 MiB of the USB Mass Storage
device attached to the RPi5 with the generated ext2 fixture. Attach only the
project's dedicated sacrificial test drive. The kernel block adapter exposes
exactly those first 1024 1-KiB blocks, bounding this bring-up milestone's
destructive scope independently of the physical device capacity.

`kernelcheck-rpi5` also requires the RPi5 Ethernet port to have an active
link. The standalone RP1 Cadence GEM driver resets and configures the
BCM54213PE PHY, negotiates the link, initializes its typed RX/TX DMA rings,
and uses the dedicated `02:00:20:00:00:02` test MAC. The host runner uses a
privileged raw socket on `ETH_TEST_IFACE` (default `enp5s0`) to prove that a
request for another address stays unanswered and that an ARP request for
`192.168.20.2` receives the exact reply. The same owned RX path then rejects
an ICMP request for another IP and one with a corrupt checksum before
returning a checksum-correct echo reply. The capability then enters a
single-connection TCP state machine on port 7, covering checksum rejection,
SYN options, handshake, data echo, FIN close, and reconnect.

The first Linux socket boundary is also active at EL0. The syscall fixture
creates one `AF_INET`/`SOCK_STREAM` fd, binds an explicitly validated
`sockaddr_in` to port 8080, transitions it to listening state, and closes it
through AArch64 syscalls 198/200/201/57. This milestone proves socket
control-plane ABI and lifecycle before the connected data path below.
The RX readiness token is now linear and survives the intervening USB/ext2
and BusyBox work in a guarded stable owner slot. Blocking `accept4(242)`
takes that token, processes a real three-way handshake on port 8080, restores
the token, and returns connected fd 5. The EL0 fixture closes fd 5 and the
listener separately. A blocking `read(63)` moves the received linear frame
owner into a second stable slot while its payload is visible to userspace;
`write(64)` consumes that same owner to transmit an independently generated
userspace response as PSH/ACK and restores the RX token. Receive and response
lengths advance their respective TCP sequence spaces independently. The
current contract remains one request segment followed by one complete
response write; stream reassembly and partial writes are not implemented.

The RPi5 runner captures UART once per kernel boot, then projects that one
transcript through every `kernel/tests/rpi5/views/*.filter`. Each projection
is compared exactly with the same-named `.expected` file. This lets boot,
process, VM, syscall, filesystem, and networking contracts grow independently
without paying for a separate hardware reboot for every viewpoint.

The runner reports reset, SWD load, and execution phases from the host. During
kernel execution it prints elapsed time every five seconds and stops capture
as soon as the stable final resource marker arrives. These progress lines are
not kernel UART diagnostics and are not part of any `.expected` contract.

Kernel UART output is classified at its call site. `kernel_boot_log` is only
for stable operator-visible boot/status messages. Temporary kernel debug UART
logging was removed once a distribution BusyBox could report integration
evidence through the userspace Linux `write` boundary.

All new Takibi sources in this tree are compiled with `--forbid-trap` from
their first commit. Fallible internal operations return variants; conversion
to Linux `-errno` values happens only at the syscall boundary. Process,
address-space, page, mapping, file, and DMA lifetimes retain explicit
affine/linear ownership.

## Initial milestones

1. Boot through a minimal EL2 shim and enter the kernel once at EL1.
2. Install complete fail-stop exception vectors that retain fault evidence.
3. Create one typed process and address space with separate RX text and
   RW+XN data/stack pages.
4. Run one EL0 program through correct AArch64 Linux `write` and `exit`
   syscall boundaries, then reclaim every linear resource.
5. Run a distribution-provided static BusyBox from an initramfs.
6. Mount and mutate a reproducible RAM-backed ext2 image before connecting
   the same block interface to RPi5 USB Mass Storage.

Milestone 1 now runs on real RPi5 hardware: the typed initial process enters
EL0 with RX text and RW+XN data/stack mappings, observes Linux AArch64
`write(64)` success plus `-EBADF`/`-EFAULT` error returns, exits through
`exit(93)`, and returns to the owning EL1 frame to unmap and free every page.

The next compatibility fixture is generated under `kernel/build/user` from
Alpine v3.24's pinned AArch64 `busybox-static` package. It is wrapped in a
`newc` initramfs and embedded in the kernel without committing the GPL binary.
The kernel validates the archive name/bounds and the real static-PIE ELF load
plan before the larger owned process-image mapping is attempted.

That measured load plan now drives the real `PT_LOAD` mappings plus an owned
initial stack and fixed short-lived heap. Alpine BusyBox runs
`cat /hello.txt` at EL0, opens the USB ext2 file through `openat(56)`, emits it
through `sendfile(71)`, closes it, and exits through syscall 93 with status
zero. All 401 image, heap, and stack pages sit
under one linear `ProcessImagePages` teardown obligation and are returned
before the smaller syscall fixture is created.

Alpine's `busybox-static` package deliberately does not contain the `httpd`
applet. The distribution-provided implementation is `/bin/busybox-extras`
from `busybox-extras`; it is an AArch64 PIE using
`/lib/ld-musl-aarch64.so.1`. That executable plus Alpine's matching musl
interpreter is therefore the selected HTTP-server userspace target. An
Ubuntu `busybox-static` with `httpd` was also evaluated, but it is `ET_EXEC`
with absolute addresses beginning at `0x400000`; relocating its segments into
this kernel's guarded `0x40000000` userspace window does not relocate those
internal references. The kernel continues to reject that unsupported form
instead of mapping an image which will fail after entry. The next loader work
is the real ELF-interpreter path for the Alpine PIE, not an `ET_EXEC`
pseudo-relocation.

The generated `newc` initramfs now contains the original static BusyBox,
`busybox-httpd` from the pinned Alpine `busybox-extras` package, and the
matching pinned `ld-musl-aarch64.so.1`. Its parser walks aligned cpio entries
with archive-bound checks instead of assuming the archive contains one file.
RPi5 boot validation checks the exact names and the known AArch64 PIE entry,
load-segment count, and extent of both HTTPd inputs before the existing static
BusyBox process is started.

Both dynamic HTTPd inputs also pass the real owned process-image mapper on
RPi5. In independent mapping probes, every `PT_LOAD` page receives RX or
RW+XN permissions, file-backed bytes are copied, BSS remains zero, the fixed
heap and stack retain page owners, and teardown leaves the complete 2 MiB EL0
window unmapped. A dedicated `httpd_loader.expected` view records 157 pages
for the HTTPd PIE and 296 for musl. Independent probes intentionally precede
the combined layout: the remaining loader work is assigning non-overlapping
load biases and constructing interpreter-aware auxv, not debugging either
image's ordinary segment mapping at the same time.

The segment mapper is now shared by single-image execution and a combined
dynamic-image layout. HTTPd remains at load bias zero and musl uses bias
`0x40000`; their 28 and 167 segment pages coexist without overlap in the
same EL0 page table. Allocation failure, invalid permissions, and overlap all
roll back the complete combined prefix. The RPi5 loader view requires all 195
pages to be reclaimed and the window to be empty. Heap, stack, and
interpreter-aware auxv are deliberately the next layer on this proven segment
layout.

The combined layout now also owns one shared 128-page heap and one stack,
bringing the complete process to 324 pages. Its initial entry probe uses
`busybox-httpd httpd --help` and an interpreter-aware auxiliary
vector: application `AT_PHDR`/`AT_PHNUM`/`AT_ENTRY`, musl `AT_BASE`, page
size, random bytes, UID/EUID/GID/EGID, secure mode, and `AT_EXECFN`. Takibi's
string-literal `\0` escape makes every argv terminator explicit. The probe
still reclaims the full layout before static BusyBox runs; transferring
control now enters biased musl code, dynamically links the distribution
HTTPd PIE, dispatches the real applet, returns status zero through
`exit_group`, and reclaims the complete address space. Serving begins next in
BusyBox's single-process `-i` mode; ordinary foreground mode is deferred
because the traced implementation clones a child after each `accept`.

The first ext2 slice is also active on RPi5. The build creates a checked 1 MiB
RAM fixture with `mke2fs`, populates it with `e2mkdir`/`e2cp`, and embeds it as
a writable image. The filesystem core reaches it only through the 1 KiB block
interface in `kernel/drivers/block/`. It validates the superblock and group
descriptor, decodes the inode table, walks the root directory, reads and
resizes a regular file, resolves a fast symlink, updates allocation bitmaps
and free counts, and creates and unlinks a root file using typed block/inode
owners. Indirect blocks and multi-group images remain deferred until a
concrete caller requires them.

The same ext2 core now mounts the RPi5's real USB Mass Storage device. The
standalone RP1 xHCI/Bulk-Only/SCSI driver reports 512-byte sectors; the USB
block adapter combines each adjacent sector pair into the filesystem core's
1 KiB block contract. During `kernelcheck-rpi5`, the checked embedded image
is copied into the deliberately bounded first-1-MiB device view, then mounted
and `/hello.txt` is looked up and read back from USB. Linux-compatible
`openat`, `read`, `write`, `sendfile`, and `close` bind one process file
descriptor to this mount; the small EL0 fixture also overwrites
`/mutable.txt` through those syscall boundaries. The adapter intentionally
does not expose the rest of the physical medium yet.

The same reproducible ext2 image now contains `/index.html` for the concrete
BusyBox HTTPd target. Linux `openat` accepts both `/index.html` and the
relative `index.html` used after HTTPd changes its document root, and
`newfstatat(79)` returns the AArch64 asm-generic regular-file metadata and
exact ext2 length. Unsupported configuration paths continue to return
`-ENOENT`.
